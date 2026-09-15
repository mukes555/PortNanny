import Foundation

/// `portnanny exec`: a free port, a lease on it for the run, and an identity
/// the guard can see, then the command. `PORT` is exported, so
/// `portnanny exec --free-port -- npm run dev` just works, and a server
/// started this way is attributed even when its tool leaves no marker.
public enum CLIExec {

    public static func run(_ options: CLICommand.ExecOptions) -> Int32 {
        let scan = PortNannyCLI.scan(refreshDocker: false)
        let store = ReservationStore.appStore()
        let caller = scan.caller

        var environment = ProcessInfo.processInfo.environment
        let owner = options.owner ?? AgentSignatures.declaredOwner(in: environment) ?? caller?.name
        let session = options.session ?? AgentSignatures.declaredSession(in: environment) ?? caller?.sessionKey ?? caller?.sessionPid.map(String.init)

        let choice = takePort(options, scan: scan, store: store, caller: caller, owner: owner, session: session)
        guard case .ready(let port, let leased) = choice else {
            return choice == .refused ? CLIExit.refused : CLIExit.notFound
        }
        defer {
            // Only ever a lease this run took: releasing whatever happened to
            // be on the port handed the winner of a race its port back.
            if leased { _ = store.release(port: port, by: caller, force: true) }
        }

        environment["PORT"] = String(port)
        // Both spellings, so a script from the PortKilla days reads the same server.
        for key in [AgentSignatures.declaredOwnerKey, AgentSignatures.legacyDeclaredOwnerKey] where owner != nil { environment[key] = owner }
        for key in [AgentSignatures.declaredSessionKey, AgentSignatures.legacyDeclaredSessionKey] where session != nil { environment[key] = session }

        guard let executable = resolve(options.command[0]) else {
            PortNannyCLI.printError("portnanny: '\(options.command[0])' not found")
            return CLIExit.commandNotFound
        }
        if isatty(2) != 0 {
            let who = owner.map { " as \($0)" } ?? ""
            let leasedNote = leased ? ", leased for the run" : ""
            PortNannyCLI.printError("portnanny: PORT=\(port)\(who)\(leasedNote)")
        }
        return runChild(executable, arguments: Array(options.command.dropFirst()), environment: environment)
    }

    enum PortChoice: Equatable {
        case ready(port: Int, leased: Bool)
        /// A live lease on the port the person named.
        case refused
        case unavailable
    }

    /// The port the command will run on, and whether a lease was taken on it.
    ///
    /// Choosing a port means scanning, which is far too slow to do while
    /// holding the lease lock, so another agent can take the port in between.
    /// The loser used to run on the winner's port regardless, then release
    /// the winner's lease on the way out; now it tries the next free one.
    static func takePort(_ options: CLICommand.ExecOptions, scan: PortNannyCLI.Scan, store: ReservationStore,
                         caller: AgentOwner?, owner: String?, session: String?) -> PortChoice {
        let personNamedThePort = options.port != nil
        var lostToAnotherAgent: Set<Int> = []
        for _ in 0..<3 {
            guard let port = choosePort(options, scan: scan, store: store, caller: caller, avoiding: lostToAnotherAgent) else {
                return .unavailable
            }
            if let lease = store.reservation(for: port), !lease.isHeld(by: caller) {
                PortNannyCLI.printError(":\(port) is reserved by \(lease.describedHolder) \(lease.expiryDescription()). Wait, ask, or use --free-port.")
                guard !personNamedThePort else { return .refused }
                lostToAnotherAgent.insert(port)
                continue
            }
            guard options.reserve else { return .ready(port: port, leased: false) }

            // Pinned to exec's own pid: if exec is killed outright, the lease goes with it.
            let lease = Reservation(port: port, owner: owner ?? Reservation.currentUser, sessionKey: session, sessionPid: Int(getpid()),
                                    reason: "exec: \(CommandRedaction.redact(options.command.joined(separator: " ")).prefix(60))", ttl: Reservation.maxTTL)
            do {
                _ = try store.reserve(lease, by: caller)
                return .ready(port: port, leased: true)
            } catch {
                guard !personNamedThePort else {
                    // They asked for this port: run on it, without a lease.
                    PortNannyCLI.printError("portnanny: could not lease :\(port) (\(error)); running without a lease")
                    return .ready(port: port, leased: false)
                }
                lostToAnotherAgent.insert(port)
            }
        }
        PortNannyCLI.printError("portnanny: other agents took every port offered; try again")
        return .unavailable
    }

    /// --port must be free; --free-port takes the first free one that no
    /// other live lease claims.
    static func choosePort(_ options: CLICommand.ExecOptions, scan: PortNannyCLI.Scan, store: ReservationStore,
                           caller: AgentOwner?, avoiding contested: Set<Int> = []) -> Int? {
        if let wanted = options.port {
            if let occupant = scan.ports.first(where: { $0.port == wanted }) {
                PortNannyCLI.printError(":\(wanted) is in use by \(occupant.processName) (PID \(occupant.pid))" + (occupant.agentOwner.map { ", \($0.label)" } ?? "") + ". Run `portnanny whois \(wanted)`, or use --free-port.")
                return nil
            }
            // Another user's server is invisible to the scan but would still
            // take the bind away from the command about to run.
            if PortProbe.isHeld(wanted) {
                PortNannyCLI.printError(":\(wanted) is in use by a process PortNanny cannot see, most likely one run by another user or with sudo.")
                return nil
            }
            return wanted
        }
        let taken = Set(scan.ports.map(\.port)).union(store.portsReservedByOthers(for: caller)).union(contested)
        guard let free = PortNannyCLI.firstFreePort(prefer: options.prefer, range: options.range, listening: taken) else {
            PortNannyCLI.printError("no free port in \(options.range.lowerBound)-\(options.range.upperBound)")
            return nil
        }
        return free
    }

    static func resolve(_ command: String) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        return ToolLocator.resolve(command)
    }

    /// Runs the child with our stdio, forwards SIGINT and SIGTERM to it, and
    /// answers with its status (128 + signal when it died of one).
    static func runChild(_ executable: String, arguments: [String], environment: [String: String]) -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.standardInput
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError

        var forwarders: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                if child.isRunning { kill(child.processIdentifier, signalNumber) }
            }
            source.activate()
            forwarders.append(source)
        }
        defer { forwarders.forEach { $0.cancel() } }

        do {
            try child.run()
        } catch {
            PortNannyCLI.printError("portnanny: could not start '\(executable)': \(error.localizedDescription)")
            return CLIExit.notExecutable
        }
        child.waitUntilExit()
        if child.terminationReason == .uncaughtSignal {
            return 128 + child.terminationStatus
        }
        return child.terminationStatus
    }
}
