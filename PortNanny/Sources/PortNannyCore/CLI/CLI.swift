import Foundation

/// The command-line commands, shared by the standalone `portnanny`
/// executable (bundled as Contents/Helpers/portnanny, which Homebrew links
/// onto PATH) and by the app binary when it is invoked with a subcommand.
public enum PortNannyCLI {

    /// Returns an exit code when the arguments were a CLI invocation,
    /// or nil to continue launching the GUI.
    public static func run(_ arguments: [String]) -> Int32? {
        PreferencesMigration.runIntoSharedDomain()
        Policy.loadFromSharedDomain()
        guard let parsed = CLIArguments.parse(arguments) else { return nil }

        switch parsed {
        case .failure(let error):
            printError("portnanny: \(error.message)\nRun `portnanny help` for usage.")
            return CLIExit.usage
        case .success(.list(let options)):
            return list(options)
        case .success(.kill(let options)):
            return CLIKill.run(options)
        case .success(.whoami(let json)):
            return whoami(json: json)
        case .success(.agents(let json)):
            return CLIAgents.run(json: json)
        case .success(.wait(let port, let timeout, let json)):
            return wait(port: port, timeout: timeout, json: json)
        case .success(.open(let port)):
            // /usr/bin/open keeps AppKit out of the CLI binary.
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["http://localhost:\(port)"]
            try? opener.run()
            return CLIExit.ok
        case .success(.history(let options)):
            return history(options)
        case .success(.help(let topic)):
            print(CLIArguments.usage(for: topic))
            return CLIExit.ok
        case .success(.version(let json)):
            return version(json: json)
        case .success(.agentDocs(let options)):
            return AgentDocsInstaller.run(options)
        case .success(.mcp):
            return MCPServer().serve()
        case .success(.mcpSetup(let agent)):
            print(MCPSetup.instructions(for: agent))
            return CLIExit.ok
        case .success(.doctor(let json, let agents)):
            return agents ? DoctorAgents.run(json: json) : doctor(json: json)
        case .success(.whois(let options)):
            return CLIWhois.run(options)
        case .success(.reserve(let options)):
            return CLIReserve.reserve(options)
        case .success(.release(let port, let force, let json)):
            return CLIReserve.release(port: port, force: force, json: json)
        case .success(.reservations(let json)):
            return CLIReserve.list(json: json)
        case .success(.exec(let options)):
            return CLIExec.run(options)
        case .success(.drift(let json)):
            return CLIDrift.run(json: json)
        case .success(.setup(let options)):
            return CLISetup.run(options)
        case .success(.completions(let shell)):
            print(CLICompletions.script(for: shell) ?? "")
            return CLIExit.ok
        case .success(.freePort(let prefer, let range, let json)):
            return freePort(prefer: prefer, range: range, json: json)
        case .success(.schema(let command)):
            return schema(for: command)
        case .success(.serve(let port)):
            return DebugServer.serve(port: port)
        }
    }

    // MARK: - Shared helpers

    public struct Scan {
        let ports: [PortInfo]
        let table: ProcessTable
        let caller: AgentOwner?
    }

    /// One scan plus the caller's own identity, which the guard compares
    /// against each target's owner. Container names come from a synchronous
    /// `docker ps` only when asked, because it costs about a tenth of a
    /// second; `kill` asks for it only once it has a container in its sights.
    public static func scan(refreshDocker: Bool) -> Scan {
        let table = ProcessTable.capture()
        if refreshDocker {
            let listeningPids = Set(table.listeners?.map(\.pid) ?? [])
            let dockerPresent = listeningPids.contains { table.name(for: $0)?.lowercased().contains("docker") == true }
            DockerService.shared.refreshNow(dockerPresent: dockerPresent)
        }
        let ports = (try? PortScanner().scanActivePorts(processes: table)) ?? []
        let callerPid = Int(Foundation.ProcessInfo.processInfo.processIdentifier)
        let caller = AgentAttribution.callerOwner(callerPid: callerPid, in: table)
        return Scan(ports: ports, table: table, caller: caller)
    }

    /// `FileHandle.write(_:)` raises an uncatchable exception when stderr is
    /// closed, which a parent process is free to do; the throwing variant
    /// reports it instead, and a message nobody can read is not worth dying for.
    public static func printError(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
    }

