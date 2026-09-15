import Foundation

// MARK: - Watchlist and port guards
// Watched ports report when they free up or get taken; guarded ports go one
// step further and auto-kill an unprotected occupant, except a running AI
// agent's server. Everything here runs on the main thread after a scan.
extension PortManager {

    public func isWatched(_ port: Int) -> Bool {
        watchedPorts.contains(port)
    }

    public func isGuarded(_ port: Int) -> Bool {
        guardedPorts.contains(port)
    }

    /// Confirmation happens in the UI: this just flips the state.
    public func toggleGuard(_ port: Int) {
        if guardedPorts.contains(port) {
            guardedPorts.remove(port)
            showToast("Guard removed from :\(port)")
        } else {
            guardedPorts.insert(port)
            watchedPorts.insert(port) // guarding implies watching
            // The server already on the port is the one being protected. Left
            // unrecorded, the next scan read it as an intruder and killed it.
            watchedOccupancy[port] = Self.occupancy(of: port, in: activePorts)
            Notifier.requestPermission()
            showToast("Guarding :\(port)")
        }
    }

    public func toggleWatch(_ port: Int) {
        if watchedPorts.contains(port) {
            watchedPorts.remove(port)
            guardedPorts.remove(port)
            watchedOccupancy.removeValue(forKey: port)
            showToast("Stopped watching :\(port)")
        } else {
            watchedPorts.insert(port)
            // Seeded so adding a busy port doesn't announce the server already there.
            watchedOccupancy[port] = Self.occupancy(of: port, in: activePorts)
            Notifier.requestPermission()
            showToast("Watching :\(port)")
        }
    }

    public struct WatchEvent: Equatable {
        enum Kind: Equatable { case freed, occupied(by: String) }
        let port: Int
        let kind: Kind
    }

    /// Diffs watched-port occupancy between two scans.
    public static func watchEvents(
        watched: Set<Int>,
        previous: [Int: String],
        current: [Int: String]
    ) -> [WatchEvent] {
        var events: [WatchEvent] = []
        for port in watched.sorted() {
            let was = previous[port]
            let now = current[port]
            if was != nil && now == nil {
                events.append(WatchEvent(port: port, kind: .freed))
            } else if let now, was != now {
                // Newly occupied OR the occupant changed identity between scans
                // (a restart/swap must still fire the guard, not go unnoticed).
                events.append(WatchEvent(port: port, kind: .occupied(by: occupantName(now))))
            }
        }
        return events
    }

    public func firePendingFreeNotifications(with ports: [PortInfo]) {
        guard !pendingFreeNotifications.isEmpty else { return }

        let stillBusy = Set(ports.map { $0.port })
        let freed = pendingFreeNotifications.subtracting(stillBusy)
        for port in freed.sorted() {
            // Watched ports already got a "free" notification from the watch
            // diff this cycle: don't send a second one for the same event.
            if !watchedPorts.contains(port) {
                notify(.portFreed, title: "Port \(port) is free", body: "The process finally exited: :\(port) is available now.")
            }
        }
        pendingFreeNotifications.subtract(freed)
    }

    /// Sends a notification only when the person wants that kind. Guard
    /// kills still happen regardless; only the alert is suppressed.
    private func notify(_ kind: NotificationKind, title: String, body: String) {
        guard notifies(kind) else { return }
        Notifier.send(title: title, body: body, sound: notificationSound)
    }

    /// A process that keeps coming back (pm2, nodemon, a launchd KeepAlive
    /// job) would otherwise be killed and announced on every scan, forever.
    /// After a few kills in quick succession the guard stands down instead.
    private static let guardStrikeLimit = 3
    private static let guardStrikeWindow: TimeInterval = 60

    /// Records one guard kill and says whether that was one too many. Only
    /// the guard itself calls this; views ask `guardIsStruckOut`.
    public func registerGuardStrike(on port: Int) -> Bool {
        let now = Date()
        var recent = (guardStrikes[port] ?? []).filter { now.timeIntervalSince($0) < Self.guardStrikeWindow }
        recent.append(now)
        guardStrikes[port] = recent
        return recent.count > Self.guardStrikeLimit
    }

    /// Whether the guard on `port` has stood down, without touching the count.
    public func guardIsStruckOut(on port: Int) -> Bool {
        let now = Date()
        let recent = (guardStrikes[port] ?? []).filter { now.timeIntervalSince($0) < Self.guardStrikeWindow }
        return recent.count > Self.guardStrikeLimit
    }

