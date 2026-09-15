import Foundation

/// How PortNanny recognises AI coding agents: what their processes look like
/// in the tree, what they leave in the environment of their children, and
/// what names people use for them. Pure data; the logic lives in
/// `AgentAttribution`.
public enum AgentSignatures {

    /// A process in the ancestry chain. Bare binaries match on the exact
    /// executable name, never on arguments, so a project folder named
    /// "claude-code" is not mistaken for the binary. The name is
    /// case-sensitive on purpose: `claude` is the Claude Code CLI, `Claude`
    /// is the desktop app it may be running inside. App bundles match on
    /// their distinctive `.app/` path anywhere in the (lowercased) command.
    public struct TreeSignature {
        let name: String
        let confidence: AgentOwner.Confidence
        /// What it looks for, for the compatibility matrix: an executable
        /// name, or a bundle path fragment starting with "/".
        let label: String
        let matches: (_ commandLower: String, _ executableName: String) -> Bool
    }

    /// Editors spawn shells for humans and for their built-in agents alike, so
    /// an editor ancestor only proves "started from inside the editor".
    public static let appBundles: [(name: String, pathFragment: String)] = [
        ("Cursor", "/cursor.app/"),
        ("VS Code", "/visual studio code.app/"),
        ("Windsurf", "/windsurf.app/"),
        ("Zed", "/zed.app/"),
        ("Trae", "/trae.app/"),
    ]

    public static let treeSignatures: [TreeSignature] = [
        TreeSignature(name: "Claude Code", confidence: .agent, label: "claude") { _, exe in exe == "claude" },
        // An npm install runs as node; without this its sessions read as ended.
        TreeSignature(name: "Claude Code", confidence: .agent, label: "claude") { cmd, exe in
            exe == "node" && cmd.contains("/@anthropic-ai/claude-code/")
        },
        TreeSignature(name: "Codex CLI", confidence: .agent, label: "codex") { _, exe in exe == "codex" },
        TreeSignature(name: "Gemini CLI", confidence: .agent, label: "gemini") { _, exe in exe == "gemini" },
        TreeSignature(name: "Copilot CLI", confidence: .agent, label: "copilot") { _, exe in exe == "copilot" },
        TreeSignature(name: "OpenCode", confidence: .agent, label: "opencode") { _, exe in exe == "opencode" },
        TreeSignature(name: "Aider", confidence: .agent, label: "aider") { _, exe in exe == "aider" },
        TreeSignature(name: "Zed", confidence: .editorTerminal, label: "zed") { _, exe in exe == "zed" },
    ] + appBundles.map { bundle in
        TreeSignature(name: bundle.name, confidence: .editorTerminal, label: bundle.pathFragment) { cmd, _ in cmd.contains(bundle.pathFragment) }
    }

    /// An environment variable an agent leaves on its children. `value` nil
    /// means any value counts. Order is precedence: an explicit declaration
    /// first, then agents, then editor terminals, so Claude Code running
    /// inside a Cursor terminal is Claude Code.
    public struct EnvMarker {
        let name: String
        let key: String
        let value: String?
        let confidence: AgentOwner.Confidence
    }

    public static let envMarkers: [EnvMarker] = [
        EnvMarker(name: "Claude Code", key: "CLAUDECODE", value: nil, confidence: .agent),
        EnvMarker(name: "Cursor", key: "CURSOR_AGENT", value: nil, confidence: .agent),
        EnvMarker(name: "Gemini CLI", key: "GEMINI_CLI", value: nil, confidence: .agent),
        EnvMarker(name: "Codex CLI", key: "CODEX_SANDBOX", value: nil, confidence: .agent),
        EnvMarker(name: "Codex CLI", key: "CODEX_SANDBOX_NETWORK_DISABLED", value: nil, confidence: .agent),
        EnvMarker(name: "Cursor", key: "CURSOR_TRACE_ID", value: nil, confidence: .editorTerminal),
        EnvMarker(name: "VS Code", key: "TERM_PROGRAM", value: "vscode", confidence: .editorTerminal),
    ]

    /// An agent (or a person) can label everything it starts by exporting
    /// this before launching servers; PortNanny reads it like any marker.
    public static let declaredOwnerKey = "PORTNANNY_OWNER"

