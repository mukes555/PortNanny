import Foundation

/// Which AI coding agent a process belongs to, and the specific session
/// (agent process) it came from. Two windows of the same tool are distinct
/// sessions; `sessionPid` is nil when the session could not be pinned down.
public struct AgentOwner: Codable, Equatable {
    public enum Source: String, Codable {
        case processTree = "process tree"
        case environment
        case declared
    }

    /// How sure we are that an agent, rather than a person, started this.
    /// An editor spawns shells for both, so an editor signal alone is only
    /// "started from inside the editor" and never a reason to refuse a kill.
    public enum Confidence: String, Codable {
        case agent
        case editorTerminal = "editor terminal"
    }

    public let name: String
    public var sessionPid: Int?
    /// A per-session UUID where the agent provides one (Claude Code). Wins
    /// over the pid for identity: pids get recycled, UUIDs don't.
    public var sessionKey: String?
    public var source: Source
    public var confidence: Confidence
    /// The session that started this process has exited: nothing is watching
    /// the server any more, so anyone may stop it.
    public var sessionEnded: Bool

    /// Output carries the short key: `isSameSession` compares full keys, so
    /// an agent that copies what it read cannot pass as another session.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sessionPid, forKey: .sessionPid)
        try container.encodeIfPresent(shortSessionKey, forKey: .sessionKey)
        try container.encode(source, forKey: .source)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(sessionEnded, forKey: .sessionEnded)
    }

    public init(name: String, sessionPid: Int? = nil, sessionKey: String? = nil, source: Source,
         confidence: Confidence = .agent, sessionEnded: Bool = false) {
        self.name = name
        self.sessionPid = sessionPid
        self.sessionKey = sessionKey
        self.source = source
        self.confidence = confidence
        self.sessionEnded = sessionEnded
    }

    /// Stable identity string, e.g. "Claude Code@3f2a9c1d", "Claude Code#845",
    /// or "Claude Code". A long key (a UUID) is shortened; a short one (a
    /// declared PORTNANNY_SESSION) is shown whole so two do not look alike.
    public var sessionId: String {
        if let shortSessionKey { return "\(name)@\(shortSessionKey)" }
        return sessionPid.map { "\(name)#\($0)" } ?? name
    }

    /// The key as shown: a UUID is cut to eight characters, a declared
    /// PORTNANNY_SESSION is shown whole so two do not look alike.
    public var shortSessionKey: String? {
        sessionKey.map { $0.count <= 16 ? $0 : String($0.prefix(8)) }
    }

    /// Same session as `other` when both know their session and it matches;
    /// nil when either side can't say.
    public func isSameSession(as other: AgentOwner) -> Bool? {
        if let mine = sessionKey, let theirs = other.sessionKey { return mine == theirs }
        if let mine = sessionPid, let theirs = other.sessionPid { return mine == theirs }
        return nil
    }

    /// An agent session that is still running: the case the guard protects.
    public var isLiveAgentSession: Bool {
        confidence == .agent && !sessionEnded
    }

    /// Whether this owner can be told apart from another session of the
    /// same tool at all.
    public var hasKnownSession: Bool {
        sessionPid != nil || sessionKey != nil
    }

    /// Short form for tables and chips: "Claude Code", "Claude Code (ended)".
    public var label: String {
        sessionEnded ? "\(name) (ended)" : name
    }

    /// "Claude Code (session 845)" or just the name.
    public var described: String {
        sessionPid.map { "\(name) (session \($0))" } ?? name
    }

    /// One line for detail views and tooltips.
    public var detail: String {
        if confidence == .editorTerminal {
            return "Started from a \(name) terminal (by you or an agent inside it)"
        }
        if sessionEnded {
            return "Started by \(name); that session has ended, so nothing is watching this server"
        }
        let session = sessionPid.map { "session \($0), " } ?? ""
        let how = source == .declared ? "declared" : "from \(source.rawValue)"
        return "Started by \(name) (\(session)\(how))"
    }
}

/// Attributes a process to the AI agent that spawned it, using two passive
/// signals and never a launcher or registry:
///
/// 1. Process ancestry (server -> shell -> agent). Precise about the session,
///    but the link breaks when the server is reparented to launchd (nohup,
///    pm2, or a tool shell that exited after backgrounding it), which is how
///    most agents start dev servers.
/// 2. Environment markers. Agents stamp their child processes (Claude Code
///    sets CLAUDECODE=1, Cursor sets CURSOR_TRACE_ID, ...); the environment
///    is inherited at spawn and survives reparenting, so the server carries
///    its birth certificate with it.
///
/// Unknown stays unknown: we never guess an owner.
public enum AgentAttribution {

