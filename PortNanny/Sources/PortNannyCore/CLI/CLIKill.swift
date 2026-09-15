import Foundation

/// `portnanny kill`: identity-checked kills of every listener on a port (or
/// one pid), gated by the friendly-fire guard, with machine-readable output.
public enum CLIKill {

    public struct Report: Encodable {
        let schema = 1
        var action: String
        var port: Int?
        var force: Bool
        var caller: AgentOwner?
        var targets: [Target]
        var reasons: [String]
        /// Refusals that --force overrode: the audit trail of whose server
        /// was killed against the guard's advice.
        var overriddenRefusals: [String] = []
        /// "refused", "allowed", "overridden", or "not-evaluated: …" so an
        /// agent can tell "checked and cleared" from "could not check".
        var guardVerdict = ""
        /// Supervisors stopped or commands run in place of a plain kill.
        var stoppedVia: [String] = []
        var exitCode: Int32

        struct Target: Encodable {
            let pid: Int
            let processName: String
            let port: Int
            let proto: String
            let agentOwner: AgentOwner?
            let connections: Int
            let projectPath: String?
            let managedBy: ManagedRuntime?
        }
    }

    /// What a kill produced: the report for JSON consumers, the text for
    /// people, and where the text belongs.
    public struct Outcome {
        let report: Report
        let text: String
        let toStderr: Bool
    }

    public static func run(_ options: CLICommand.KillOptions) -> Int32 {
        let outcome = perform(options)
        if options.json {
            return PortNannyCLI.printJSON(outcome.report) ? outcome.report.exitCode : CLIExit.internalError
        }
        if outcome.toStderr {
            PortNannyCLI.printError(outcome.text)
        } else {
            print(outcome.text)
        }
        return outcome.report.exitCode
    }

    /// Docker publishes every container's port through one backend process,
    /// so the container's name is the only thing that makes `docker stop`
    /// possible; without it a kill can only refuse. Naming costs a
    /// `docker ps`, so it is worth paying for exactly when a target is a
    /// container we cannot name yet.
    static func needsContainerNames(_ targets: [PortInfo]) -> Bool {
        targets.contains { $0.type == .docker && $0.containerName == nil }
    }

