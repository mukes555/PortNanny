import Foundation

// MARK: - PortScanner
public class PortScanner {

    public enum ScanError: Error {
        case invalidOutput
        case commandFailed(Int32)
    }

    /// pid -> working directory, cached because PIDs are stable across
    /// refreshes. Guarded by `cwdLock`: the timer refresh and a link-initiated
    /// kill can scan on different queues at the same time.
    private var cwdCache: [Int: String] = [:]
    private let cwdLock = NSLock()

    /// True when the last scan had to shell out to lsof (libproc unavailable),
    /// so the UI can say why it is slower. Written from scan queues, read on
    /// main; guarded by `cwdLock`.
    private var usedFallback = false
    public var lastScanUsedFallback: Bool {
        cwdLock.lock()
        defer { cwdLock.unlock() }
        return usedFallback
    }

    private func setUsedFallback(_ value: Bool) {
        cwdLock.lock()
        usedFallback = value
        cwdLock.unlock()
    }

    /// How much enrichment a scan does. While nothing is on screen only the
    /// badge count and the watchlist consume the result, and they need six
    /// fields, not working directories, Docker names, or agent attribution.
    public enum ScanDepth {
        case light
        case full
    }

    /// Scans listening TCP ports and bound UDP sockets. `processes` supplies
    /// per-PID command, memory, and children so we don't shell out per port.
    public func scanActivePorts(processes: ProcessTable, depth: ScanDepth = .full) throws -> [PortInfo] {
        // Fast path: listeners gathered in the same native pass as the table.
        // nil means libproc is unavailable; an empty list is a real answer and
        // must not fall through to lsof on every refresh of a quiet machine.
        if let native = processes.listeners ?? NativeScanner.allListeners() {
            setUsedFallback(false)
            var raws: [RawListener] = []
            for listener in native {
                let raw = RawListener(
                    processName: processes.name(for: listener.pid) ?? "unknown",
                    pid: listener.pid,
                    user: processes.user(for: listener.pid) ?? "?",
                    host: listener.host,
                    port: listener.port,
                    proto: listener.proto,
                    connections: listener.connections
                )
                mergeListener(raw, into: &raws)
            }
            return buildPortInfos(raws, processes: processes, depth: depth)
        }

        // Fallback: the lsof pipeline
        if !lastScanUsedFallback {
            Log.scan.warning("libproc returned nothing; scanning through lsof")
        }
        setUsedFallback(true)
        return try scanWithLsof(processes: processes)
    }

    private func scanWithLsof(processes: ProcessTable) throws -> [PortInfo] {
        // -iTCP -sTCP:LISTEN: listening TCP sockets only; -n/-P: skip name lookups.
        // lsof exits 1 when nothing matches, so that's an empty list, not an error.
        let tcpOutput: String
        do {
            tcpOutput = try CommandRunner.run(
                "/usr/sbin/lsof",
                ["-iTCP", "-sTCP:LISTEN", "-n", "-P"],
                timeout: 5.0,
                allowedExitCodes: [0, 1]
            )
        } catch let error as CommandRunner.CommandError {
            if case .failed(_, let code, _) = error { throw ScanError.commandFailed(code) }
            throw ScanError.invalidOutput
        }

        // UDP has no LISTEN state; a UDP scan failure shouldn't fail the refresh.
        let udpOutput = (try? CommandRunner.run(
            "/usr/sbin/lsof", ["-iUDP", "-n", "-P"], timeout: 5.0, allowedExitCodes: [0, 1]
        )) ?? ""

        let tcp = parsePortOutput(tcpOutput, processes: processes, proto: "tcp")
        let udp = parsePortOutput(udpOutput, processes: processes, proto: "udp")
        return (tcp + udp).sorted { $0.port < $1.port }
    }

    struct RawListener {
        let processName: String
        let pid: Int
        let user: String
        var host: String
        let port: Int
        var proto: String = "tcp"
        var connections: Int = 0

        var isExposedHost: Bool {
            PortInfo.isWildcardHost(host)
        }
    }

