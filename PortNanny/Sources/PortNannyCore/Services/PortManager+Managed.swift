import Foundation

// MARK: - Managed runtimes
// A supervised listener is stopped the way its supervisor expects, so the
// port stays free: the reloader goes down with its child, and pm2, launchd,
// and Docker get their own stop commands.
extension PortManager {

    /// Stops the reloader (nodemon, next dev, a gunicorn master) and, with
    /// it, the listener it would otherwise respawn.
    public func stopSupervisor(of port: PortInfo) {
        guard let managed = port.managedBy, let supervisor = managed.supervisorPid, let name = managed.supervisorName else {
            killPort(port)
            return
        }
        // The History entry waits for the kill: it used to be written first,
        // so a supervisor that refused to die was recorded as stopped anyway.
        killProcess(pid: supervisor, name: name, killTree: true) { [weak self] in
            self?.history.addEntry(port: port.port, processName: port.processName, action: .killed,
                                   owner: port.agentOwner?.name, killedBy: "\(KillInitiator.user.rawValue) (stopped \(managed.label))")
        }
    }

    /// Runs the runtime's own stop command (pm2 stop, brew services stop,
    /// launchctl bootout, docker stop) off the main thread and waits for
    /// the port to free.
    public func stopManaged(_ port: PortInfo) {
        guard let managed = port.managedBy, var command = managed.stopArguments else {
            showToast("No stop command for \(port.managedBy?.label ?? "this process")")
            return
        }
        guard let tool = ToolLocator.resolve(command[0]) else {
            lastErrorMessage = "\(command[0]) was not found. Run `\(managed.stopCommand ?? "")` in a terminal."
            showToast("\(command[0]) not found")
            return
        }
        command[0] = tool

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                _ = try CommandRunner.run(command[0], Array(command.dropFirst()), timeout: 20)
                let stillBusy = ManagedRuntime.waitForPortsFree([port.port], timeout: 12)
                Log.kill.info("stop \(managed.label, privacy: .public) via \(managed.stopCommand ?? "", privacy: .public) freed=\(stillBusy.isEmpty)")
                DispatchQueue.main.async {
                    if stillBusy.isEmpty {
                        self.activePorts.removeAll { $0.port == port.port }
                        self.lastErrorMessage = nil
                        self.showToast("Stopped \(managed.label)")
                        self.history.addEntry(port: port.port, processName: port.processName, action: .killed,
                                              owner: port.agentOwner?.name, killedBy: "\(KillInitiator.user.rawValue) (\(managed.stopCommand ?? ""))")
                    } else {
                        self.showToast(":\(port.port) still in use after `\(managed.stopCommand ?? "")`")
                    }
                    self.scheduleRefresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastErrorMessage = self.formatError(error, context: "Stop failed")
                    self.showToast("Stop failed")
                }
            }
        }
    }
}
