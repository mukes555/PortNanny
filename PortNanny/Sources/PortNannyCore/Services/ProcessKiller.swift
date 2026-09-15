import Foundation

// MARK: - ProcessKiller
public class ProcessKiller {

    public enum KillError: Error, LocalizedError {
        case invalidPid(Int)
        case permissionDenied(Int)
        case identityMismatch(pid: Int, expected: String, actual: String)
        case unknownError(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPid(let pid):
                return "Invalid PID \(pid)"
            case .permissionDenied(let pid):
                return "No permission to kill PID \(pid)"
            case .identityMismatch(let pid, _, let actual):
                return "PID \(pid) now belongs to '\(actual)': refresh and retry"
            case .unknownError(let message):
                return message
            }
        }
    }

    /// What a kill did.
    public struct Outcome: Equatable {
        /// False when the process had already exited: nothing was signalled,
        /// so nothing should be recorded in History as killed.
        public let signalled: Bool
        /// Children a tree kill could not take down (another user's, or a pid
        /// recycled during the walk). The port can stay busy because of them,
        /// so the caller says so instead of reporting a clean kill.
        public let childrenNotKilled: [Int]

        static let gone = Outcome(signalled: false, childrenNotKilled: [])
    }

    /// Kills a process by PID, optionally killing its children as well.
    ///
    /// Pass `expectedName` (the process name captured at scan time) whenever
    /// possible: PIDs get recycled, and the check refuses to signal a PID that
    /// now belongs to a different program.
    @discardableResult
    public func killProcess(pid: Int, force: Bool = false, killTree: Bool = false, expectedName: String? = nil) throws -> Outcome {
        // kill(0)/kill(-1) signal entire process groups: never allow them, and
        // a number no pid can be is a bad argument, not a process: narrowing
        // one to pid_t traps and takes the whole process down.
        guard pid > 0, let target = pid_t(exactly: pid) else { throw KillError.invalidPid(pid) }

        if let expectedName {
            guard let actualName = currentProcessName(pid: pid) else {
                return .gone // Already gone, nothing to do.
            }
            if !Self.namesMatch(expected: expectedName, actual: actualName) {
                throw KillError.identityMismatch(pid: pid, expected: expectedName, actual: actualName)
            }
        }

        var childrenNotKilled: [Int] = []
        if killTree {
            // One snapshot of the process tree for the whole walk. Enumerating
            // the table again at every node cost depth x (all processes)
            // syscalls, and a reparent race could make the recursion cycle.
            var seen: Set<Int> = [pid]
            killDescendants(of: pid, force: force, children: childrenByParent(), seen: &seen, depth: 0,
                            failed: &childrenNotKilled)
        }

        // The user explicitly chooses SIGKILL (force); a graceful kill must
        // never silently escalate, so a failed SIGTERM is reported, not forced.
        let signal = force ? SIGKILL : SIGTERM
        if kill(target, signal) == 0 {
            return Outcome(signalled: true, childrenNotKilled: childrenNotKilled)
        }

        switch errno {
        case ESRCH:
            // Died in the meantime: the port is free, but nobody killed it.
            return Outcome(signalled: false, childrenNotKilled: childrenNotKilled)
        case EPERM:
            throw KillError.permissionDenied(pid)
        default:
            throw KillError.unknownError("kill(\(pid)) failed (errno \(errno))")
        }
    }

    /// Case-insensitive name match tolerant of lsof's ~9-char truncation.
    /// An empty expected name means "cannot verify" and never matches: an
    /// empty prefix would otherwise make the identity check always pass.
    public static func namesMatch(expected: String, actual: String) -> Bool {
        let expectedLower = expected.lowercased()
        let actualLower = actual.lowercased()
        guard !expectedLower.isEmpty, !actualLower.isEmpty else { return false }
        return actualLower.hasPrefix(expectedLower) || expectedLower.hasPrefix(actualLower)
    }

    private static let maxTreeDepth = 32

    /// Kills grandchildren before children before the caller signals the
    /// parent. Each child is checked against the name it had when the tree
    /// was captured, so a pid recycled during the walk fails the check
    /// instead of being signalled.
    private func killDescendants(of pid: Int, force: Bool, children: (Int) -> [(pid: Int, name: String?)],
                                 seen: inout Set<Int>, depth: Int, failed: inout [Int]) {
        guard depth < Self.maxTreeDepth else { return }
        for child in children(pid) where !seen.contains(child.pid) {
            seen.insert(child.pid)
            killDescendants(of: child.pid, force: force, children: children, seen: &seen, depth: depth + 1, failed: &failed)
            // A child that cannot be killed is the reason a tree kill leaves
            // the port busy; swallowing it left the caller reporting success.
            do {
                _ = try killProcess(pid: child.pid, force: force, expectedName: child.name)
            } catch {
                failed.append(child.pid)
            }
        }
    }

    /// Children lookup from one native snapshot; pgrep per node only when
    /// libproc gave nothing (sandboxed or unexpected OS).
    private func childrenByParent() -> (Int) -> [(pid: Int, name: String?)] {
        let processes = NativeScanner.processMap()
        guard !processes.isEmpty else {
            // pgrep gives pids only, so there is nothing to verify against.
            // An empty name was passed instead of none, and an empty name
            // never matches: every child failed the identity check, and this
            // fallback killed nothing at all.
            return { Self.pgrepChildren(of: $0).map { (pid: $0, name: nil) } }
        }

        var byParent: [Int: [(pid: Int, name: String?)]] = [:]
        for (child, process) in processes {
            byParent[Int(process.ppid), default: []].append((pid: Int(child), name: process.name))
        }
        return { byParent[$0] ?? [] }
    }

    private static func pgrepChildren(of pid: Int) -> [Int] {
        // pgrep exits 1 with no children
        let output = (try? CommandRunner.run(
            "/usr/bin/pgrep", ["-P", "\(pid)"], timeout: 2.0, allowedExitCodes: [0, 1]
        )) ?? ""
        return output.components(separatedBy: .newlines).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Returns the executable base name currently running under `pid`,
    /// or nil if the PID is not alive.
    private func currentProcessName(pid: Int) -> String? {
        guard isProcessRunning(pid) else { return nil }

        if let target = pid_t(exactly: pid), let name = NativeScanner.processName(target) {
            return name
        }

        // Fallback: ps exits 1 when the PID doesn't exist
        let output = (try? CommandRunner.run(
            "/bin/ps", ["-p", "\(pid)", "-o", "comm="], timeout: 2.0, allowedExitCodes: [0, 1]
        )) ?? ""

        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return nil }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Checks if a process is currently running
    /// SZOMB from sys/proc.h: exited, not yet reaped by its parent. kill(2)
    /// still succeeds on a zombie, so the CLI would otherwise wait the full
    /// timeout and report a dead process as "still running".
    private static let zombieStatus: UInt32 = 5

    public func isProcessRunning(_ pid: Int) -> Bool {
        // A number too large for a pid is not a running process, and asking
        // the kernel about it would trap on the way in.
        guard pid > 0, let target = pid_t(exactly: pid) else { return false }

        if let bsd = NativeScanner.bsdInfo(target) {
            return bsd.pbi_status != Self.zombieStatus
        }
        if kill(target, 0) == 0 {
            return true
        }
        // EPERM means it exists but belongs to someone else.
        return errno == EPERM
    }
}
