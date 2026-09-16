import Foundation

/// The JSON contracts, written down. `portnanny schema <command>` prints one;
/// a test checks that what the encoders emit stays within it. Fields are only
/// ever added within a schema version.
public enum OutputSchemas {
    public static let commands = ["list", "kill", "whois", "whoami", "wait", "history", "version", "doctor", "doctor-agents", "agents", "free-port", "reserve", "release", "reservations", "drift"]

    public static let expectedPort: [String: String] = [
        "port": "the port the project's files name", "source": "where: \".env PORT\", \"package.json dev\", \"vite.config.ts\"",
    ]

    public static let reservation: [String: String] = [
        "port": "the leased port", "owner": "holder's display name: an agent, or the user name", "sessionKey": "holder's session id, when known",
        "sessionPid": "holder's session pid, when known", "reason": "what the lease is for, when given",
        "createdAt": "ISO 8601", "expiresAt": "ISO 8601; the lease is gone after this",
    ]

    public static let agentOwner: [String: String] = [
        "name": "agent display name, e.g. \"Claude Code\"",
        "sessionPid": "pid of the agent process for this session, when known",
        "sessionKey": "per-session id: the agent's own (Claude Code) or PORTNANNY_SESSION; preferred identity",
        "source": "\"process tree\" | \"environment\" | \"declared\"",
        "confidence": "\"agent\" | \"editor terminal\"",
        "sessionEnded": "true when the session that started the process has exited",
    ]

    public static let port: [String: String] = [
        "port": "port number", "pid": "process id", "processName": "executable name", "command": "command line, secrets redacted",
        "user": "owning user", "memoryUsage": "human-readable RSS", "memorySizeKB": "RSS in KB", "type": "classification, e.g. \"Node.js\"",
        "projectName": "project folder name, when known", "projectPath": "working directory, when known",
        "containerName": "Docker container, when the port is published by one", "children": "child processes [{pid, name, command}]",
        "bindAddress": "\"*\" / \"0.0.0.0\" / \"::\" mean all interfaces", "proto": "\"tcp\" | \"udp\"", "cpuPercent": "CPU between scans",
        "age": "human-readable process age, when known", "agentOwner": "AgentOwner or absent", "connections": "established TCP connections on this port",
        "managedBy": "ManagedRuntime or absent: a supervisor that would undo a plain kill",
        "reservation": "Reservation or absent: a live lease on this port",
        "expectedPort": "ExpectedPort or absent: the project configured a different port for this server",
    ]

    public static let managedRuntime: [String: String] = [
        "kind": "pm2 | launchd | docker | reloader", "name": "pm2 app, launchd label, container, or the reloader (nodemon, next dev, ...)",
        "supervisorPid": "the process kill signals instead of the listener, for reloaders and masters", "supervisorName": "its executable name",
        "stopArguments": "argv of the command that stops it for real, when one exists", "stopCommand": "the same command, for display",
    ]

    public static let evidence: [String: String] = [
        "declaredOwner": "PORTNANNY_OWNER as found in the environment, before canonicalising",
        "declaredSession": "PORTNANNY_SESSION as found",
        "ancestry": "[{pid, name, role}] from the parent upwards, ending with the deciding ancestor; role is \"agent: X\", \"editor: X\", \"barrier\", or absent",
        "markers": "{key: value} for the allowlisted marker keys present in the environment",
        "decidedBy": "declared | process tree | environment | docker (the container owns the port) | none",
        "owner": "AgentOwner or absent",
    ]

    public static let whoisTarget: [String: String] = [
        "port": "port number", "proto": "\"tcp\" | \"udp\"", "bindAddress": "bind address, when known", "pid": "process id",
        "processName": "executable name", "command": "command line, secrets redacted", "user": "owning user",
        "type": "classification, e.g. \"Node.js\"", "age": "human-readable process age, when known",
        "projectName": "project folder name, when known", "projectPath": "working directory, when known",
        "containerName": "Docker container, when published by one", "connections": "established TCP connections",
        "peers": "[{host, port, kind}] remote ends of the established connections; kind is local | lan | remote",
        "children": "child processes [{pid, name, command}]", "agentOwner": "AgentOwner or absent",
        "managedBy": "ManagedRuntime or absent",
        "expectedPort": "ExpectedPort or absent", "expectedHeldBy": "who holds the expected port now, when someone does",
        "evidence": "AttributionEvidence (fields below)",
        "verdict": "what kill would do for this caller, same vocabulary as kill.guardVerdict",
        "reason": "the refusal reason, when refused",
        "sameProject": "the target runs in the caller's working directory, above it, or below it",
    ]

    public static let agentStatus: [String: String] = [
        "name": "tool display name", "kind": "\"agent\" | \"editor terminal\"",
        "recognisedBy": "[\"executable claude\", \"env CLAUDECODE\", \"cursor.app in the tree\", ...]",
        "session": "how precisely sessions of this tool are told apart", "provenance": "where the facts come from and what was verified",
        "tip": "what to export to be identified better, when applicable",
        "running": "processes of this tool right now", "installedAt": "where the executable was found on PATH, when it was",
    ]

