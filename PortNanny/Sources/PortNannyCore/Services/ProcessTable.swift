import Foundation

/// A snapshot of every running process, taken with a single `ps` invocation.
///
/// The scanners previously spawned `ps`/`pgrep` once per listening port
/// (dozens of subprocesses per refresh); they now share one of these per
/// refresh and do dictionary lookups instead.
public struct ProcessTable {

    public struct Entry {
        let pid: Int
        let ppid: Int
        let rssKB: Int
        let cpuPercent: Double
        let ageSeconds: Int?
        let command: String
        /// Authoritative name from the kernel (native scans). The computed
        /// fallback mis-splits paths with spaces ("Google Chrome Helper" -> "Google").
        var processName: String?
        /// Owner uid (native scans only).
        var uid: uid_t?

        var name: String {
            if let processName, !processName.isEmpty {
                return processName
            }
            let executable = command.split(separator: " ").first.map(String.init) ?? command
            return executable.split(separator: "/").last.map(String.init) ?? executable
        }
    }

    public static let empty = ProcessTable(psOutput: "")

    private let entriesByPid: [Int: Entry]
    private let childrenByPpid: [Int: [Entry]]
    /// Listening sockets gathered in the same native pass as the table, so
    /// the scanner never walks the process list twice. nil for ps-built tables.
    public let listeners: [NativeScanner.Listener]?

    public static func capture() -> ProcessTable {
        // Raw-syscall snapshot; ps subprocess only as a fallback
        if let snapshot = NativeScanner.capture() {
            let entries = snapshot.samples.map { sample in
                Entry(
                    pid: sample.pid, ppid: sample.ppid, rssKB: sample.rssKB,
                    cpuPercent: sample.cpuPercent, ageSeconds: sample.ageSeconds,
                    command: sample.command, processName: sample.name, uid: sample.uid
                )
            }
            return ProcessTable(entries: entries, listeners: snapshot.listeners)
        }

        let output = (try? CommandRunner.run(
            "/bin/ps", ["-axo", "pid=,ppid=,rss=,%cpu=,etime=,command="], timeout: 5.0
        )) ?? ""
        return ProcessTable(psOutput: output)
    }

    /// Just the ancestor chain of `pid` (plus `extra` pids), for callers that
    /// only need to walk upwards: `portnanny whoami` used to snapshot all
    /// ~600 processes to inspect five.
    public static func ancestry(of pid: Int, including extra: [Int] = []) -> ProcessTable {
        var entries: [Entry] = []
        var seen = Set<Int>()
        var queue = [pid] + extra

        // Skipping a chain's end (launchd's ppid 0) must not end the walk:
        // with `extra` pids the caller's own chain is still in the queue.
        while let current = queue.popLast(), seen.count < 64 {
            // `extra` comes from callers, and so from the environment; a value
            // no pid can hold is skipped rather than narrowed into a trap.
            guard current > 0, !seen.contains(current), let kernelPid = pid_t(exactly: current) else { continue }
            seen.insert(current)
            guard let bsd = NativeScanner.bsdInfo(kernelPid) else { continue }
            let shortName = NativeScanner.stringFromFixedCArray(bsd.pbi_name)
            let facts = ProcessFacts.shared.facts(for: kernelPid, startedAt: bsd.pbi_start_tvsec, shortName: shortName)
            let name = facts.executablePath.map { ($0 as NSString).lastPathComponent } ?? shortName
            entries.append(Entry(
                pid: current, ppid: Int(bsd.pbi_ppid), rssKB: 0, cpuPercent: 0, ageSeconds: nil,
                command: facts.command ?? facts.executablePath ?? name, processName: name, uid: bsd.pbi_uid
            ))
            queue.append(Int(bsd.pbi_ppid))
        }
        return ProcessTable(entries: entries)
    }

    public init(entries: [Entry], listeners: [NativeScanner.Listener]? = nil) {
        var byPid: [Int: Entry] = [:]
        var byPpid: [Int: [Entry]] = [:]
        for entry in entries {
            byPid[entry.pid] = entry
            byPpid[entry.ppid, default: []].append(entry)
        }
        entriesByPid = byPid
        childrenByPpid = byPpid
        self.listeners = listeners
    }

    public init(psOutput: String) {
        var byPid: [Int: Entry] = [:]
        var byPpid: [Int: [Entry]] = [:]

        // Line format: PID PPID RSS %CPU ETIME COMMAND (command keeps its spaces)
        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let rss = Int(parts[2]) else { continue }

            let entry = Entry(
                pid: pid,
                ppid: ppid,
                rssKB: rss,
                cpuPercent: Double(parts[3]) ?? 0,
                ageSeconds: ElapsedFormat.seconds(fromEtime: String(parts[4])),
                command: String(parts[5])
            )
            byPid[pid] = entry
            byPpid[ppid, default: []].append(entry)
        }

        entriesByPid = byPid
        childrenByPpid = byPpid
        listeners = nil
    }

    public var allEntries: [Entry] { Array(entriesByPid.values) }
    /// The entries without copying them into an array.
    public var entries: Dictionary<Int, Entry>.Values { entriesByPid.values }

    public func command(for pid: Int) -> String? { entriesByPid[pid]?.command }
    public func name(for pid: Int) -> String? { entriesByPid[pid]?.name }
    public func uid(for pid: Int) -> uid_t? { entriesByPid[pid]?.uid }
    public func user(for pid: Int) -> String? { entriesByPid[pid]?.uid.map(NativeScanner.username) }
    public func ppid(for pid: Int) -> Int? { entriesByPid[pid]?.ppid }
    public func rssKB(for pid: Int) -> Int? { entriesByPid[pid]?.rssKB }
    public func cpuPercent(for pid: Int) -> Double? { entriesByPid[pid]?.cpuPercent }
    public func ageSeconds(for pid: Int) -> Int? { entriesByPid[pid]?.ageSeconds }
    public func children(of pid: Int) -> [Entry] { childrenByPpid[pid] ?? [] }

    /// Every process under `pid`, the set a tree kill takes down.
    public func descendants(of pid: Int) -> Set<Int> {
        var found: Set<Int> = []
        var queue = children(of: pid).map(\.pid)
        while let next = queue.popLast(), found.insert(next).inserted {
            queue += children(of: next).map(\.pid)
        }
        return found
    }
}
