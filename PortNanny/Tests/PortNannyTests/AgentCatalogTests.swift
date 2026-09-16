import XCTest
@testable import PortNannyCore

/// Phase B1: the compatibility matrix, declared sessions, attribution
/// evidence, and the new commands' parsing and contracts.
final class AgentCatalogTests: XCTestCase {

    private func table(_ rows: [(Int, Int, String)]) -> ProcessTable {
        let lines = rows.map { "\($0.0) \($0.1) 1024 0.0 05:00 \($0.2)" }.joined(separator: "\n")
        return ProcessTable(psOutput: lines)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Catalog

    func testEveryRecognisedToolHasANoteAndEveryNoteATool() {
        let names = Set(AgentCatalog.entries.map(\.name))
        XCTAssertEqual(names, Set(AgentCatalog.notes.keys))
        for entry in AgentCatalog.entries {
            XCTAssertFalse(entry.session.isEmpty, "\(entry.name) needs a session note")
            XCTAssertFalse(entry.provenance.isEmpty, "\(entry.name) needs provenance")
            XCTAssertFalse(entry.executables.isEmpty && entry.bundles.isEmpty && entry.envSignals.isEmpty, "\(entry.name) has no signal")
        }
        XCTAssertEqual(AgentCatalog.entries.first?.name, "Claude Code")
        XCTAssertEqual(AgentCatalog.entry(named: "Cursor")?.kind, "agent", "Cursor has a built-in agent with its own marker")
        XCTAssertEqual(AgentCatalog.entry(named: "VS Code")?.kind, "editor terminal")
    }

    func testAgentsDocDescribesEveryCatalogEntry() throws {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent("docs/AGENTS.md"), encoding: .utf8)
        for entry in AgentCatalog.entries {
            XCTAssertTrue(doc.contains(entry.name), "docs/AGENTS.md should mention \(entry.name)")
            for signal in entry.envSignals {
                let key = signal.split(separator: "=").first.map(String.init) ?? signal
                XCTAssertTrue(doc.contains(key), "docs/AGENTS.md should mention \(key)")
            }
        }
        for needle in ["PORTNANNY_OWNER", "PORTNANNY_SESSION", "whois", "--orphaned", "doctor --agents"] {
            XCTAssertTrue(doc.contains(needle), "docs/AGENTS.md should mention \(needle)")
        }
    }