    public typealias EnvironmentLookup = (_ pid: Int) -> [String: String]

    /// Deepest ancestor we'll walk before giving up (guards against cycles).
    static let maxDepth = 24

    public static func liveEnvironment(pid: Int) -> [String: String] {
        ProcessFacts.shared.markers(for: Int32(pid), keys: AgentSignatures.markerKeys)
    }

    /// The agent that owns `pid`: by ancestry first (session-precise), then by
    /// the markers in its environment. Nil when neither says anything.
    public static func owner(ofPid pid: Int, in processes: ProcessTable,
                      environmentOf: EnvironmentLookup = liveEnvironment) -> AgentOwner? {
        let environment = environmentOf(pid)
        // An explicit PORTNANNY_OWNER is the documented way to label what you
        // start; it beats whatever the tree says, for targets as for callers.
        // The session still comes from the tree (or Claude's own markers), so
        // two sessions that export the same name stay two sessions.
        if var declared = declaredOwner(in: environment) {
            attachSession(to: &declared, ofPid: pid, environment: environment, in: processes)
            return declared
        }
        let fromTree = ownerFromAncestry(ofPid: pid, in: processes)
        if fromTree?.confidence == .agent {
            return fromTree
        }
        // An editor ancestor only says "started inside the editor"; a marker
        // in the environment (CLAUDECODE=1) knows which agent did it.
        guard var fromEnvironment = ownerFromEnvironment(environment, in: processes) else {
            return fromTree
        }
        // Markers seen through tmux/screen/ssh were inherited from whoever
        // started the multiplexer, not the pane: keep the name, drop the
        // session so it can't pin the server to the wrong agent.
        if ancestryCrossesBarrier(ofPid: pid, in: processes) {
            fromEnvironment.sessionPid = nil
            fromEnvironment.sessionKey = nil
        }
        return fromEnvironment
    }