    public static let all: [String: [String: String]] = [
        "list": ["<array>": "PortInfo objects (see fields below)"].merging(port) { a, _ in a },
        "kill": [
            "schema": "1", "action": "not-found | already-free | held-by-unseen | no-orphans | would-kill | would-refuse | refused | managed | killed | stopped | partial | still-running | failed",
            "port": "requested port, absent for --pid and --orphaned", "force": "whether --force was given", "caller": "AgentOwner of the caller, or absent",
            "targets": "[{pid, processName, port, proto, agentOwner, connections, projectPath, managedBy}]", "reasons": "refusal or failure lines",
            "stoppedVia": "supervisors signalled or commands run in place of a plain kill",
            "overriddenRefusals": "refusals --force overrode", "guardVerdict": "refused | allowed | overridden | not-evaluated: … | allowed: caller is not an agent",
            "exitCode": "0 done, 1 nothing listening, 3 refused, 4 failed or only partly killed, 5 still running, 6 managed (a supervisor would undo it; the stop command is in reasons)",
        ],
        "whois": [
            "schema": "1", "port": "requested port, absent for --pid", "pid": "requested pid, absent for a port",
            "caller": "AgentOwner of the caller, or absent", "targets": "[Dossier] one per process (fields below)", "exitCode": "0 found, 1 nothing listening",
        ],
        "whoami": ["schema": "1", "detected": "whether an agent was identified", "owner": "AgentOwner or absent"],
        "wait": ["schema": "1", "port": "port", "free": "true when nothing listens", "waitedSeconds": "time waited", "exitCode": "0 free, 5 timeout"],
        "agents": [
            "schema": "1",
            "sessions": "[{id, name, kind, session, ports, claims, memoryKB, isYou}] live sessions first, then ended, editor terminals, and the ports nobody claims",
            "caller": "AgentOwner or absent: who PortNanny thinks is asking",
        ],
        "history": ["<array>": "[{id, port, processName, timestamp, action, owner, killedBy}] newest first; kills only unless --all, which adds action Refused rows where killedBy names the agent that was refused"],
        "version": ["schema": "1", "version": "semver", "bundleIdentifier": "com.mukes555.PortNanny", "installSource": "Homebrew | Applications (DMG) | development build", "architecture": "arm64 | x86_64", "defaultsDomain": "the preference domain this build reads; a debug build honours PORTNANNY_DEFAULTS_SUITE, a release build does not"],
        "doctor": ["<object>": "label -> value, one entry per diagnostic line"],
        "doctor-agents": ["schema": "1", "caller": "AgentOwner of the caller, or absent", "agents": "[AgentStatus] the compatibility matrix against this machine (fields below)"],
        "free-port": ["schema": "1", "port": "first free port that no one else has leased, absent when none", "preferred": "requested port", "range": "\"A-B\"", "exitCode": "0 found, 1 none"],
        "reserve": [
            "schema": "1", "action": "reserved | renewed | in-use | refused | failed", "port": "requested port",
            "reservation": "the lease (yours, or the other holder's when refused)", "occupant": "PortInfo when the port is in use",
            "reasons": "why not, when not", "exitCode": "0 leased, 1 in use, 3 someone else holds it",
        ],
        "release": ["schema": "1", "action": "released | refused | not-reserved", "port": "port", "reservation": "the lease released or refused", "exitCode": "0 released, 1 not reserved, 3 someone else holds it (use --force)"],
        "reservations": ["<array>": "Reservation objects, live ones only, by port"],
        "drift": [
            "schema": "1", "drifted": "[{port, pid, processName, projectName, projectPath, expected: ExpectedPort, heldBy: {pid, processName, agentOwner} or absent}]",
            "exitCode": "always 0",
        ],
    ]

    /// Sub-objects a command's output embeds, printed under it.
    static let nested: [String: [(String, [String: String])]] = [
        "list": [("AgentOwner", agentOwner), ("ManagedRuntime", managedRuntime), ("Reservation", reservation), ("ExpectedPort", expectedPort)],
        "drift": [("ExpectedPort", expectedPort), ("AgentOwner", agentOwner)],
        "kill": [("AgentOwner", agentOwner), ("ManagedRuntime", managedRuntime)],
        "whoami": [("AgentOwner", agentOwner)],
        "whois": [("Dossier", whoisTarget), ("AttributionEvidence", evidence), ("AgentOwner", agentOwner), ("ManagedRuntime", managedRuntime)],
        "reserve": [("Reservation", reservation)],
        "release": [("Reservation", reservation)],
        "reservations": [("Reservation", reservation)],
        "doctor-agents": [("AgentStatus", agentStatus), ("AgentOwner", agentOwner)],
        "agents": [("AgentOwner", agentOwner)],
    ]

    public static func render(_ command: String?) -> String? {
        guard let command, let fields = all[command] else { return nil }
        var lines = ["\(command == "doctor-agents" ? "doctor --agents" : command) --json"]
        for key in fields.keys.sorted() {
            lines.append("  \(key.padding(toLength: 20, withPad: " ", startingAt: 0)) \(fields[key]!)")
        }
        for (name, block) in nested[command] ?? [] {
            lines.append("  \(name):")
            for key in block.keys.sorted() {
                lines.append("    \(key.padding(toLength: 18, withPad: " ", startingAt: 0)) \(block[key]!)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