    /// A guard only ever fires against unprotected processes the user owns.
    public func guardKillTarget(for port: Int, in ports: [PortInfo]) -> PortInfo? {
        guard guardedPorts.contains(port),
              let occupant = ports.first(where: { $0.port == port }),
              !isProtectedProcessName(occupant.processName),
              !isSystemPort(occupant) else { return nil }
        return occupant
    }

    public static func ownersOfGuardedOccupants(_ guarded: Set<Int>, in ports: [PortInfo], processes: ProcessTable) -> [Int: AgentOwner] {
        var owners: [Int: AgentOwner] = [:]
        for port in ports where guarded.contains(port.port) {
            // Keyed by pid: a port number can carry a TCP listener and a UDP
            // binder from different processes.
            if let owner = port.agentOwner ?? AgentAttribution.owner(ofPid: port.pid, in: processes) {
                owners[port.pid] = owner
            }
        }
        return owners
    }

    /// Occupancy is remembered as "pid name": a supervisor that restarts its
    /// server keeps the name but not the pid, and the guard must see that as
    /// a new occupant rather than nothing at all.
    static func occupantIdentity(pid: Int, name: String) -> String { "\(pid) \(name)" }

    /// What a scan records for a watched port. Seeding and scanning must agree
    /// on the format exactly: a seed of the bare name never matched a scan's
    /// "pid name", so every newly watched busy port looked newly taken.
    static func occupancy(of port: Int, in ports: [PortInfo]) -> String? {
        ports.first { $0.port == port }.map { occupantIdentity(pid: $0.pid, name: $0.processName) }
    }

    /// The name inside an identity, for the text a person reads.
    static func occupantName(_ identity: String) -> String {
        identity.split(separator: " ", maxSplits: 1).last.map(String.init) ?? identity
    }

    public func processWatchedPorts(with ports: [PortInfo], guardOwners: [Int: AgentOwner] = [:]) {
        guard !watchedPorts.isEmpty else {
            watchedOccupancy = [:]
            return
        }

        var current: [Int: String] = [:]
        for port in watchedPorts {
            current[port] = Self.occupancy(of: port, in: ports)
        }

        // The very first scan just establishes the baseline
        if hasCompletedFirstScan {
            for event in Self.watchEvents(watched: watchedPorts, previous: watchedOccupancy, current: current) {
                switch event.kind {
                case .freed:
                    notify(.portFreed, title: ":\(event.port) is free", body: "Nothing is listening on :\(event.port) anymore.")
                case .occupied(let name):
                    if let intruder = guardKillTarget(for: event.port, in: ports) {
                        let owner = intruder.agentOwner ?? guardOwners[intruder.pid]
                        Log.guardLog.info("guard on :\(event.port) saw \(intruder.processName, privacy: .private) owner=\(owner?.sessionId ?? "none", privacy: .public)")
                        if case .warn(let reason) = KillDecision.forHuman(target: owner) {
                            // The only unattended kill in the app never takes
                            // another agent's live server; the person decides.
                            notify(
                                .guardKill,
                                title: "Guard on :\(event.port)",
                                body: "'\(name)' took the port but was not auto-killed. \(reason)"
                            )
                        } else if registerGuardStrike(on: event.port) {
                            guardedPorts.remove(event.port)
                            guardStrikes[event.port] = nil
                            notify(
                                .guardKill,
                                title: "Guard on :\(event.port) stood down",
                                body: "'\(intruder.processName)' keeps coming back. Stop it at the source, then re-enable the guard."
                            )
                        } else {
                            // The banner said "Auto-killing" before anything
                            // was signalled, and a kill that failed was never
                            // mentioned at all: the person was told a port had
                            // been cleared while the intruder kept it.
                            notify(
                                .guardKill,
                                title: "Guard on :\(event.port)",
                                body: "Stopping '\(intruder.processName)': it took a guarded port."
                            )
                            killPort(intruder, initiator: .portGuard) { [weak self] problem in
                                self?.notify(.guardKill, title: "Guard on :\(event.port) could not stop it", body: problem)
                            }
                        }
                    } else {
                        notify(.portTaken, title: ":\(event.port) is in use", body: "'\(name)' started listening on :\(event.port).")
                    }
                }
            }
        }
        watchedOccupancy = current
    }

}