    /// The agent invoking the CLI: `PORTNANNY_OWNER` if set, else detected
    /// from the caller's own ancestry, else from the caller's own environment.
    public static func callerOwner(callerPid: Int, in processes: ProcessTable,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentOwner? {
        if var declared = declaredOwner(in: environment) {
            attachSession(to: &declared, ofPid: callerPid, environment: environment, in: processes)
            return declared
        }
        if var fromTree = ownerFromAncestry(ofPid: callerPid, in: processes), fromTree.confidence == .agent {
            // The caller's own environment is the same session the tree found.
            if fromTree.name == "Claude Code" {
                fromTree.sessionKey = environment[AgentSignatures.claudeSessionIdKey]
            }
            if fromTree.sessionKey == nil {
                // The same fallback `exec` stamps on what it starts, so a
                // detached server and its own session still match.
                fromTree.sessionKey = declaredSession(in: environment) ?? fromTree.sessionPid.map(String.init)
            }
            return fromTree
        }
        return ownerFromEnvironment(environment, in: processes) ?? ownerFromAncestry(ofPid: callerPid, in: processes)
    }

    /// Walks up from the parent of `pid`. The process itself is never the
    /// agent: an editor's own helper that happens to listen must resolve to
    /// the editor, not to a "session" of one.
    public static func ownerFromAncestry(ofPid pid: Int, in processes: ProcessTable) -> AgentOwner? {
        var current = processes.ppid(for: pid)
        var seen = Set<Int>()

        for _ in 0..<maxDepth {
            guard let pid = current, pid > 1, !seen.contains(pid) else { break }
            seen.insert(pid)

            let executable = processes.name(for: pid)
            if let executable, AgentSignatures.attributionBarriers.contains(executable) {
                return nil // see attributionBarriers
            }
            if let command = processes.command(for: pid),
               let signature = match(command: command, executableName: executable) {
                return AgentOwner(name: signature.name, sessionPid: pid, source: .processTree, confidence: signature.confidence)
            }
            current = processes.ppid(for: pid)
        }
        return nil
    }

    public static func ancestryCrossesBarrier(ofPid pid: Int, in processes: ProcessTable) -> Bool {
        var current = processes.ppid(for: pid)
        var seen = Set<Int>()
        for _ in 0..<maxDepth {
            guard let pid = current, pid > 1, !seen.contains(pid) else { return false }
            seen.insert(pid)
            if let executable = processes.name(for: pid), AgentSignatures.attributionBarriers.contains(executable) {
                return true
            }
            current = processes.ppid(for: pid)
        }
        return false
    }

    /// Owner from environment markers. A Claude Code session pid is only
    /// trusted while that process is alive and still an agent; otherwise the
    /// name is kept and the session reported as ended.
    public static func ownerFromEnvironment(_ environment: [String: String], in processes: ProcessTable) -> AgentOwner? {
        if let declared = declaredOwner(in: environment) {
            return declared
        }

        let marker = AgentSignatures.envMarkers.first { marker in
            guard let actual = environment[marker.key] else { return false }
            return marker.value.map { $0 == actual.lowercased() } ?? true
        }
        guard let marker else { return nil }

        var owner = AgentOwner(name: marker.name, source: .environment, confidence: marker.confidence)
        if marker.key == "TERM_PROGRAM", let fork = vscodeFork(in: environment) {
            owner = AgentOwner(name: fork, source: .environment, confidence: .editorTerminal)
        }
        if marker.name == "Claude Code" {
            owner.sessionKey = environment[AgentSignatures.claudeSessionIdKey]
            if let session = AgentSignatures.claudeSessionPid(in: environment) {
                if isAgentProcess(session, named: marker.name, in: processes) {
                    owner.sessionPid = session
                } else {
                    owner.sessionEnded = true
                    owner.sessionKey = nil
                }
            }
        }
        // A marker without any session (Cursor, Gemini, Codex, older Claude
        // Code) would otherwise claim a live session forever. If no process
        // of that agent is running at all, the session has ended.
        if owner.confidence == .agent, owner.sessionPid == nil, !owner.sessionEnded, !anyProcessRunning(named: marker.name, in: processes) {
            owner.sessionEnded = true
        }
        // A tool without a session id of its own may still have been given
        // one by whoever started it.
        if owner.sessionKey == nil, !owner.sessionEnded {
            owner.sessionKey = declaredSession(in: environment)
        }
        return owner
    }

    private static func anyProcessRunning(named agent: String, in processes: ProcessTable) -> Bool {
        processes.entries.contains { entry in
            match(command: entry.command, executableName: entry.name)?.name == agent
        }
    }

    private static func declaredOwner(in environment: [String: String]) -> AgentOwner? {
        guard let raw = AgentSignatures.declaredOwner(in: environment) else { return nil }
        let name = AgentSignatures.canonicalName(raw)
        guard !name.isEmpty else { return nil }
        return AgentOwner(name: name, sessionKey: declaredSession(in: environment), source: .declared)
    }

    /// A declared owner without a PORTNANNY_SESSION borrows the session the
    /// scanner can see: the nearest agent in the ancestry (not through a
    /// multiplexer), or Claude Code's own session markers.
    static func attachSession(to owner: inout AgentOwner, ofPid pid: Int, environment: [String: String], in processes: ProcessTable) {
        if owner.sessionKey == nil {
            owner.sessionKey = environment[AgentSignatures.claudeSessionIdKey]
        }
        guard owner.sessionPid == nil else { return }
        if let fromTree = ownerFromAncestry(ofPid: pid, in: processes), fromTree.confidence == .agent, !ancestryCrossesBarrier(ofPid: pid, in: processes) {
            owner.sessionPid = fromTree.sessionPid
            return
        }
        if let session = AgentSignatures.claudeSessionPid(in: environment), isAgentProcess(session, named: "Claude Code", in: processes) {
            owner.sessionPid = session
        }
    }

    /// PORTNANNY_SESSION, cleaned; nil when unset or blank.
    static func declaredSession(in environment: [String: String]) -> String? {
        guard let raw = AgentSignatures.declaredSession(in: environment) else { return nil }
        let cleaned = AgentSignatures.cleanedLabel(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func vscodeFork(in environment: [String: String]) -> String? {
        for key in AgentSignatures.vscodeForkHintKeys {
            if let path = environment[key], let name = AgentSignatures.bundleName(inPath: path) {
                return name
            }
        }
        return nil
    }

    /// True when `pid` is running and is still the same agent (guards against
    /// the pid having been reused, by an unrelated process or another agent).
    private static func isAgentProcess(_ pid: Int, named agent: String, in processes: ProcessTable) -> Bool {
        guard let command = processes.command(for: pid) else { return false }
        return match(command: command, executableName: processes.name(for: pid))?.name == agent
    }

    /// Match a process against the known tree signatures. `executableName` is
    /// the kernel-reported binary name when available; it is authoritative
    /// because an executable path can contain spaces ("Application Support"),
    /// which makes the first-token fallback unreliable.
    public static func match(command: String, executableName: String? = nil) -> AgentSignatures.TreeSignature? {
        let commandLower = command.lowercased()
        let firstToken = command.split(separator: " ").first.map(String.init) ?? command
        let basename = executableName ?? (firstToken as NSString).lastPathComponent
        return AgentSignatures.treeSignatures.first { $0.matches(commandLower, basename) }
    }
}