    /// IPv4/IPv6 duplicates of the same (pid, port, proto) merge into one row;
    /// when one of them binds all interfaces, the merged row keeps that host
    /// so the "exposed" badge can't be masked.
    func mergeListener(_ raw: RawListener, into listeners: inout [RawListener]) {
        if let existing = listeners.firstIndex(where: {
            $0.port == raw.port && $0.pid == raw.pid && $0.proto == raw.proto
        }) {
            if raw.isExposedHost && !listeners[existing].isExposedHost {
                listeners[existing].host = raw.host
            }
            // Each address family's row already carries the per-port total.
            listeners[existing].connections = max(listeners[existing].connections, raw.connections)
            return
        }
        listeners.append(raw)
    }

    /// Parses lsof output into PortInfo objects
    public func parsePortOutput(_ output: String, processes: ProcessTable, proto: String = "tcp") -> [PortInfo] {
        let lines = output.components(separatedBy: "\n")

        // Format of lsof output:
        // COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        // node    12345 user   23u  IPv4 0x...      0t0  TCP *:3000 (LISTEN)

        // Pass 1: collect raw listeners, merging IPv4/IPv6 duplicates of the
        // same (pid, port). When one duplicate binds all interfaces, the merged
        // row keeps that host so the "exposed" badge can't be masked.
        var listeners: [RawListener] = []

        for line in lines.dropFirst() { // Skip header
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 9 else { continue }

            let processName = String(components[0])
            guard let pid = Int(components[1]) else { continue }
            let user = String(components[2])

            guard let endpoint = extractEndpoint(from: components) else { continue }

            // UDP: ephemeral high ports are outgoing sockets (QUIC etc.),
            // not servers anyone would look for.
            if proto == "udp" && endpoint.port >= 49152 {
                continue
            }

            let raw = RawListener(
                processName: processName, pid: pid, user: user,
                host: endpoint.host, port: endpoint.port, proto: proto
            )
            mergeListener(raw, into: &listeners)
        }

        return buildPortInfos(listeners, processes: processes)
    }