    /// Tools that export no session id of their own (Codex, Gemini, custom
    /// bots) can still keep their sessions apart: export any string that is
    /// unique per session next to PORTNANNY_OWNER, and servers started
    /// under it belong to that session.
    public static let declaredSessionKey = "PORTNANNY_SESSION"

    /// The names before 2.1; rule files and scripts written for PortKilla
    /// still set them, so they are read as the new ones.
    public static let legacyDeclaredOwnerKey = "PORTKILLA_OWNER"
    public static let legacyDeclaredSessionKey = "PORTKILLA_SESSION"

    /// The declared owner or session from an environment, new name first.
    public static func declaredOwner(in environment: [String: String]) -> String? {
        environment[declaredOwnerKey] ?? environment[legacyDeclaredOwnerKey]
    }

    /// CLAUDE_PID, when it names something that could be a process. Any
    /// process can set this variable to anything, and a value past what a
    /// 32-bit pid holds used to trap the moment it reached the kernel.
    public static func claudeSessionPid(in environment: [String: String]) -> Int? {
        guard let raw = environment[claudeSessionKey], let pid = Int(raw) else { return nil }
        let couldBeAProcess = pid > 0 && pid_t(exactly: pid) != nil
        return couldBeAProcess ? pid : nil
    }

    public static func declaredSession(in environment: [String: String]) -> String? {
        environment[declaredSessionKey] ?? environment[legacyDeclaredSessionKey]
    }

    /// Names the Claude Code process itself; equals the pid the tree walk
    /// finds, which is what makes the two signals agree on a session.
    public static let claudeSessionKey = "CLAUDE_PID"
    /// A UUID per Claude Code session: never recycled the way a pid is, and
    /// stable across a restart in place. Preferred identity when both sides
    /// have it.
    public static let claudeSessionIdKey = "CLAUDE_CODE_SESSION_ID"

    /// Multiplexers and remote shells freeze the environment they were
    /// started with and re-parent everything under themselves, so markers
    /// and ancestry seen through one of these say nothing about which pane
    /// or session started a server.
    public static let attributionBarriers: Set<String> = ["tmux", "screen", "zellij", "sshd"]

    /// VS Code forks point these at their own app bundle, which names the
    /// fork when only `TERM_PROGRAM=vscode` is set.
    public static let vscodeForkHintKeys = ["VSCODE_GIT_ASKPASS_MAIN", "VSCODE_GIT_ASKPASS_NODE"]

    /// The only environment keys ever read from another process.
    public static let markerKeys: Set<String> = Set(
        envMarkers.map(\.key) + [declaredOwnerKey, declaredSessionKey, legacyDeclaredOwnerKey, legacyDeclaredSessionKey, claudeSessionKey, claudeSessionIdKey] + vscodeForkHintKeys
    )

    /// Turns whatever someone typed into PORTNANNY_OWNER into the display
    /// name PortNanny uses, so "claude-code" and "Claude Code" are one agent.
    /// Unknown names are kept as typed (custom bots are legitimate owners).
    public static func canonicalName(_ declared: String) -> String {
        let cleaned = cleanedLabel(declared)
        let key = cleaned.lowercased().filter { $0.isLetter || $0.isNumber }
        return aliases[key] ?? cleaned
    }

    /// Declared values land in notifications and terminal output, so control
    /// characters (newlines, tabs, escape sequences) are dropped and the
    /// length is capped.
    public static func cleanedLabel(_ raw: String) -> String {
        let cleaned = raw
            .map { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? false) ? " " : $0 }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(64)
        return String(cleaned)
    }

    private static let aliases: [String: String] = [
        "claude": "Claude Code", "claudecode": "Claude Code",
        "codex": "Codex CLI", "codexcli": "Codex CLI",
        "gemini": "Gemini CLI", "geminicli": "Gemini CLI",
        "copilot": "Copilot CLI", "copilotcli": "Copilot CLI", "githubcopilot": "Copilot CLI",
        "opencode": "OpenCode",
        "aider": "Aider",
        "cursor": "Cursor",
        "vscode": "VS Code", "code": "VS Code", "visualstudiocode": "VS Code",
        "windsurf": "Windsurf",
        "zed": "Zed",
        "trae": "Trae",
    ]

    /// The editor whose app bundle a path points into, if any.
    public static func bundleName(inPath path: String) -> String? {
        let lower = path.lowercased()
        return appBundles.first { lower.contains($0.pathFragment) }?.name
    }
}