    /// False when encoding failed: a JSON consumer must never see exit 0 with
    /// empty output.
    @discardableResult
    public static func printJSON<T: Encodable>(_ value: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            printError("portnanny: could not encode output as JSON")
            return false
        }
        print(text)
        return true
    }

    public static var stdoutIsTerminal: Bool { isatty(1) != 0 }

    public struct VersionReport: Encodable {
        let schema = 1
        let version: String
        let bundleIdentifier = "com.mukes555.PortNanny"
        let installSource: String
        let architecture: String
        /// Which preference domain this build reads and writes. A test
        /// harness can compare it against the throwaway domain it asked for
        /// and stop before it writes into the person's real store, and posts
        /// real refusal banners at them.
        let defaultsDomain = HistoryManager.appSuiteName
    }

    private static func version(json: Bool) -> Int32 {
        let version = UpdateChecker.currentVersion ?? "dev"
        guard json else {
            print(version)
            return CLIExit.ok
        }
        let arch = Diagnostics.report().first { $0.label == "Architecture" }?.value ?? "unknown"
        let report = VersionReport(version: version, installSource: InstallSource.detect().rawValue, architecture: arch)
        return printJSON(report) ? CLIExit.ok : CLIExit.internalError
    }

    // MARK: - free-port

    public struct FreePortReport: Encodable {
        public let schema = 1
        public let port: Int?
        public let preferred: Int
        public let range: String
        public let exitCode: Int32
    }

    /// The first port nothing listens on that can be bound right now. A bind
    /// probe catches what the listener table can't see (another user's
    /// socket, a port in TIME_WAIT with SO_REUSEADDR off).
    public static func firstFreePort(prefer: Int, range: ClosedRange<Int>, listening: Set<Int>, probe: Bool = true) -> Int? {
        func isFree(_ port: Int) -> Bool { !listening.contains(port) && (!probe || PortProbe.canBind(port)) }
        if isFree(prefer) { return prefer }
        return range.lazy.filter { $0 != prefer }.first(where: isFree)
    }

    private static func freePort(prefer: Int, range: ClosedRange<Int>, json: Bool) -> Int32 {
        let listening = Set((NativeScanner.allListeners() ?? []).map(\.port))
        // Another live lease is as good as taken; our own is not.
        let reserved = ReservationStore.appStore().portsReservedByOthers(for: callerIdentity())
        let port = firstFreePort(prefer: prefer, range: range, listening: listening.union(reserved))
        let exit = port == nil ? CLIExit.notFound : CLIExit.ok
        if json {
            let report = FreePortReport(port: port, preferred: prefer, range: "\(range.lowerBound)-\(range.upperBound)", exitCode: exit)
            return printJSON(report) ? exit : CLIExit.internalError
        }
        if let port {
            print(port) // just the number, so `PORT=$(portnanny free-port)` works
        } else {
            printError("no free port in \(range.lowerBound)-\(range.upperBound)")
        }
        return exit
    }

    // MARK: - schema

    private static func schema(for command: String?) -> Int32 {
        guard let text = OutputSchemas.render(command) else {
            printError("portnanny: no schema for '\(command ?? "")'. Known: \(OutputSchemas.commands.joined(separator: ", "))")
            return CLIExit.usage
        }
        print(text)
        return CLIExit.ok
    }

    // MARK: - doctor

    private static func doctor(json: Bool) -> Int32 {
        let lines = Diagnostics.report()
        if json {
            let object = Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0.value) })
            return printJSON(object) ? CLIExit.ok : CLIExit.internalError
        }
        for line in lines {
            print("\(line.label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(line.value)")
        }
        return CLIExit.ok
    }

    // MARK: - list

    private static func list(_ options: CLICommand.ListOptions) -> Int32 {
        let scan = scan(refreshDocker: true)
        if options.mine && scan.caller == nil {
            // An empty list would read as "no servers"; the truth is "not identified".
            printError("portnanny: you are not identified as an AI agent, so nothing can be \"mine\". Run `portnanny whoami`, or export PORTNANNY_OWNER=<name>.")
            if options.json { print("[]") }
            return CLIExit.notFound
        }
        let ports = filtered(scan.ports, by: options, caller: scan.caller)

        if options.json {
            // The array shape is a stable contract scripts depend on; new
            // fields are only ever added.
            return printJSON(ports) ? CLIExit.ok : CLIExit.internalError
        }

        if ports.isEmpty {
            print(scan.ports.isEmpty ? "No listening ports found." : "No ports match that filter.")
            return CLIExit.ok
        }

        // Piped output gets rows only, so `portnanny list | grep 3000` is clean.
        if stdoutIsTerminal {
            print("PORT   PROTO  PID     PROCESS               MEMORY    AGENT                 BIND")
        }
        for port in ports {
            let line = [
                ":\(port.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
                port.proto.padding(toLength: 7, withPad: " ", startingAt: 0),
                "\(port.pid)".padding(toLength: 8, withPad: " ", startingAt: 0),
                port.processName.padding(toLength: 22, withPad: " ", startingAt: 0),
                port.memoryUsage.padding(toLength: 10, withPad: " ", startingAt: 0),
                (port.agentOwner?.label ?? "-").padding(toLength: 22, withPad: " ", startingAt: 0),
                port.bindAddress ?? ""
            ].joined()
            print(line)
        }
        return CLIExit.ok
    }

    public static func filtered(_ ports: [PortInfo], by options: CLICommand.ListOptions, caller: AgentOwner?) -> [PortInfo] {
        if options.unowned {
            return ports.filter { $0.agentOwner == nil }
        }
        if options.orphaned {
            return ports.filter { $0.agentOwner?.sessionEnded == true }
        }
        if let agent = options.agent {
            let wanted = AgentSignatures.canonicalName(agent)
            return ports.filter { $0.agentOwner?.name == wanted }
        }
        if options.mine {
            guard let caller else { return [] }
            // "Mine" means exactly what kill would let me stop without --force.
            return ports.filter { port in
                guard let owner = port.agentOwner, owner.name == caller.name else { return false }
                return KillDecision.forAgent(caller: caller, target: owner) == .allow
            }
        }
        return ports
    }

    // MARK: - whoami

    public struct WhoAmI: Encodable {
        let schema = 1
        let detected: Bool
        let owner: AgentOwner?
    }

    /// How the friendly-fire guard identifies this process. Only the ancestor
    /// chain matters (plus the session pid a marker may name), not the whole
    /// process table.
    public static func callerIdentity() -> AgentOwner? {
        let callerPid = Int(Foundation.ProcessInfo.processInfo.processIdentifier)
        let environment = Foundation.ProcessInfo.processInfo.environment
        let sessionPid = AgentSignatures.claudeSessionPid(in: environment)
        let table = ProcessTable.ancestry(of: callerPid, including: sessionPid.map { [$0] } ?? [])
        return AgentAttribution.callerOwner(callerPid: callerPid, in: table, environment: environment)
    }

    /// Prints how the friendly-fire guard identifies the calling process, so
    /// an agent can check itself before a kill is refused.
    private static func whoami(json: Bool) -> Int32 {
        let me = callerIdentity()

        if json {
            return printJSON(WhoAmI(detected: me != nil, owner: me)) ? CLIExit.ok : CLIExit.internalError
        }
        guard let me else {
            print("Not running under a known AI agent. Export PORTNANNY_OWNER=<name> to declare one.")
            return CLIExit.ok
        }
        let how = me.source == .declared ? "declared via PORTNANNY_OWNER" : "detected from \(me.source.rawValue)"
        let kind = me.confidence == .editorTerminal ? " (editor terminal: a person, except that another agent's running server needs --force)" : ""
        print("\(me.described), \(how)\(kind)")
        return CLIExit.ok
    }

    // MARK: - wait

    public struct WaitReport: Encodable {
        let schema = 1
        let port: Int
        let free: Bool
        let waitedSeconds: Double
        let exitCode: Int32
    }

    /// Blocks until nothing listens on the port, polling the native scanner.
    /// The CLI half of the app's "notify me when this frees up".
    public static func waitUntilFree(port: Int, timeout: TimeInterval) -> WaitReport {
        let start = Date()
        let isFree = ManagedRuntime.waitForPortsFree([port], timeout: timeout).isEmpty
        let waited = Date().timeIntervalSince(start)
        return WaitReport(port: port, free: isFree, waitedSeconds: (waited * 100).rounded() / 100,
                          exitCode: isFree ? CLIExit.ok : CLIExit.stillRunning)
    }

    private static func wait(port: Int, timeout: TimeInterval, json: Bool) -> Int32 {
        let report = waitUntilFree(port: port, timeout: timeout)
        if json {
            return printJSON(report) ? report.exitCode : CLIExit.internalError
        } else if report.free {
            print(":\(port) is free.")
        } else {
            printError(":\(port) is still in use after \(Int(timeout))s.")
        }
        return report.exitCode
    }

    // MARK: - history

    /// Kills recorded by the app and the CLI, newest first. This is how an
    /// agent finds out what happened to a server that vanished.
    private static func history(_ options: CLICommand.HistoryOptions) -> Int32 {
        let store = HistoryManager.appStore()
        var items = options.all ? store.events : store.history
        if let port = options.port {
            items = items.filter { $0.port == port }
        }
        items = Array(items.prefix(options.limit))

        if options.json {
            return printJSON(items) ? CLIExit.ok : CLIExit.internalError
        }
        if items.isEmpty {
            print(options.port.map { "No recorded kills on :\($0)." } ?? "No recorded kills.")
            return CLIExit.ok
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if stdoutIsTerminal {
            print("WHEN                 PORT   PROCESS               STARTED BY            KILLED BY")
        }
        for item in items {
            let line = [
                formatter.string(from: item.timestamp).padding(toLength: 21, withPad: " ", startingAt: 0),
                ":\(item.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
                item.processName.padding(toLength: 22, withPad: " ", startingAt: 0),
                (item.owner ?? "-").padding(toLength: 22, withPad: " ", startingAt: 0),
                (item.action == .refused ? "refused: " : "") + (item.killedBy ?? "-")
            ].joined()
            print(line)
        }
        return CLIExit.ok
    }

    // MARK: - agent-docs

    /// A snippet for CLAUDE.md / AGENTS.md. The guard only helps agents that
    /// call `portnanny kill` instead of reaching for lsof by reflex.
    public static let agentDocs = """
    ## Freeing ports

    Use PortNanny to stop whatever is on a port. Never run `kill -9 $(lsof -ti:PORT)`:
    other AI agents may be using that port, and PortNanny knows who owns what.

    - `portnanny free <port>` frees the port (SIGTERM, verified; exit 0 if it was
      already free). `portnanny kill <port> --dry-run` shows what would happen first.
    - Exit code 3 means the port belongs to another agent's running session, or to
      nobody PortNanny can name (most likely a person's server). The refusal is on
      stderr. Do not retry with `--force`; tell the user, or pick another port with
      `portnanny free-port --prefer 3000`. "Another Claude Code session" is still
      another session: it is not you. Servers you start are attributed to you
      automatically; if PortNanny can't see that, export PORTNANNY_OWNER first.
    - Exit code 6 means a supervisor (pm2, launchd, Docker, or a reloader such as
      nodemon) would undo a plain kill and its tool is not on PATH; stderr names
      the command to run instead. When the tool is there, PortNanny runs it.
    - `portnanny wait <port> --timeout 30` blocks until the port is free.
    - `portnanny list --json` lists every listener with its owning agent;
      `portnanny list --mine` shows only the ones you may stop. Use `--pid` when two
      processes share a port.
    - `portnanny whois <port>` explains who started a server and why PortNanny thinks
      so (ancestry, markers, declaration), and what `kill` would do for you.
    - `portnanny agents` is the room: every agent session here, the servers it is
      running, the ports it has reserved and not started on yet, and the sessions
      that have ended. Worth a look before you take a port someone else is about
      to use.
    - `portnanny exec --free-port --prefer 3000 -- npm run dev` picks a free port,
      exports PORT, leases the port for the run, and attributes the server to you.
      `portnanny reserve <port> --for 10m` leases a port you are about to use by
      hand (exit 3 when someone else holds it); `portnanny release <port>` gives it
      back. `free-port` and `exec` skip ports others have leased.
    - `portnanny drift` lists servers running somewhere other than where their
      project's .env, package.json, or vite.config says, and who holds that port.
    - `portnanny kill --orphaned` stops every server left behind by an agent session
      that has ended; safe for anyone, exit 0 when there is nothing to clean up.
    - `portnanny history --port <port>` shows who started and who stopped a server
      that has vanished.
    - `portnanny whoami` shows how PortNanny identifies you; `portnanny doctor
      --agents` shows how every tool is recognised. Codex, Windsurf and Trae leave
      no reliable marker: export `PORTNANNY_OWNER=<your name>` before starting
      servers so they are attributed to you, and `PORTNANNY_SESSION=<unique>` so
      two of your sessions are told apart.
    """
}