    /// Enriches raw listeners with process details from the shared snapshot.
    private func buildPortInfos(_ listeners: [RawListener], processes: ProcessTable, depth: ScanDepth = .full) -> [PortInfo] {
        let isFull = depth == .full
        if isFull {
            refreshWorkingDirectories(for: listeners.map { $0.pid }, processes: processes)
            let dockerPresent = listeners.contains { $0.processName.lowercased().contains("docker") }
            DockerService.shared.refreshInBackground(dockerPresent: dockerPresent)
        }

        // One read of the leases per scan; a listener on a leased port shows it.
        let leases = isFull ? Dictionary(ReservationStore.shared.recent().map { ($0.port, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        let ports = listeners.map { raw -> PortInfo in
            let rawCommand = processes.command(for: raw.pid) ?? ""
            // Classification sees the raw arguments; everything downstream
            // (rows, JSON, history) gets the redacted line.
            // printable as well as redacted: a process can name itself with
            // escape sequences that would spoof a terminal reading `list`.
            let command = CommandRedaction.printable(CommandRedaction.redact(rawCommand))
            let processName = CommandRedaction.printable(Self.bestProcessName(lsofName: raw.processName, entryName: processes.name(for: raw.pid)))
            let memoryKb = processes.rssKB(for: raw.pid) ?? 0
            let memory = memoryKb > 0 ? MemoryFormat.string(kilobytes: memoryKb) : "N/A"
            let children = isFull ? processes.children(of: raw.pid).map {
                PortInfo.ProcessInfo(pid: $0.pid, name: CommandRedaction.printable($0.name),
                                     command: CommandRedaction.printable(CommandRedaction.redact($0.command)))
            } : []
            let projectPath = isFull ? projectWorthyPath(cachedWorkingDirectory(raw.pid)) : nil

            let type = determinePortType(processName: processName, command: rawCommand)
            let containerName = isFull ? DockerService.shared.getContainerName(forPort: raw.port) : nil
            // Servers have a port their project meant for them; databases,
            // Docker, and editor helpers do not.
            var expectedPort: ExpectedPort?
            let couldDrift = type.category == .web || type == .other
            if isFull, couldDrift, let projectPath {
                expectedPort = ProjectConfig.drift(from: ProjectConfig.shared.expectedPorts(in: projectPath), actual: raw.port)
            }
            return PortInfo(
                port: raw.port,
                pid: raw.pid,
                processName: processName,
                command: command,
                user: raw.user,
                memoryUsage: memory,
                memorySizeKB: memoryKb,
                type: type,
                projectName: projectPath.map { ($0 as NSString).lastPathComponent } ?? extractProjectName(command: rawCommand),
                projectPath: projectPath,
                containerName: containerName,
                children: children.isEmpty ? nil : children,
                bindAddress: raw.host,
                proto: raw.proto,
                cpuPercent: processes.cpuPercent(for: raw.pid) ?? 0,
                age: processes.ageSeconds(for: raw.pid).flatMap { ElapsedFormat.humanize(seconds: $0) },
                agentOwner: isFull ? agentOwner(for: raw, type: type, containerName: containerName, processes: processes) : nil,
                connections: raw.connections,
                managedBy: isFull ? ManagedRuntime.detect(pid: raw.pid, containerName: containerName, type: type, in: processes) : nil,
                reservation: leases[raw.port],
                expectedPort: expectedPort
            )
        }

        return ports.sorted { $0.port < $1.port }
    }

    /// A port fronted by Docker belongs to the container, not to whoever
    /// happened to launch Docker Desktop (its env would say so forever).
    private func agentOwner(for raw: RawListener, type: PortInfo.PortType, containerName: String?, processes: ProcessTable) -> AgentOwner? {
        let isDockerFronted = containerName != nil || type == .docker
        if isDockerFronted { return nil }
        return AgentAttribution.owner(ofPid: raw.pid, in: processes)
    }

    // MARK: - Working directories

    /// Resolves working directories for PIDs not yet cached (native syscall
    /// first, one lsof batch as fallback) and drops entries for dead PIDs.
    private func refreshWorkingDirectories(for pids: [Int], processes: ProcessTable) {
        cwdLock.lock()
        let live = Set(pids)
        cwdCache = cwdCache.filter { live.contains($0.key) }
        var missing = pids.filter { cwdCache[$0] == nil }
        for pid in missing {
            if let path = NativeScanner.workingDirectory(Int32(pid)) {
                cwdCache[pid] = path
            }
        }
        // Other users' processes (root daemons) can't be read by lsof either,
        // so asking would only fork a subprocess that returns nothing.
        let me = getuid()
        missing = missing.filter { cwdCache[$0] == nil && (processes.uid(for: $0) ?? me) == me }
        cwdLock.unlock()

        // The subprocess runs outside the lock so a concurrent scan isn't
        // held for up to three seconds.
        var resolved: [Int: String] = [:]
        if !missing.isEmpty {
            let pidList = missing.map(String.init).joined(separator: ",")
            // -Fn machine format: "p<pid>" line, then "n<path>" line per file
            let output = (try? CommandRunner.run(
                "/usr/sbin/lsof", ["-a", "-p", pidList, "-d", "cwd", "-Fn"],
                timeout: 3.0, allowedExitCodes: [0, 1]
            )) ?? ""
            resolved = Self.parseCwdOutput(output)
        }

        cwdLock.lock()
        for (pid, path) in resolved {
            cwdCache[pid] = path
        }
        // Negative-cache misses so we don't re-query them every refresh
        for pid in pids where cwdCache[pid] == nil {
            cwdCache[pid] = ""
        }
        cwdLock.unlock()
    }

    private func cachedWorkingDirectory(_ pid: Int) -> String? {
        cwdLock.lock()
        defer { cwdLock.unlock() }
        return cwdCache[pid]
    }

    public static func parseCwdOutput(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var currentPid: Int?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("p") {
                currentPid = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    /// A cwd only counts as a "project" when it's a real directory the user
    /// would recognize: not /, not the bare home folder.
    private func projectWorthyPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path == "/" || path == NSHomeDirectory() {
            return nil
        }
        return path
    }

    private func extractEndpoint(from lsofLineComponents: [Substring]) -> (host: String, port: Int)? {
        for token in lsofLineComponents.reversed() {
            // Connected sockets ("1.2.3.4:5->6.7.8.9:443") aren't listeners
            guard !token.contains("->") else { continue }
            guard token.contains(":"), let lastColon = token.lastIndex(of: ":") else { continue }

            let digits = token[token.index(after: lastColon)...]
                .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            guard let port = Int(digits) else { continue }

            // "[::1]:8080" -> "::1", "*:3000" -> "*", "127.0.0.1:3000" -> "127.0.0.1"
            let host = String(token[..<lastColon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return (host, port)
        }
        return nil
    }

    /// One rule per line, checked in order: the first match wins. Editors
    /// come first because their names would otherwise substring-match the
    /// runtime keywords further down ("Code Helper" is not a Go server).
    /// Runtimes match on the executable's base name, never on substrings of
    /// the whole command ("go" used to classify Google Chrome as Go).
    private static let typeRules: [(type: PortInfo.PortType, matches: (ProcessSignals) -> Bool)] = [
        (.ide, { KnownEditors.matches($0.processName) }),
        (.nodejs, { ["node", "npm", "npx", "yarn", "pnpm", "next", "vite", "webpack", "bun", "deno"].contains($0.executable) }),
        // docker-proxy is intentionally not a database: it fronts published
        // ports and is classified as .docker below, container name attached.
        (.database, { signals in
            ["postgres", "mysqld", "mysql", "mongod", "redis-server", "mariadbd", "mariadb"]
                .contains { signals.executable == $0 || signals.processLower.contains($0) }
        }),
        (.webserver, { signals in ["apache", "nginx", "httpd", "caddy"].contains { signals.processLower.contains($0) } }),
        (.python, { $0.executable.hasPrefix("python") || $0.executable == "gunicorn" || $0.executable == "uvicorn" }),
        (.java, { $0.executable == "java" || $0.commandLower.contains("gradle") }),
        (.ruby, { $0.executable == "ruby" || $0.commandLower.contains("rails") }),
        (.php, { $0.executable.hasPrefix("php") }),
        (.go, { $0.executable == "go" || $0.commandLower.hasPrefix("go run ") }),
        (.docker, { $0.processLower.contains("docker") || $0.processLower.contains("com.docker") }),
    ]

    private struct ProcessSignals {
        let processName: String
        let processLower: String
        let commandLower: String
        let executable: String
    }

    public func determinePortType(processName: String, command: String) -> PortInfo.PortType {
        let signals = ProcessSignals(
            processName: processName,
            processLower: processName.lowercased(),
            commandLower: command.lowercased(),
            executable: executableName(processName: processName, command: command)
        )
        return Self.typeRules.first { $0.matches(signals) }?.type ?? .other
    }

    /// lsof truncates COMMAND to ~9 chars ("com.docke"). When the ps snapshot
    /// has the full executable name and it extends the truncated one, use it.
    public static func bestProcessName(lsofName: String, entryName: String?) -> String {
        guard let entryName, entryName.count > lsofName.count else { return lsofName }
        return entryName.lowercased().hasPrefix(lsofName.lowercased()) ? entryName : lsofName
    }

    /// argv[0] split on spaces truncates a path that contains one
    /// ("/Users/me/Library/Application Support/fnm/.../node"), so an absolute
    /// path defers to the kernel's own name for the process.
    private func executableName(processName: String, command: String) -> String {
        let firstToken = command.split(separator: " ").first.map(String.init) ?? ""
        let kernelName = processName.lowercased()
        let looksLikeAPath = firstToken.hasPrefix("/")
        let kernelNameIsUseful = !kernelName.isEmpty && kernelName != "unknown"
        if looksLikeAPath, kernelNameIsUseful, !firstToken.hasSuffix("/" + kernelName) {
            return kernelName
        }
        let base = firstToken.split(separator: "/").last.map(String.init) ?? ""
        return (base.isEmpty ? processName : base).lowercased()
    }

    /// One-off child lookup (used by tests and ad-hoc callers).
    /// Bulk work should use a shared ProcessTable instead.
    public func getChildProcesses(pid: Int) -> [PortInfo.ProcessInfo] {
        ProcessTable.capture().children(of: pid).map {
            PortInfo.ProcessInfo(pid: $0.pid, name: $0.name, command: $0.command)
        }
    }

    /// Extracts project name from command (if running from a project directory)
    private func extractProjectName(command: String) -> String? {
        let components = command.components(separatedBy: "/")
        for (index, component) in components.enumerated() {
            if ["projects", "workspace", "dev", "code"].contains(component.lowercased()) {
                if index + 1 < components.count {
                    return components[index + 1]
                }
            }
        }
        return nil
    }
}
