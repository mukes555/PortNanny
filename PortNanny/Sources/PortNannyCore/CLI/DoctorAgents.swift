import Foundation

/// `portnanny doctor --agents`: the compatibility matrix checked against
/// this machine. Which tools are running or installed, how each one is
/// recognised, how precisely its sessions are told apart, and where every
/// fact came from.
public enum DoctorAgents {

    public struct Report: Encodable {
        let schema = 1
        public let caller: AgentOwner?
        public let agents: [Status]
    }

    public struct Status: Encodable {
        public let name: String
        public let kind: String
        public let recognisedBy: [String]
        public let session: String
        public let provenance: String
        public let tip: String?
        /// Processes of this tool right now.
        public let running: Int
        /// Where the executable was found on PATH, for CLI tools.
        public let installedAt: String?

        public init(name: String, kind: String, recognisedBy: [String], session: String, provenance: String,
                    tip: String?, running: Int, installedAt: String?) {
            self.name = name
            self.kind = kind
            self.recognisedBy = recognisedBy
            self.session = session
            self.provenance = provenance
            self.tip = tip
            self.running = running
            self.installedAt = installedAt
        }
    }

    public static func run(json: Bool) -> Int32 {
        let report = report()
        if json {
            return PortNannyCLI.printJSON(report) ? CLIExit.ok : CLIExit.internalError
        }
        print(text(report))
        return CLIExit.ok
    }

    public static func report(table: ProcessTable = ProcessTable.capture(),
                              path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Report {
        let callerPid = Int(ProcessInfo.processInfo.processIdentifier)
        let caller = AgentAttribution.callerOwner(callerPid: callerPid, in: table)
        let statuses = AgentCatalog.entries.map { entry in
            Status(name: entry.name, kind: entry.kind, recognisedBy: recognisedBy(entry),
                   session: entry.session, provenance: entry.provenance, tip: entry.tip,
                   running: running(entry, in: table), installedAt: installed(entry, path: path))
        }
        return Report(caller: caller, agents: statuses)
    }

    static func recognisedBy(_ entry: AgentCatalogEntry) -> [String] {
        entry.executables.map { "executable \($0)" }
            + entry.bundles.map { "\($0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) in the tree" }
            + entry.envSignals.map { "env \($0)" }
    }

    static func running(_ entry: AgentCatalogEntry, in table: ProcessTable) -> Int {
        table.entries.filter { AgentAttribution.match(command: $0.command, executableName: $0.name)?.name == entry.name }.count
    }

    /// Only PATH counts: the doctor says what the agent's own shell would
    /// find, not where a binary might be hiding.
    static func installed(_ entry: AgentCatalogEntry, path: String) -> String? {
        for executable in entry.executables {
            for directory in path.split(separator: ":") {
                let candidate = "\(directory)/\(executable)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static func text(_ report: Report) -> String {
        var lines: [String] = []
        if let me = report.caller {
            let how = me.source == .declared ? "declared via PORTNANNY_OWNER" : "from \(me.source.rawValue)"
            lines.append("You: \(me.described), \(how)")
        } else {
            lines.append("You: not identified as an AI agent")
        }
        for agent in report.agents {
            lines.append("")
            lines.append("\(agent.name) (\(agent.kind)): \(presence(agent))")
            lines.append(row("recognised by", agent.recognisedBy.joined(separator: "; ")))
            lines.append(row("sessions", agent.session))
            lines.append(row("provenance", agent.provenance))
            if let tip = agent.tip {
                lines.append(row("tip", tip))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func presence(_ agent: Status) -> String {
        if agent.running > 0 {
            let count = agent.kind == "agent" ? " (\(agent.running) process\(agent.running == 1 ? "" : "es"))" : ""
            return "running\(count)"
        }
        if let path = agent.installedAt {
            return "installed at \(path), not running"
        }
        return "not running"
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(value)"
    }
}
