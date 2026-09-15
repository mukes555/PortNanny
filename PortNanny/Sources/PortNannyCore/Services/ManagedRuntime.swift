import Foundation

/// A supervisor that would undo a plain kill of a listener: it restarts the
/// process (pm2, a launchd job, nodemon and other reloaders) or fronts it (a
/// Docker container). Knowing it turns "kill" into the verb that actually
/// frees the port.
public struct ManagedRuntime: Codable, Equatable {
    public enum Kind: String, Codable {
        case pm2
        case launchd
        case docker
        /// nodemon, `next dev`, `uvicorn --reload`, a gunicorn master: a
        /// parent that respawns the listener when it exits.
        case reloader
    }

    public let kind: Kind
    /// pm2 app name or id, launchd label, container name, or the reloader's name.
    public let name: String
    /// The process to stop instead of the listener, for reloaders and masters.
    public let supervisorPid: Int?
    public let supervisorName: String?
    /// What a person or agent runs instead of a kill, when a command exists,
    /// as argv and in display form.
    public let stopArguments: [String]?
    public let stopCommand: String?

    public init(kind: Kind, name: String, supervisorPid: Int? = nil, supervisorName: String? = nil, stop: [String]? = nil) {
        self.kind = kind
        self.name = name
        self.supervisorPid = supervisorPid
        self.supervisorName = supervisorName
        self.stopArguments = stop
        self.stopCommand = stop.map { $0.map(ManagedRuntime.shellQuoted).joined(separator: " ") }
    }

    /// Chip text: "pm2", "launchd", "container", "nodemon", "next dev".
    public var short: String {
        switch kind {
        case .docker: return "container"
        case .reloader: return name
        case .pm2, .launchd: return kind.rawValue
        }
    }

    /// "pm2 app api", "launchd job homebrew.mxcl.redis", "container web-1",
    /// "nodemon (PID 700)".
    public var label: String {
        switch kind {
        case .pm2: return "pm2 app \(name)"
        case .launchd: return "launchd job \(name)"
        case .docker: return "container \(name)"
        case .reloader: return supervisorPid.map { "\(name) (PID \($0))" } ?? name
        }
    }

    /// The verb for a graceful stop, or for --force: Docker's backend is never
    /// the thing to kill, so force means `docker kill` for the container.
    public func stopArguments(force: Bool) -> [String]? {
        guard let stopArguments else { return nil }
        if force, kind == .docker, let name = stopArguments.last { return ["docker", "kill", "--", name] }
        return stopArguments
    }

    public func stopCommand(force: Bool) -> String? {
        stopArguments(force: force).map { $0.map(ManagedRuntime.shellQuoted).joined(separator: " ") }
    }

    /// Why a plain kill is the wrong verb.
    public var consequence: String {
        switch kind {
        case .pm2: return "pm2 would restart it"
        case .launchd: return "launchd would restart it"
        case .docker: return "Docker publishes the port and the container would keep running"
        case .reloader: return "\(name) would restart it"
        }
    }
}

// MARK: - Detection

extension ManagedRuntime {

    struct ReloaderSignature {
        let name: String
        let matches: (_ commandLower: String, _ executableName: String) -> Bool
    }

    /// Parents that respawn their child. Matched on the parent's command
    /// line, so a project folder named "nodemon" does not count.
    static let reloaders: [ReloaderSignature] = [
        ReloaderSignature(name: "nodemon") { cmd, _ in cmd.contains("nodemon") },
        ReloaderSignature(name: "next dev") { cmd, _ in
            let isNextBinary = cmd.contains("/next/dist/bin/next") && cmd.contains(" dev")
            return isNextBinary || cmd.hasSuffix("next dev")
        },
        ReloaderSignature(name: "uvicorn --reload") { cmd, _ in cmd.contains("uvicorn") && cmd.contains("--reload") },
        ReloaderSignature(name: "fastapi dev") { cmd, _ in cmd.contains("fastapi") && cmd.contains(" dev") },
        ReloaderSignature(name: "watch mode") { cmd, _ in
            cmd.contains(" --watch") || cmd.contains(" --hot") || cmd.contains("tsx watch") || cmd.contains("ts-node-dev") || cmd.contains("dotnet watch")
        },
        ReloaderSignature(name: "watchexec") { cmd, _ in cmd.contains("watchexec") },
        ReloaderSignature(name: "cargo watch") { cmd, _ in cmd.contains("cargo-watch") || cmd.contains("cargo watch") },
        ReloaderSignature(name: "air") { _, exe in exe == "air" },
        ReloaderSignature(name: "forever") { cmd, _ in cmd.contains("/forever") || cmd.hasPrefix("forever ") },
        ReloaderSignature(name: "supervisord") { cmd, _ in cmd.contains("supervisord") },
        ReloaderSignature(name: "artisan serve") { cmd, _ in cmd.contains("artisan serve") },
        ReloaderSignature(name: "gunicorn") { cmd, exe in exe == "gunicorn" || cmd.contains("/gunicorn") },
        ReloaderSignature(name: "puma") { cmd, exe in exe == "puma" || cmd.contains("puma: cluster") },
        ReloaderSignature(name: "nginx") { _, exe in exe == "nginx" },
    ]

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
    static let ancestorsConsidered = 4