    func testDoctorAgentsSeesRunningToolsAndInstalledExecutables() throws {
        let t = table([(100, 1, "/opt/homebrew/bin/codex"), (101, 1, "/opt/homebrew/bin/codex"), (200, 1, "/bin/zsh")])
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("portnanny-doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let fake = bin.appendingPathComponent("gemini")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let report = DoctorAgents.report(table: t, path: bin.path)
        let codex = try XCTUnwrap(report.agents.first { $0.name == "Codex CLI" })
        XCTAssertEqual(codex.running, 2)
        XCTAssertNil(codex.installedAt)
        let gemini = try XCTUnwrap(report.agents.first { $0.name == "Gemini CLI" })
        XCTAssertEqual(gemini.running, 0)
        XCTAssertEqual(gemini.installedAt, fake.path)
        XCTAssertTrue(gemini.recognisedBy.contains("executable gemini"))
        XCTAssertTrue(gemini.recognisedBy.contains("env GEMINI_CLI"))
    }

    // MARK: - Declared sessions

    func testDeclaredOwnerCarriesADeclaredSession() {
        let owner = AgentAttribution.ownerFromEnvironment(["PORTNANNY_OWNER": "my-bot", "PORTNANNY_SESSION": " run-7 \n"], in: .empty)
        XCTAssertEqual(owner?.name, "my-bot")
        XCTAssertEqual(owner?.sessionKey, "run-7")
        XCTAssertEqual(owner?.sessionId, "my-bot@run-7", "short keys are shown whole")
        XCTAssertNil(AgentAttribution.ownerFromEnvironment(["PORTNANNY_OWNER": "my-bot", "PORTNANNY_SESSION": "   "], in: .empty)?.sessionKey)
    }

    func testMarkerOwnerTakesADeclaredSessionWhileTheToolRuns() {
        let running = table([(100, 1, "/opt/homebrew/bin/codex")])
        let live = AgentAttribution.ownerFromEnvironment(["CODEX_SANDBOX": "seatbelt", "PORTNANNY_SESSION": "s2"], in: running)
        XCTAssertEqual(live?.name, "Codex CLI")
        XCTAssertEqual(live?.sessionKey, "s2")
        XCTAssertTrue(live?.isLiveAgentSession == true)

        let ended = AgentAttribution.ownerFromEnvironment(["CODEX_SANDBOX": "seatbelt", "PORTNANNY_SESSION": "s2"], in: .empty)
        XCTAssertTrue(ended?.sessionEnded == true)
        XCTAssertNil(ended?.sessionKey, "an ended session does not keep a key that could pin it to a live one")
    }

    func testDeclaredSessionsTellTwoBotsApart() {
        let one = AgentOwner(name: "my-bot", sessionKey: "s1", source: .declared)
        let two = AgentOwner(name: "my-bot", sessionKey: "s2", source: .declared)
        let anonymous = AgentOwner(name: "my-bot", source: .declared)
        XCTAssertTrue(KillDecision.forAgent(caller: one, target: two).isRefusal)
        XCTAssertEqual(KillDecision.forAgent(caller: one, target: one), .allow)
        XCTAssertTrue(KillDecision.forAgent(caller: anonymous, target: two).isRefusal, "a bot that cannot show its session may not claim one that has a key")
        XCTAssertEqual(KillDecision.forAgent(caller: one, target: anonymous), .allow, "no key on the target means nothing to compare")
    }

    func testTreeCallerPicksUpItsDeclaredSession() {
        let t = table([(100, 1, "claude"), (200, 100, "/bin/zsh"), (300, 200, "portnanny whoami")])
        let caller = AgentAttribution.callerOwner(callerPid: 300, in: t, environment: ["PORTNANNY_SESSION": "s9"])
        XCTAssertEqual(caller?.name, "Claude Code")
        XCTAssertEqual(caller?.sessionPid, 100)
        XCTAssertEqual(caller?.sessionKey, "s9")
        let withOwnId = AgentAttribution.callerOwner(callerPid: 300, in: t, environment: ["PORTNANNY_SESSION": "s9", "CLAUDE_CODE_SESSION_ID": "uuid"])
        XCTAssertEqual(withOwnId?.sessionKey, "uuid", "the tool's own id wins")
    }

    func testDeclaredValuesDropControlCharacters() {
        XCTAssertEqual(AgentSignatures.cleanedLabel("s1\u{1b}[31m\n"), "s1 [31m")
        XCTAssertEqual(AgentSignatures.cleanedLabel(String(repeating: "a", count: 100)).count, 64)
    }

    // MARK: - Evidence

    func testEvidenceShowsTheAncestryThatDecided() {
        let t = table([(100, 1, "claude bg-pty-host"), (200, 100, "/bin/zsh"), (300, 200, "node server.js")])
        let evidence = AgentAttribution.explain(pid: 300, in: t, environmentOf: { _ in [:] })
        XCTAssertEqual(evidence.decidedBy, "process tree")
        XCTAssertEqual(evidence.owner?.name, "Claude Code")
        XCTAssertEqual(evidence.ancestry.map(\.pid), [200, 100])
        XCTAssertEqual(evidence.ancestry.last?.role, "agent: Claude Code")
        XCTAssertNil(evidence.ancestry.first?.role)
        XCTAssertEqual(evidence.ancestryLine, "zsh (200) -> claude (100) [agent: Claude Code]")
        XCTAssertTrue(evidence.markers.isEmpty)
    }

    func testEvidenceStopsAtABarrierAndReportsNothingDecided() {
        let t = table([(100, 1, "claude"), (200, 100, "tmux"), (300, 200, "node server.js")])
        let evidence = AgentAttribution.explain(pid: 300, in: t, environmentOf: { _ in [:] })
        XCTAssertEqual(evidence.decidedBy, "none")
        XCTAssertNil(evidence.owner)
        XCTAssertEqual(evidence.ancestry.map(\.role), ["barrier"])
    }

    func testEvidencePrefersTheDeclarationAndListsMarkers() {
        let t = table([(100, 1, "claude"), (200, 100, "/bin/zsh"), (300, 200, "node server.js")])
        let env = ["CLAUDECODE": "1", "PORTNANNY_OWNER": "my-bot", "PORTNANNY_SESSION": "s1", "HOME": "/Users/me"]
        let evidence = AgentAttribution.explain(pid: 300, in: t, environmentOf: { _ in env })
        XCTAssertEqual(evidence.decidedBy, "declared")
        XCTAssertEqual(evidence.owner?.name, "my-bot")
        XCTAssertEqual(evidence.owner?.sessionKey, "s1")
        XCTAssertEqual(evidence.declaredOwner, "my-bot")
        XCTAssertEqual(evidence.declaredSession, "s1")
        XCTAssertEqual(Set(evidence.markers.keys), ["CLAUDECODE", "PORTNANNY_OWNER", "PORTNANNY_SESSION"], "only allowlisted keys are ever shown")
        XCTAssertEqual(evidence.markersLine, "CLAUDECODE=1, PORTNANNY_OWNER=my-bot, PORTNANNY_SESSION=s1")
    }

    // MARK: - Same project

    func testSameProjectIsTheDirectoryOrAboveOrBelow() {
        XCTAssertTrue(CLIKill.isSameProject("/a/b", cwd: "/a/b"))
        XCTAssertTrue(CLIKill.isSameProject("/a/b/", cwd: "/a/b"))
        XCTAssertTrue(CLIKill.isSameProject("/a/b/c", cwd: "/a/b"))
        XCTAssertTrue(CLIKill.isSameProject("/a", cwd: "/a/b"))
        XCTAssertFalse(CLIKill.isSameProject("/a/bc", cwd: "/a/b"))
        XCTAssertFalse(CLIKill.isSameProject(nil, cwd: "/a"))
        XCTAssertFalse(CLIKill.isSameProject("/", cwd: "/a"))
    }

    func testOrphanedSelectionKeepsOnlyEndedSessions() {
        let ended = AgentOwner(name: "Claude Code", source: .environment, sessionEnded: true)
        let live = AgentOwner(name: "Cursor", sessionPid: 5, source: .processTree)
        let ports = [
            PortInfo(port: 3000, pid: 1, processName: "a", command: "a", user: "u", memoryUsage: "1", memorySizeKB: 1, type: .nodejs, agentOwner: ended),
            PortInfo(port: 3001, pid: 2, processName: "b", command: "b", user: "u", memoryUsage: "1", memorySizeKB: 1, type: .nodejs, agentOwner: live),
            PortInfo(port: 3002, pid: 3, processName: "c", command: "c", user: "u", memoryUsage: "1", memorySizeKB: 1, type: .nodejs),
        ]
        var options = CLICommand.KillOptions()
        options.orphaned = true
        XCTAssertEqual(CLIKill.select(from: ports, options: options).map(\.pid), [1])
    }

    // MARK: - Parsing

    func testWhoisAndOrphanedAndDoctorAgentsParse() {
        var byPort = CLICommand.WhoisOptions()
        byPort.port = 3000
        XCTAssertEqual(CLIArguments.parse(["whois", "3000"]), .success(.whois(byPort)))
        var byPid = CLICommand.WhoisOptions()
        byPid.pid = 12
        byPid.json = true
        XCTAssertEqual(CLIArguments.parse(["whois", "--pid", "12", "--json"]), .success(.whois(byPid)))
        XCTAssertEqual(CLIArguments.parse(["whois"]), .failure(.missingTarget))
        XCTAssertEqual(CLIArguments.parse(["whois", "3000", "--pid", "1"]), .failure(.conflictingTargets))
        XCTAssertEqual(CLIArguments.parse(["whois", "--force"]), .failure(.unknownOption("--force", command: "whois")))

        var orphaned = CLICommand.KillOptions()
        orphaned.orphaned = true
        orphaned.dryRun = true
        XCTAssertEqual(CLIArguments.parse(["kill", "--orphaned", "--dry-run"]), .success(.kill(orphaned)))
        XCTAssertEqual(CLIArguments.parse(["kill", "3000", "--orphaned"]), .failure(.conflictingTargets))
        XCTAssertEqual(CLIArguments.parse(["doctor", "--agents", "--json"]), .success(.doctor(json: true, agents: true)))
        XCTAssertEqual(CLIArguments.parse(["doctor"]), .success(.doctor(json: false, agents: false)))
        XCTAssertEqual(CLIArguments.parse(["doctor", "--x"]), .failure(.unknownOption("--x", command: "doctor")))
        XCTAssertTrue(CLIArguments.usage(for: "whois").contains("--pid"))
        XCTAssertTrue(CLIArguments.usage(for: "kill").contains("--orphaned"))
    }

    // MARK: - Contracts

    private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        return Set(object.keys)
    }

