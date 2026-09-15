import Foundation

/// How `kill` treats a listener with a supervisor: stop the supervisor
/// (reloaders and masters), run the runtime's own stop verb (pm2, launchd,
/// Docker), or, with --force, kill the listener anyway. A plain kill of a
/// supervised process frees the port for a second and reports success.
extension CLIKill {

    struct Plan {
        let target: PortInfo
        /// The process to signal, and the name to verify before signalling.
        let signalPid: Int
        let signalName: String
        let killTree: Bool
        /// A command that replaces the signal: resolved argv, and its display form.
        let command: [String]?
        let commandText: String?
        /// "stop nodemon (PID 700) instead of node (PID 812) on :3000, because ..."
        let substitution: String?
        /// Other listeners a supervisor would take down with the target; the
        /// guard judges them too, and they are named in the plan.
        let alsoStops: [PortInfo]
        /// Why nothing can be done here.
        let blocked: String?

        static func plain(_ target: PortInfo, blocked: String? = nil) -> Plan {
            Plan(target: target, signalPid: target.pid, signalName: target.processName, killTree: false,
                 command: nil, commandText: nil, substitution: nil, alsoStops: [], blocked: blocked)
        }
    }

    static func plan(for target: PortInfo, force: Bool, table: ProcessTable, ports: [PortInfo] = [],
                     resolve: (String) -> String? = { ToolLocator.resolve($0) }) -> Plan {
        guard let managed = target.managedBy else { return .plain(target) }
        let subject = "\(target.processName) (PID \(target.pid)) on :\(target.port)"

        // A reloader is stopped with everything under it, so everything under
        // it is part of the plan.
        if managed.kind == .reloader, !force {
            guard let supervisor = managed.supervisorPid, let name = managed.supervisorName ?? table.name(for: supervisor) else { return .plain(target) }
            let descendants = table.descendants(of: supervisor)
            var seen: Set<Int> = [target.pid]
            let also = ports.filter { descendants.contains($0.pid) && seen.insert($0.pid).inserted }
            return Plan(target: target, signalPid: supervisor, signalName: name, killTree: true, command: nil, commandText: nil,
                        substitution: "stop \(managed.label) instead of \(subject), because \(managed.consequence)", alsoStops: also, blocked: nil)
        }
        // --force kills the listener itself; only Docker's backend is never
        // the thing to kill, so --force there means `docker kill`.
        if force, managed.kind != .docker { return .plain(target) }

        guard var argv = managed.stopArguments(force: force), let text = managed.stopCommand(force: force) else {
            if managed.kind == .docker {
                guard !DockerService.shared.lastLookupFailed else {
                    return .plain(target, blocked: "\(subject) is published by Docker, but `docker ps` did not answer, so PortNanny cannot name the container to stop. Check that Docker is running, then try again.")
                }
                return .plain(target, blocked: "\(subject) is published by Docker Desktop for a container `docker ps` can name; PortNanny does not kill Docker itself.")
            }
            return .plain(target, blocked: "\(subject) is managed by \(managed.label) and \(managed.consequence). Pass --force to kill it anyway.")
        }
        guard let tool = resolve(argv[0]) else {
            let hint = managed.kind == .docker ? "" : ", or pass --force to kill it anyway"
            return .plain(target, blocked: "\(subject) is managed by \(managed.label) and \(managed.consequence). Run `\(text)` (\(argv[0]) is not on PATH here)\(hint).")
        }
        argv[0] = tool
        return Plan(target: target, signalPid: target.pid, signalName: target.processName, killTree: false, command: argv, commandText: text,
                    substitution: "run `\(text)` instead of killing \(subject), because \(managed.consequence)", alsoStops: [], blocked: nil)
    }