    /// The whole kill decision and action, without touching stdout: the CLI
    /// prints the outcome, the MCP server wraps it in a tool result.
    public static func perform(_ options: CLICommand.KillOptions, cwd: String = FileManager.default.currentDirectoryPath) -> Outcome {
        var scan = PortNannyCLI.scan(refreshDocker: false)
        var targets = select(from: scan.ports, options: options)
        if needsContainerNames(targets) {
            scan = PortNannyCLI.scan(refreshDocker: true)
            targets = select(from: scan.ports, options: options)
        }
        var report = Report(
            action: "", port: options.port, force: options.force, caller: scan.caller,
            targets: targets.map { Report.Target(pid: $0.pid, processName: $0.processName, port: $0.port, proto: $0.proto, agentOwner: $0.agentOwner, connections: $0.connections, projectPath: $0.projectPath, managedBy: $0.managedBy) },
            reasons: [], exitCode: CLIExit.ok
        )

        guard !targets.isEmpty else {
            if options.orphaned {
                return finish(&report, action: "no-orphans", exit: CLIExit.ok, text: "No orphaned servers: nothing is left over from an ended agent session.")
            }
            // The scan cannot see another user's sockets. Saying "nothing is
            // listening" there sent `free 5432 && start-postgres` straight into
            // EADDRINUSE, so the kernel gets the last word before a port is free.
            if options.pid == nil, let port = options.port, PortProbe.isHeld(port) {
                let text = ":\(port) is in use by a process PortNanny cannot see, most likely one run by another user or with sudo. `sudo lsof -nP -iTCP:\(port) -sTCP:LISTEN` names it."
                return finish(&report, action: "held-by-unseen", exit: CLIExit.killFailed, text: text, toStderr: true)
            }
            let what = options.pid.map { "PID \($0) is not listening on any port." } ?? "Nothing is listening on :\(options.port ?? 0)."
            // `free` treats an already-free port as done.
            let exit = options.freeIsSuccess && options.pid == nil ? CLIExit.ok : CLIExit.notFound
            return finish(&report, action: exit == CLIExit.ok ? "already-free" : "not-found", exit: exit, text: what)
        }
        var notes: [String] = []
        if scan.caller == nil, let owned = targets.first(where: { $0.agentOwner?.isLiveAgentSession == true }) {
            // The guard can't protect what it can't compare against.
            notes.append("note: :\(owned.port) belongs to \(owned.agentOwner?.described ?? "an agent") and you are not identified as an agent, so the friendly-fire guard did not apply. Run `portnanny whoami` or export PORTNANNY_OWNER=<name>.")
        }

        // A lease refuses an agent and warns a person; the warning was being
        // dropped, so a person killed a leased port without hearing about it.
        let leaseStore = ReservationStore.appStore()
        for target in targets {
            if case .warn(let why) = KillDecision.forReservation(caller: scan.caller, reservation: leaseStore.reservation(for: target.port), asAgent: false) {
                notes.append("note: \(why)")
            }
        }

        let plans = targets.map { plan(for: $0, force: options.force, table: scan.table, ports: scan.ports) }
        let judged = plans.flatMap { [$0.target] + $0.alsoStops }
        let refusals = Self.refusals(caller: scan.caller, plans: plans, leases: leaseStore, cwd: cwd)
        report.guardVerdict = verdict(caller: scan.caller, targets: judged, refused: !refusals.isEmpty, forced: options.force)
        report.reasons = refusals
        if !refusals.isEmpty && !options.force {
            let text = refusals.joined(separator: "\n")
                + "\nRefusing to kill another agent's server. Ask the user, or start yours on a free port. Pass --force only if the user says so; run `portnanny whoami` to check how you are identified."
            let action = options.dryRun ? "would-refuse" : "refused"
            if !options.dryRun {
                recordRefusals(targets, caller: scan.caller)
            }
            return finish(&report, action: action, exit: CLIExit.refused, text: text, toStderr: !options.dryRun)
        }

        if options.force && !refusals.isEmpty {
            report.overriddenRefusals = refusals
            report.reasons = []
        }

        if options.dryRun {
            let blocked = plans.compactMap(\.blocked)
            if !blocked.isEmpty {
                report.reasons += blocked
                return finish(&report, action: "managed", exit: CLIExit.managed, text: blocked.joined(separator: "\n"))
            }
            let text = plans.map { plan -> String in
                let target = plan.target
                let clients = target.connections > 0 ? " It has \(target.connections) connected client\(target.connections == 1 ? "" : "s")." : ""
                let also = plan.alsoStops.isEmpty ? "" : " That also stops " + plan.alsoStops.map { ":\($0.port) (\($0.processName), PID \($0.pid))" }.joined(separator: ", ") + "."
                if let substitution = plan.substitution {
                    return "Would \(substitution).\(clients)\(also)"
                }
                return "Would \(options.force ? "force-" : "")kill \(target.processName) (PID \(target.pid)) on :\(target.port).\(clients)"
            }.joined(separator: "\n")
            return finish(&report, action: "would-kill", exit: CLIExit.ok, text: (notes + [text]).joined(separator: "\n"))
        }

        var outcome = execute(plans, options: options, report: &report)
        if !notes.isEmpty {
            outcome = Outcome(report: outcome.report, text: (notes + [outcome.text]).joined(separator: "\n"), toStderr: outcome.toStderr)
        }
        return outcome
    }