    func testWhoisAndAgentsOutputStayWithinTheWrittenSchema() throws {
        let t = table([(100, 1, "claude"), (200, 100, "/bin/zsh"), (300, 200, "node server.js")])
        let owner = AgentOwner(name: "Claude Code", sessionPid: 100, source: .processTree)
        let port = PortInfo(port: 3000, pid: 300, processName: "node", command: "node server.js", user: "me", memoryUsage: "1MB",
                            memorySizeKB: 1024, type: .nodejs, projectName: "p", projectPath: "/p", containerName: nil,
                            children: [PortInfo.ProcessInfo(pid: 2, name: "n", command: "c")], bindAddress: "*", age: "1m",
                            agentOwner: owner, connections: 1)
        let dossier = CLIWhois.dossier(for: port, caller: AgentOwner(name: "Cursor", sessionPid: 9, source: .processTree), table: t, cwd: "/p")
        XCTAssertTrue(try keys(dossier).isSubset(of: Set(OutputSchemas.whoisTarget.keys)))
        XCTAssertTrue(try keys(dossier.evidence).isSubset(of: Set(OutputSchemas.evidence.keys)))
        XCTAssertEqual(dossier.verdict, "refused")
        XCTAssertTrue(dossier.sameProject)
        XCTAssertTrue(CLIWhois.text(for: dossier).contains("your working directory"))

        // `doctor --agents` and the `agents` command are different reports.
        let report = DoctorAgents.report(table: t, path: "")
        XCTAssertTrue(try keys(report).isSubset(of: Set(OutputSchemas.all["doctor-agents"]!.keys)))
        XCTAssertTrue(try keys(try XCTUnwrap(report.agents.first)).isSubset(of: Set(OutputSchemas.agentStatus.keys)))
        XCTAssertNotNil(OutputSchemas.render("whois"))
        XCTAssertTrue(OutputSchemas.render("doctor-agents")?.hasPrefix("doctor --agents --json") == true)
        XCTAssertTrue(OutputSchemas.render("agents")?.hasPrefix("agents --json") == true)
    }
}