    static func execute(_ plans: [Plan], options: CLICommand.KillOptions, report: inout Report) -> Outcome {
        let blocked = plans.compactMap(\.blocked)
        if !blocked.isEmpty {
            report.reasons += blocked
            return finish(&report, action: "managed", exit: CLIExit.managed, text: blocked.joined(separator: "\n"), toStderr: true)
        }

        let killer = ProcessKiller()
        var failures: [String] = []
        var signalled: [Plan] = []
        var commanded: [Plan] = []
        /// Plans whose process had already exited: the port is free, but
        /// History must not record a kill that never happened.
        var alreadyGone: Set<Int> = []
        for plan in plans {
            if let command = plan.command {
                do {
                    _ = try CommandRunner.run(command[0], Array(command.dropFirst()), timeout: 20)
                    commanded.append(plan)
                    report.stoppedVia.append(plan.commandText ?? command.joined(separator: " "))
                } catch {
                    failures.append("`\(plan.commandText ?? "")` failed: \(error.localizedDescription)")
                }
                continue
            }
            do {
                let outcome = try killer.killProcess(pid: plan.signalPid, force: options.force, killTree: plan.killTree, expectedName: plan.signalName)
                signalled.append(plan)
                if !outcome.signalled { alreadyGone.insert(plan.signalPid) }
                // A tree kill that leaves children behind is why the port can
                // stay busy; those errors used to be dropped silently.
                if !outcome.childrenNotKilled.isEmpty {
                    let pids = outcome.childrenNotKilled.map(String.init).joined(separator: ", ")
                    failures.append("\(plan.signalName) (PID \(plan.signalPid)): could not stop its child process\(outcome.childrenNotKilled.count == 1 ? "" : "es") \(pids)")
                }
                if plan.signalPid != plan.target.pid {
                    report.stoppedVia.append("\(plan.signalName) (PID \(plan.signalPid))")
                }
            } catch {
                failures.append("\(plan.signalName) (PID \(plan.signalPid)): \(error.localizedDescription)")
            }
        }

        // A supervisor's children may take a moment longer than the supervisor.
        let awaited = signalled.flatMap { [$0.signalPid, $0.target.pid] + $0.alsoStops.map(\.pid) }
        let stillRunning = waitForExit(awaited, timeout: PortManager.exitTimeout(force: options.force) + 1, killer: killer)
        // `docker stop` alone waits up to ten seconds for a graceful exit.
        let stillListening = ManagedRuntime.waitForPortsFree(commanded.map(\.target.port), timeout: 12)

        let killed = signalled.filter { !stillRunning.contains($0.signalPid) && !stillRunning.contains($0.target.pid) }
        let stopped = commanded.filter { !stillListening.contains($0.target.port) }
        record(killed.filter { !alreadyGone.contains($0.signalPid) } + stopped, report: report)

        // `free` promises a free port, not a dead process. A supervisor can
        // put a new server on the port within milliseconds of the old one
        // dying, and `free 3000 && npm start` then hit EADDRINUSE anyway.
        let takenAgain = options.freeIsSuccess ? (killed + stopped).map(\.target.port).filter(PortProbe.isHeld) : []

        var lines = killed.map { plan -> String in
            let target = plan.target
            let leftover = options.orphaned ? " (\(target.agentOwner?.label ?? "orphaned"))" : ""
            if alreadyGone.contains(plan.signalPid) {
                return "\(plan.signalName) (PID \(plan.signalPid)) had already exited; :\(target.port) is free."
            }
            if plan.signalPid != target.pid {
                let also = plan.alsoStops.isEmpty ? "" : " and " + plan.alsoStops.map { ":\($0.port)" }.joined(separator: ", ")
                return "Stopped \(plan.signalName) (PID \(plan.signalPid)), and with it \(target.processName) (PID \(target.pid)) on :\(target.port)\(also)."
            }
            return "Killed \(target.processName) (PID \(target.pid)) on :\(target.port)\(leftover)."
        }
        lines += stopped.map { "Stopped \($0.target.managedBy?.label ?? "") with `\($0.commandText ?? "")`; :\($0.target.port) is free." }
        lines += signalled.filter { stillRunning.contains($0.signalPid) || stillRunning.contains($0.target.pid) }
            .map { "\($0.target.processName) (PID \($0.target.pid)) is still running. Try --force." }
        lines += commanded.filter { stillListening.contains($0.target.port) }
            .map { ":\($0.target.port) is still in use after `\($0.commandText ?? "")`." }
        lines += takenAgain.map { ":\($0) is in use again already; something restarted it." }
        lines += failures.map { "Failed to kill \($0)" }
        report.reasons += failures

        let text = lines.joined(separator: "\n")
        if signalled.isEmpty && commanded.isEmpty {
            return finish(&report, action: "failed", exit: CLIExit.killFailed, text: text, toStderr: true)
        }
        // Some died and some did not. This used to exit 0 as "killed", so a
        // script that killed three ports and checked the status carried on
        // with one of them still listening.
        if !failures.isEmpty {
            return finish(&report, action: "partial", exit: CLIExit.killFailed, text: text, toStderr: true)
        }
        if !stillRunning.isEmpty || !stillListening.isEmpty || !takenAgain.isEmpty {
            return finish(&report, action: "still-running", exit: CLIExit.stillRunning, text: text)
        }
        let action = signalled.isEmpty ? "stopped" : "killed"
        return finish(&report, action: action, exit: CLIExit.ok, text: text)
    }

    private static func record(_ done: [Plan], report: Report) {
        let store = HistoryManager.appStore()
        let actor = report.caller.map { "\($0.described) via CLI" } ?? "CLI"
        for plan in done {
            let how = plan.commandText.map { " (\($0))" } ?? ""
            store.addEntry(port: plan.target.port, processName: plan.target.processName, action: .killed,
                           owner: plan.target.agentOwner?.name, killedBy: actor + how)
            for taken in plan.alsoStops {
                store.addEntry(port: taken.port, processName: taken.processName, action: .killed,
                               owner: taken.agentOwner?.name, killedBy: actor + " (with \(plan.signalName), PID \(plan.signalPid))")
            }
        }
    }
}