    /// The guard: the whole request is refused if any target, or anything a
    /// supervisor would take down with it, is another agent's or leased.
    static func refusals(caller: AgentOwner?, plans: [Plan], leases: ReservationStore, cwd: String) -> [String] {
        let asked = Set(plans.map(\.target.pid))
        let judged = plans.flatMap { [$0.target] + $0.alsoStops }
        return judged.flatMap { target -> [String] in
            let subject = ":\(target.port) (PID \(target.pid))" + (asked.contains(target.pid) ? "" : ", which its supervisor would take down too,")
            var reasons: [String] = []
            if case .refuse(let reason) = KillDecision.forAgent(caller: caller, target: target.agentOwner) {
                // A hint, not a permission: the caller's own project is where
                // its own unclaimed server would be, and also the user's.
                let location = isSameProject(target.projectPath, cwd: cwd) ? " (it runs in your working directory)" : ""
                reasons.append("\(subject) is \(reason)\(location)")
            }
            if case .refuse(let why) = KillDecision.forReservation(caller: caller, reservation: leases.reservation(for: target.port), asAgent: true) {
                reasons.append("\(subject) is \(why)")
            }
            return reasons
        }
    }

    /// A refusal is an event the person may want to act on: it goes into
    /// History and, at once, to the running app.
    private static func recordRefusals(_ targets: [PortInfo], caller: AgentOwner?) {
        let store = HistoryManager.appStore()
        let actor = caller.map { "\($0.described) via CLI" } ?? "CLI"
        for target in targets where KillDecision.forAgent(caller: caller, target: target.agentOwner).isRefusal {
            store.addRefusal(port: target.port, processName: target.processName, owner: target.agentOwner?.name, refused: actor)
            RefusalSignal.post(RefusalSignal.Payload(port: target.port, processName: target.processName, owner: target.agentOwner?.name, caller: actor))
        }
    }

    /// "refused", "overridden", "allowed", or why the guard could not judge:
    /// an agent must tell "checked and cleared" from "could not check".
    static func verdict(caller: AgentOwner?, targets: [PortInfo], refused: Bool, forced: Bool) -> String {
        if refused { return forced ? "overridden" : "refused" }
        if caller == nil, targets.contains(where: { $0.agentOwner?.isLiveAgentSession == true }) { return "not-evaluated: caller unknown" }
        if targets.allSatisfy({ $0.agentOwner == nil }) {
            if caller == nil { return "not-evaluated: target unknown" }
            if caller?.confidence != .agent { return "allowed: caller is not an agent" }
            return Policy.refusesUnclaimedServers ? "allowed" : "allowed: unclaimed guard off"
        }
        return "allowed"
    }

    /// Every distinct process on the port, the one pid asked for, or with
    /// --orphaned every process whose agent session has ended.
    public static func select(from ports: [PortInfo], options: CLICommand.KillOptions) -> [PortInfo] {
        var seenPids = Set<Int>()
        return ports.filter { port in
            let matches: Bool
            if options.orphaned {
                matches = port.agentOwner?.sessionEnded == true
            } else {
                matches = options.pid.map { $0 == port.pid } ?? (port.port == options.port)
            }
            guard matches, !seenPids.contains(port.pid) else { return false }
            seenPids.insert(port.pid)
            return true
        }
    }

    /// True when `path` is the working directory, or inside it, or above it.
    public static func isSameProject(_ path: String?, cwd: String) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let target = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let mine = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        guard target != "/", mine != "/" else { return false }
        return target == mine || target.hasPrefix(mine + "/") || mine.hasPrefix(target + "/")
    }

    /// Polls because the CLI has no run loop to host dispatch sources.
    static func waitForExit(_ pids: [Int], timeout: TimeInterval, killer: ProcessKiller) -> Set<Int> {
        var alive = Set(pids)
        let deadline = Date().addingTimeInterval(timeout)
        while !alive.isEmpty && Date() < deadline {
            alive = alive.filter { killer.isProcessRunning($0) }
            if !alive.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        return alive
    }

    static func finish(_ report: inout Report, action: String, exit: Int32, text: String, toStderr: Bool = false) -> Outcome {
        report.action = action
        report.exitCode = exit
        return Outcome(report: report, text: text, toStderr: toStderr)
    }
}