    /// The supervisor of `pid`, if any. Docker first, then the outermost
    /// pm2 or launchd job (they would restart a reloader too), then the
    /// nearest reloader or a parent running the very same command line
    /// (Flask's and Django's reloaders, gunicorn's master).
    public static func detect(pid: Int, containerName: String?, type: PortInfo.PortType, in processes: ProcessTable,
                              launchdLabel: (Int) -> String? = { LaunchdJobs.shared.label(forPid: $0) },
                              pm2Facts: (Int) -> [String: String] = pm2Environment) -> ManagedRuntime? {
        if let containerName {
            return ManagedRuntime(kind: .docker, name: containerName, stop: ["docker", "stop", "--", containerName])
        }
        if type == .docker {
            return ManagedRuntime(kind: .docker, name: "Docker Desktop")
        }

        let chain = ancestors(of: pid, in: processes)
        if chain.contains(where: { isPM2Daemon($0.command) }) {
            return pm2(for: pid, facts: pm2Facts(pid))
        }
        let jobRoot = chain.last?.ppid == 1 ? chain.last?.pid : (processes.ppid(for: pid) == 1 ? pid : nil)
        if let jobRoot, let label = launchdLabel(jobRoot), isServiceLabel(label) {
            return ManagedRuntime(kind: .launchd, name: label, supervisorPid: jobRoot, supervisorName: processes.name(for: jobRoot), stop: launchdStop(label: label))
        }
        for ancestor in chain {
            let lower = ancestor.command.lowercased()
            if let signature = reloaders.first(where: { $0.matches(lower, ancestor.name) }) {
                return ManagedRuntime(kind: .reloader, name: signature.name, supervisorPid: ancestor.pid, supervisorName: ancestor.name)
            }
        }
        if let parent = chain.first, let mine = processes.command(for: pid), parent.command == mine {
            return ManagedRuntime(kind: .reloader, name: "\(parent.name) reloader", supervisorPid: parent.pid, supervisorName: parent.name)
        }
        return nil
    }

    struct Ancestor {
        let pid: Int
        let ppid: Int
        let name: String
        let command: String
    }

    /// Up to four non-shell ancestors, nearest first. A shell that carries
    /// a signature (`sh -c "nodemon ..."`) is kept.
    static func ancestors(of pid: Int, in processes: ProcessTable) -> [Ancestor] {
        var chain: [Ancestor] = []
        var current = processes.ppid(for: pid)
        var seen = Set<Int>()
        while let next = current, next > 1, !seen.contains(next), chain.count < ancestorsConsidered {
            seen.insert(next)
            let name = processes.name(for: next) ?? "?"
            // tmux, screen and sshd are where the session ends, not supervisors
            // of what runs inside it. A tmux server keeps the argv of the
            // command that opened the session, so `tmux new -s build tsc
            // --watch` read as a reloader: killing one supervised port then
            // took the whole tmux server down, every pane and editor with it.
            if AgentSignatures.attributionBarriers.contains(name) { break }
            let command = processes.command(for: next) ?? ""
            let ppid = processes.ppid(for: next) ?? 0
            let lower = command.lowercased()
            let plainShell = shells.contains(name) && !reloaders.contains { $0.matches(lower, name) }
            if !plainShell {
                chain.append(Ancestor(pid: next, ppid: ppid, name: name, command: command))
            }
            current = ppid
        }
        return chain
    }

