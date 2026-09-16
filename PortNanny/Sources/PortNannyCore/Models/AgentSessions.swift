import Foundation

/// What is listening, grouped by the session that started it: the question
/// this app exists to answer. Plain functions, so both the popover's Agents
/// view and the Workbench's Agents section render the same grouping and it
/// can be tested without a window.
public enum AgentSessions {

    public struct Group: Identifiable {
        /// Live sessions first, then the ones that ended (safe to clean up),
        /// then editor terminals, then whatever nobody claims.
        public enum Kind: Int {
            case live = 0
            case ended = 1
            case editor = 2
            case unattributed = 3

            /// The SF Symbol both the popover and the Workbench draw for it.
            public var icon: String {
                switch self {
                case .live: return "sparkles"
                case .ended: return "moon.zzz"
                case .editor: return "terminal"
                case .unattributed: return "person"
                }
            }

            /// "Stop all" is for a session. The catch-all group is a
            /// leftovers bin, and stopping all of it would take the database
            /// and Docker with it.
            public var hasBulkVerb: Bool { self != .unattributed }
        }

        public let id: String
        public let title: String
        public let subtitle: String
        public let kind: Kind
        public let owner: AgentOwner?
        public let ports: [PortInfo]
        /// Ports this session has leased with nothing listening on them yet:
        /// "I am about to start something here". Only the Agents view shows
        /// them, and only it can, because a claim has no process to list.
        public let claims: [Reservation]

        public var memoryKB: Int { ports.reduce(0) { $0 + $1.memorySizeKB } }
        public var isEmpty: Bool { ports.isEmpty && claims.isEmpty }
    }

    /// One group per session. `leases` are matched to the session that holds
    /// them; a lease whose holder has nothing listening still gets a group,
    /// because "Codex has :3100 and has not started yet" is worth seeing.
    public static func groups(from ports: [PortInfo], leases: [Reservation] = [], user: String = Reservation.currentUser) -> [Group] {
        var members: [String: [PortInfo]] = [:]
        var owners: [String: AgentOwner] = [:]
        for port in ports {
            let key = port.agentOwner.map(sessionKey) ?? unattributedKey
            members[key, default: []].append(port)
            if let owner = port.agentOwner, owners[key] == nil { owners[key] = owner }
        }

        // A lease on a port something is already listening on is shown by
        // that row's own chip; only the unused ones are news here.
        let listening = Set(ports.map(\.port))
        var claims: [String: [Reservation]] = [:]
        for lease in leases where !listening.contains(lease.port) {
            let key = claimKey(for: lease, owners: owners, user: user)
            claims[key, default: []].append(lease)
            if owners[key] == nil, key != unattributedKey { owners[key] = lease.holder }
        }

        let keys = Set(members.keys).union(claims.keys)
        return keys.map { key -> Group in
            let owner = owners[key]
            return Group(
                id: key,
                title: title(for: owner),
                subtitle: subtitle(for: owner, user: user),
                kind: kind(of: owner),
                owner: owner,
                ports: (members[key] ?? []).sorted { $0.port < $1.port },
                claims: (claims[key] ?? []).sorted { $0.port < $1.port }
            )
        }
        .sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.title != b.title ? a.title < b.title : a.subtitle < b.subtitle
        }
    }

    /// Ended sessions' servers: what "Clean up" stops.
    public static func orphaned(_ ports: [PortInfo]) -> [PortInfo] {
        ports.filter { $0.agentOwner?.sessionEnded == true }
    }

    /// The badge counts, without building the groups.
    public static func sessionCount(of ports: [PortInfo]) -> Int {
        Set(ports.map { $0.agentOwner.map(sessionKey) ?? unattributedKey }).count
    }

    /// Live sessions only, for the header: an ended session is not running.
    public static func liveSessionCount(of ports: [PortInfo]) -> Int {
        Set(ports.compactMap(\.agentOwner).filter(\.isLiveAgentSession).map(sessionKey)).count
    }

    public static let unattributedKey = "(unattributed)"

    /// Every ended session of one tool shares a group: which of yesterday's
    /// sessions left a server behind is not a useful distinction.
    private static func sessionKey(_ owner: AgentOwner) -> String {
        if owner.sessionEnded { return "\(owner.name) (ended)" }
        if owner.confidence == .editorTerminal { return "\(owner.name) terminal" }
        return owner.sessionId
    }

    /// The group a lease belongs to: the session that took it, by the same
    /// rule the guard uses, or the catch-all when it was the person's own.
    private static func claimKey(for lease: Reservation, owners: [String: AgentOwner], user: String) -> String {
        if let match = owners.first(where: { lease.isHeld(by: $0.value, user: user) })?.key { return match }
        guard lease.holder.hasKnownSession || lease.owner != user else { return unattributedKey }
        return sessionKey(lease.holder)
    }

    private static func kind(of owner: AgentOwner?) -> Group.Kind {
        guard let owner else { return .unattributed }
        if owner.confidence == .editorTerminal { return .editor }
        return owner.sessionEnded ? .ended : .live
    }

    private static func title(for owner: AgentOwner?) -> String {
        guard let owner else { return "No agent" }
        if owner.confidence == .editorTerminal { return "\(owner.name) terminal" }
        return owner.name
    }

    private static func subtitle(for owner: AgentOwner?, user: String) -> String {
        guard let owner else { return "started by you, or by something that leaves no trace" }
        if owner.confidence == .editorTerminal { return "started inside the editor, by a person or its agent" }
        if owner.sessionEnded { return "session ended; anyone may stop these" }
        var parts: [String] = []
        if let pid = owner.sessionPid { parts.append("session \(pid)") }
        if let key = owner.shortSessionKey { parts.append("id \(key)") }
        parts.append(owner.source == .declared ? "declared" : "from \(owner.source.rawValue)")
        return parts.joined(separator: " · ")
    }
}
