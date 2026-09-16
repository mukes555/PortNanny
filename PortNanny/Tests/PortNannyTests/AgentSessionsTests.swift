import XCTest
@testable import PortNannyCore
@testable import PortNanny

/// The Agents view: what is listening grouped by the session that started it,
/// plus the ports a session has claimed and not started on yet.
final class AgentSessionsTests: XCTestCase {

    private func port(_ number: Int, pid: Int = 1, owner: AgentOwner? = nil) -> PortInfo {
        PortInfo(port: number, pid: pid, processName: "node", command: "node server.js", user: "me",
                 memoryUsage: "1MB", memorySizeKB: 1024, type: .nodejs, agentOwner: owner)
    }

    private let claude = AgentOwner(name: "Claude Code", sessionPid: 10, sessionKey: "abc", source: .processTree)

    func testAClaimJoinsTheSessionThatHoldsIt() {
        let lease = Reservation(port: 3100, owner: "Claude Code", sessionKey: "abc", sessionPid: 10, reason: "checkout page")
        let groups = AgentSessions.groups(from: [port(3000, owner: claude)], leases: [lease])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].ports.map(\.port), [3000])
        XCTAssertEqual(groups[0].claims.map(\.port), [3100], "the port it said it was about to use")
    }

    func testAnAgentWithOnlyAClaimStillGetsASection() {
        let lease = Reservation(port: 3100, owner: "Codex CLI", sessionKey: "z9", sessionPid: 42, reason: "api")
        let groups = AgentSessions.groups(from: [port(3000, owner: claude)], leases: [lease])

        XCTAssertEqual(groups.map(\.title), ["Claude Code", "Codex CLI"])
        XCTAssertEqual(groups[1].ports, [], "it has not started anything yet")
        XCTAssertEqual(groups[1].claims.map(\.port), [3100])
        XCTAssertEqual(groups[1].kind, .live)
    }

    func testAClaimOnAPortSomethingIsAlreadyListeningOnIsNotRepeated() {
        let lease = Reservation(port: 3000, owner: "Claude Code", sessionKey: "abc", sessionPid: 10)
        let groups = AgentSessions.groups(from: [port(3000, owner: claude)], leases: [lease])

        XCTAssertEqual(groups[0].claims, [], "the row itself carries the lease chip")
    }

    func testAPersonsOwnLeaseIsNotAnAgentSession() {
        let mine = Reservation(port: 4000, owner: "mbp")
        let groups = AgentSessions.groups(from: [port(3000, owner: claude)], leases: [mine], user: "mbp")

        XCTAssertEqual(groups.map(\.title), ["Claude Code", "No agent"])
        XCTAssertEqual(groups[1].claims.map(\.port), [4000])
    }

    func testEndedSessionsShareOneSectionAndSortAfterLiveOnes() {
        let endedYesterday = AgentOwner(name: "Claude Code", sessionPid: 1, source: .processTree, sessionEnded: true)
        let endedToday = AgentOwner(name: "Claude Code", sessionPid: 2, source: .processTree, sessionEnded: true)
        let groups = AgentSessions.groups(from: [
            port(4000, pid: 2, owner: endedYesterday),
            port(4001, pid: 3, owner: endedToday),
            port(3000, owner: claude),
        ])

        XCTAssertEqual(groups.map(\.kind), [.live, .ended])
        XCTAssertEqual(groups[1].ports.map(\.port), [4000, 4001],
                       "which of yesterday's sessions left a server behind is not a useful distinction")
        XCTAssertEqual(AgentSessions.orphaned(groups.flatMap(\.ports)).map(\.port), [4000, 4001])
    }

    func testTheSummaryCountsOnlyWhatIsRunning() {
        let ports = [port(3000, owner: claude), port(3001, pid: 2, owner: claude)]
        XCTAssertEqual(AgentSessions.liveSessionCount(of: ports), 1, "one session, two servers")
        XCTAssertEqual(AgentSessions.sessionCount(of: ports), 1)
        XCTAssertEqual(AgentSessions.groups(from: ports)[0].memoryKB, 2048)
    }

    // MARK: - `portnanny agents`

    func testTheAgentsCommandParses() {
        XCTAssertEqual(CLIArguments.parse(["agents"]), .success(.agents(json: false)))
        XCTAssertEqual(CLIArguments.parse(["agents", "--json"]), .success(.agents(json: true)))
        guard case .failure? = CLIArguments.parse(["agents", "--nope"]) else {
            return XCTFail("an option the command does not know is an error, never ignored")
        }
    }

    func testEachLineNamesTheSessionAndWhatItHolds() {
        let lease = Reservation(port: 3100, owner: "Codex CLI", sessionKey: "s-42", reason: "api")
        let ended = AgentOwner(name: "Cursor", sessionPid: 7, source: .environment, sessionEnded: true)
        let groups = AgentSessions.groups(from: [port(3000, owner: claude), port(4000, pid: 2, owner: ended)],
                                          leases: [lease])
        let lines = CLIAgents.lines(for: groups, caller: claude)

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("Claude Code"), lines[0])
        XCTAssertTrue(lines[0].contains("running"), lines[0])
        XCTAssertTrue(lines[0].contains(":3000"), lines[0])
        XCTAssertTrue(lines[0].contains("← you"), "an agent reading this should find itself")
        XCTAssertTrue(lines[1].contains("claims :3100"), lines[1])
        XCTAssertFalse(lines[1].contains("← you"), "another agent's session is not yours")
        XCTAssertTrue(lines[2].contains("ended"), lines[2])
    }

    func testALongListOfPortsIsCutRatherThanWrapped() {
        let ports = (1...14).map { port(45000 + $0, pid: $0) }
        let lines = CLIAgents.lines(for: AgentSessions.groups(from: ports), caller: nil)
        XCTAssertTrue(lines[0].contains("+4 more"), lines[0])
        XCTAssertFalse(lines[0].contains(":45014"), "the tail is counted, not printed")
    }

    // MARK: - The setting the two views replaced

    func testAnUpgradeFromAdvancedKeepsItsDetail() throws {
        let suite = "PortNannyViewMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.discardSuite(named: suite, defaults: defaults) }
        defaults.set("advanced", forKey: DefaultsKey.viewDensity)

        let manager = PortManager(defaults: defaults, history: HistoryManager(defaults: defaults), autoStart: false)
        defer { manager.stopAutoRefresh() }

        XCTAssertTrue(manager.showsDetails, "Advanced became the detail switch")
        XCTAssertEqual(manager.viewMode, .agents, "and everyone starts in the view this app is for")
    }

    func testAnUpgradeFromCleanStartsWithoutDetail() throws {
        let suite = "PortNannyViewMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.discardSuite(named: suite, defaults: defaults) }
        defaults.set("clean", forKey: DefaultsKey.viewDensity)

        let manager = PortManager(defaults: defaults, history: HistoryManager(defaults: defaults), autoStart: false)
        defer { manager.stopAutoRefresh() }

        XCTAssertFalse(manager.showsDetails)
        XCTAssertEqual(manager.viewMode, .agents)
    }

    func testAChosenViewSurvivesARestart() throws {
        let suite = "PortNannyViewMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.discardSuite(named: suite, defaults: defaults) }

        let manager = PortManager(defaults: defaults, history: HistoryManager(defaults: defaults), autoStart: false)
        manager.viewMode = .ports
        manager.showsDetails = true
        manager.stopAutoRefresh()

        let restarted = PortManager(defaults: defaults, history: HistoryManager(defaults: defaults), autoStart: false)
        defer { restarted.stopAutoRefresh() }
        XCTAssertEqual(restarted.viewMode, .ports)
        XCTAssertTrue(restarted.showsDetails)
    }
}
