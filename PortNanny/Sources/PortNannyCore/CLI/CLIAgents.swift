import Foundation

/// `portnanny agents`: who is on this machine and what they hold. The same
/// grouping the app's Agents view draws, for a person reading a terminal and
/// for an agent asking "who else is working here?" before it takes a port.
public enum CLIAgents {

    public struct Report: Encodable {
        let schema = 1
        let sessions: [Session]
        /// The caller's own identity, so an agent can find itself in the list.
        let caller: AgentOwner?

        struct Session: Encodable {
            let id: String
            let name: String
            /// live, ended, editor, or none (nobody claims these).
            let kind: String
            let session: String?
            let ports: [Int]
            /// Ports leased with nothing listening on them yet.
            let claims: [Int]
            let memoryKB: Int
            let isYou: Bool
        }
    }

    public static func run(json: Bool) -> Int32 {
        let scan = PortNannyCLI.scan(refreshDocker: false)
        let groups = AgentSessions.groups(from: scan.ports, leases: ReservationStore.appStore().all())
        let report = Report(sessions: groups.map { session(from: $0, caller: scan.caller) }, caller: scan.caller)

        if json {
            return PortNannyCLI.printJSON(report) ? CLIExit.ok : CLIExit.internalError
        }
        guard !groups.isEmpty else {
            print("Nothing is listening, and nobody holds a port.")
            return CLIExit.ok
        }
        for line in lines(for: groups, caller: scan.caller) {
            print(line)
        }
        return CLIExit.ok
    }

    /// One line per session: who, what it is running, what it has claimed.
    /// Padded to the longest name so the columns line up without a table.
    static func lines(for groups: [AgentSessions.Group], caller: AgentOwner?) -> [String] {
        let names = groups.map { title(of: $0, caller: caller) }
        let width = min(names.map(\.count).max() ?? 0, 34)
        return zip(groups, names).map { group, name in
            let padded = name.count >= width ? name : name + String(repeating: " ", count: width - name.count)
            var parts = [padded, state(of: group)]
            if !group.ports.isEmpty {
                parts.append(portList(group.ports.map(\.port)))
                parts.append(MemoryFormat.string(kilobytes: group.memoryKB))
            }
            if !group.claims.isEmpty {
                parts.append("claims " + portList(group.claims.map(\.port)))
            }
            return parts.filter { !$0.isEmpty }.joined(separator: "  ")
        }
    }

    /// A line is for reading: the catch-all group can hold thirty ports, and
    /// listing them all turns the answer into a wall.
    private static let portsPerLine = 10

    private static func portList(_ ports: [Int]) -> String {
        let shown = ports.prefix(portsPerLine).map { ":\($0)" }.joined(separator: " ")
        let rest = ports.count - portsPerLine
        return rest > 0 ? "\(shown) +\(rest) more" : shown
    }

    private static func title(of group: AgentSessions.Group, caller: AgentOwner?) -> String {
        var title = group.title
        if let key = group.owner?.shortSessionKey {
            title += " (id \(key))"
        } else if let pid = group.owner?.sessionPid {
            title += " (session \(pid))"
        }
        return isCaller(group, caller: caller) ? title + " ← you" : title
    }

    private static func state(of group: AgentSessions.Group) -> String {
        switch group.kind {
        case .live: return "running"
        case .ended: return "ended  "
        case .editor: return "terminal"
        case .unattributed: return "        "
        }
    }

    /// The caller's own session, by the same rule the guard uses.
    private static func isCaller(_ group: AgentSessions.Group, caller: AgentOwner?) -> Bool {
        guard let caller, let owner = group.owner, owner.name == caller.name else { return false }
        return owner.isSameSession(as: caller) ?? false
    }

    private static func session(from group: AgentSessions.Group, caller: AgentOwner?) -> Report.Session {
        Report.Session(
            id: group.id,
            name: group.title,
            kind: kindName(group.kind),
            session: group.owner?.sessionId,
            ports: group.ports.map(\.port),
            claims: group.claims.map(\.port),
            memoryKB: group.memoryKB,
            isYou: isCaller(group, caller: caller)
        )
    }

    private static func kindName(_ kind: AgentSessions.Group.Kind) -> String {
        switch kind {
        case .live: return "live"
        case .ended: return "ended"
        case .editor: return "editor"
        case .unattributed: return "none"
        }
    }
}
