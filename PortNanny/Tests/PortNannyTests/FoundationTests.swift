import XCTest
@testable import PortNannyCore

/// Phase A units: redaction, free-port selection, schema coverage, and the
/// full decision matrix.
final class FoundationTests: XCTestCase {

    // MARK: - Redaction gaps found by the audit

    func testRedactionCatchesDigitNamesQuotedSecretsAndChildCommands() {
        let cases = [
            "docker run -e S3_SECRET_KEY=abc123 img",
            "env AUTH0_SECRET=hunter2 node app.js",
            "node app --config {\"token\":\"sk-live-1\"}",
            "curl -H 'X-API-Key: abc' https://x",
        ]
        for command in cases {
            let redacted = CommandRedaction.redact(command)
            XCTAssertFalse(redacted.contains("abc123"), redacted)
            XCTAssertFalse(redacted.contains("hunter2"), redacted)
            XCTAssertFalse(redacted.contains("sk-live-1"), redacted)
            XCTAssertTrue(redacted.contains(CommandRedaction.mask) || !redacted.contains("abc"), redacted)
        }
        XCTAssertEqual(CommandRedaction.redact("node server.js --port 3000"), "node server.js --port 3000", "an innocent line is untouched")
    }

    func testControlCharactersCannotReachATerminal() {
        let spoofed = "node\u{1b}[2K\rKilled everything\u{7}"
        let safe = CommandRedaction.printable(spoofed)
        XCTAssertFalse(safe.contains("\u{1b}"), safe)
        XCTAssertFalse(safe.contains("\r"), safe)
        XCTAssertTrue(safe.hasPrefix("node"))
        XCTAssertEqual(CommandRedaction.printable("plain text\ttabbed"), "plain text\ttabbed", "tabs are how tables line up")
    }

    func testALeaseReasonIsCappedAndStripped() {
        let lease = Reservation(port: 3000, owner: "bot", reason: String(repeating: "x", count: 5000) + "\u{1b}[31m")
        XCTAssertEqual(lease.reason?.count, 200)
        XCTAssertFalse(lease.reason?.contains("\u{1b}") ?? true)
    }

    func testRedactionCoversTheCommonShapes() {
        XCTAssertEqual(CommandRedaction.redact("node server.js --token=abc123 --port 3000"), "node server.js --token=[redacted] --port 3000")
        XCTAssertEqual(CommandRedaction.redact("app --api-key sk-live-xyz"), "app --api-key [redacted]")
        XCTAssertEqual(CommandRedaction.redact("DATABASE_PASSWORD=hunter2 rails s"), "DATABASE_PASSWORD=[redacted] rails s")
        XCTAssertEqual(CommandRedaction.redact("pg -d postgres://admin:s3cret@db:5432/app"), "pg -d postgres://admin:[redacted]@db:5432/app")
        XCTAssertEqual(CommandRedaction.redact("curl -H 'Authorization: Bearer eyJhbGci' x"), "curl -H 'Authorization: Bearer [redacted]' x")
        XCTAssertEqual(CommandRedaction.redact("node --port 3000 --host 0.0.0.0"), "node --port 3000 --host 0.0.0.0", "nothing sensitive stays untouched")
    }

    func testFirstFreePortPrefersThePreferredThenScans() {
        // `probe: false` keeps this about the choosing logic. Probing binds real
        // ports, so the test used to fail whenever the machine running it had a
        // dev server on 3000, which for this project is most machines.
        XCTAssertEqual(PortNannyCLI.firstFreePort(prefer: 3000, range: 3000...3010, listening: [], probe: false), 3000)
        XCTAssertEqual(PortNannyCLI.firstFreePort(prefer: 3000, range: 3000...3010, listening: [3000, 3001], probe: false), 3002)
        XCTAssertNil(PortNannyCLI.firstFreePort(prefer: 3000, range: 3000...3001, listening: [3000, 3001], probe: false))
    }