    /// LaunchServices registers every app it opens as `application.<bundle>.<n>`
    /// and Apple's own agents are `com.apple.*`; neither is a service someone
    /// would stop with launchctl. What is left: Homebrew services and the
    /// user's own LaunchAgents.
    static func isServiceLabel(_ label: String) -> Bool {
        !label.hasPrefix("application.") && !label.hasPrefix("com.apple.")
    }

    /// pm2's daemon names itself "PM2 v5.3.0: God Daemon (/Users/me/.pm2)".
    static func isPM2Daemon(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.hasPrefix("pm2 ") && lower.contains("god daemon")
    }

    /// pm2 stamps its children with the app's `name` and `pm_id`.
    public static func pm2Environment(_ pid: Int) -> [String: String] {
        NativeScanner.environmentMarkers(Int32(pid), keys: ["name", "pm_id"])
    }

    /// The app id or name comes out of the target's own environment, so it
    /// is only ever handed to pm2 when it can be nothing but an app: a number,
    /// or a plain name that is not a flag and not pm2's "all".
    static func pm2(for pid: Int, facts: [String: String]) -> ManagedRuntime {
        if let name = facts["name"].flatMap(pm2SafeName) {
            return ManagedRuntime(kind: .pm2, name: name, stop: ["pm2", "stop", name])
        }
        if let id = facts["pm_id"], !id.isEmpty, id.allSatisfy(\.isNumber) {
            return ManagedRuntime(kind: .pm2, name: "app \(id)", stop: ["pm2", "stop", id])
        }
        return ManagedRuntime(kind: .pm2, name: "an app `pm2 list` can name")
    }

    static func pm2SafeName(_ raw: String) -> String? {
        let name = raw.prefix(64)
        let safe = !name.isEmpty && name.first != "-" && name.lowercased() != "all"
            && name.allSatisfy { $0.isLetter || $0.isNumber || "._@:-".contains($0) }
        return safe ? String(name) : nil
    }

    /// Homebrew services are launchd jobs too; `brew services` is the verb
    /// people know, and it keeps the job from coming back at login.
    static func launchdStop(label: String) -> [String] {
        let brewPrefix = "homebrew.mxcl."
        if label.hasPrefix(brewPrefix) {
            return ["brew", "services", "stop", String(label.dropFirst(brewPrefix.count))]
        }
        return ["launchctl", "bootout", "gui/\(getuid())/\(label)"]
    }

    /// Ports still listening after `timeout`, polled through the native
    /// scanner; the CLI's `wait` and the stop verbs share it.
    public static func waitForPortsFree(_ ports: [Int], timeout: TimeInterval) -> Set<Int> {
        var busy = Set(ports)
        let deadline = Date().addingTimeInterval(timeout)
        // One look before the clock: `--timeout 0` asks "is it free now?".
        repeat {
            let listening = Set((NativeScanner.allListeners() ?? []).map(\.port))
            // A port only this user's scan cannot see is still taken: asking the
            // kernel keeps `wait` from calling another user's server free.
            busy = busy.filter { listening.contains($0) || PortProbe.isHeld($0) }
            if busy.isEmpty { break }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while true
        return busy
    }

    static func shellQuoted(_ value: String) -> String {
        let safe = value.allSatisfy { $0.isLetter || $0.isNumber || "._-@:+/".contains($0) }
        return safe ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// pid -> label from `launchctl list`, read at most every fifteen seconds
/// and only when a listener sits directly under launchd.
public final class LaunchdJobs {
    public static let shared = LaunchdJobs()

    private var labelsByPid: [Int: String] = [:]
    private var fetchedAt = Date.distantPast
    private let lock = NSLock()

    public func label(forPid pid: Int) -> String? {
        lock.lock()
        let stale = Date().timeIntervalSince(fetchedAt) > 15
        if stale { fetchedAt = Date() } // one refresher at a time; others use the old table
        let table = labelsByPid
        lock.unlock()
        guard stale else { return table[pid] }

        // The subprocess runs outside the lock, so a concurrent scan is not
        // held for up to three seconds behind it.
        let output = (try? CommandRunner.run("/bin/launchctl", ["list"], timeout: 3.0)) ?? ""
        let fresh = Self.parse(output)
        lock.lock()
        labelsByPid = fresh
        lock.unlock()
        return fresh[pid]
    }

    /// "PID\tStatus\tLabel" per line; a dash for jobs not running.
    static func parse(_ output: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            map[pid] = String(parts[2])
        }
        return map
    }
}