    func testFreePortArgumentsParse() {
        XCTAssertEqual(CLIArguments.parse(["free-port"]), .success(.freePort(prefer: 3000, range: 3000...3999, json: false)))
        XCTAssertEqual(CLIArguments.parse(["free-port", "--prefer", "8080", "--range", "8000-8100", "--json"]), .success(.freePort(prefer: 8080, range: 8000...8100, json: true)))
        XCTAssertEqual(CLIArguments.parse(["free-port", "--range", "9000-8000"]), .failure(.invalidNumber("9000-8000", option: "--range")))
        XCTAssertEqual(CLIArguments.parse(["free-port", "--prefer", "1", "--range", "3000-3100"]).debugDescription.contains("outside"), true)
        XCTAssertEqual(CLIArguments.parse(["schema", "kill"]), .success(.schema(command: "kill")))
    }

    func testEncodedOutputStaysWithinTheWrittenSchema() throws {
        let owner = AgentOwner(name: "Claude Code", sessionPid: 1, sessionKey: "k", source: .processTree)
        let port = PortInfo(port: 3000, pid: 1, processName: "node", command: "node", user: "me", memoryUsage: "1MB",
                            memorySizeKB: 1024, type: .nodejs, projectName: "p", projectPath: "/p", containerName: "c",
                            children: [PortInfo.ProcessInfo(pid: 2, name: "n", command: "c")], bindAddress: "*", age: "1m",
                            agentOwner: owner, connections: 2)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(port)) as? [String: Any])
        for key in encoded.keys {
            XCTAssertNotNil(OutputSchemas.port[key], "PortInfo emits '\(key)' but the schema doesn't describe it")
        }
        let ownerJSON = try XCTUnwrap(encoded["agentOwner"] as? [String: Any])
        for key in ownerJSON.keys {
            XCTAssertNotNil(OutputSchemas.agentOwner[key], "AgentOwner emits '\(key)' but the schema doesn't describe it")
        }
        for command in OutputSchemas.commands {
            XCTAssertNotNil(OutputSchemas.render(command), command)
        }
        XCTAssertNil(OutputSchemas.render("nope"))
    }

    /// Every combination of caller and target the guard can see, against the
    /// invariants the docs promise.
    func testDecisionMatrixInvariants() {
        let live = { (name: String, session: Int?) in AgentOwner(name: name, sessionPid: session, source: .processTree) }
        let ended = AgentOwner(name: "Claude Code", source: .environment, sessionEnded: true)
        let terminal = AgentOwner(name: "Cursor", source: .environment, confidence: .editorTerminal)
        let declared = AgentOwner(name: "my-bot", source: .declared)
        let owners: [AgentOwner?] = [nil, live("Claude Code", 1), live("Claude Code", 2), live("Claude Code", nil), live("Cursor", 3), ended, terminal, declared]

        for caller in owners {
            for target in owners {
                let decision = KillDecision.forAgent(caller: caller, target: target)
                let human = KillDecision.forHuman(target: target)
                XCTAssertNotEqual(decision, .warn(""), "agents are refused or allowed, never warned")
                if case .refuse = human { XCTFail("a person is never refused") }
                if caller == nil { XCTAssertEqual(decision, .allow, "unknown caller never blocks") }
                if let caller, caller.confidence == .editorTerminal, target?.isLiveAgentSession != true {
                    XCTAssertEqual(decision, .allow, "an editor terminal is a person unless a running agent session is at stake")
                }
                if let caller, let target, caller.confidence == .editorTerminal, target.isLiveAgentSession, caller.name != target.name {
                    XCTAssertTrue(decision.isRefusal, "an editor terminal may hide that editor's agent")
                }
                if let target, target.sessionEnded { XCTAssertEqual(decision, .allow, "an ended session never blocks") }
                if let target, target.confidence == .editorTerminal { XCTAssertEqual(decision, .allow, "a person's terminal never blocks") }
                if let caller, caller.confidence == .agent, target == nil { XCTAssertTrue(decision.isRefusal, "agents don't kill what nobody claims") }
                if let caller, let target, caller.confidence == .agent, target.isLiveAgentSession, caller.name != target.name {
                    XCTAssertTrue(decision.isRefusal, "a different agent's live session is refused")
                }
                if let caller, let target, caller.confidence == .agent, target.isLiveAgentSession, caller.name == target.name {
                    let same = caller.isSameSession(as: target)
                    let claimable = same == true || (same == nil && !target.hasKnownSession)
                    XCTAssertEqual(decision.isRefusal, !claimable, "the same session, or two unknown ones, of one tool is allowed; a known session needs the caller to show it")
                }
            }
        }
    }
}
