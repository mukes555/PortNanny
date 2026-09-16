import XCTest
@testable import PortNannyCore
@testable import PortNanny

/// The search field's verbs and the Workbench's groupings, without a window.
final class PaletteAndWorkbenchTests: XCTestCase {

    private func port(_ number: Int, pid: Int = 1, name: String = "node", project: String? = nil, path: String? = nil,
                      owner: AgentOwner? = nil, memoryKB: Int = 1024) -> PortInfo {
        PortInfo(port: number, pid: pid, processName: name, command: "\(name) server.js", user: "me", memoryUsage: "1MB",
                 memorySizeKB: memoryKB, type: .nodejs, projectName: project, projectPath: path, agentOwner: owner)
    }

    // MARK: - Palette parsing

    func testVerbsFilterToThePortAndKeepTheVerb() {
        XCTAssertEqual(PaletteQuery.parse("kill 3000"), PaletteQuery(intent: .verb(.kill, port: 3000), rowFilter: "3000"))
        XCTAssertEqual(PaletteQuery.parse("  K :3000 "), PaletteQuery(intent: .verb(.kill, port: 3000), rowFilter: "3000"))
        XCTAssertEqual(PaletteQuery.parse("open 5173").intent, .verb(.open, port: 5173))
        XCTAssertEqual(PaletteQuery.parse("o 5173").intent, .verb(.open, port: 5173))
        XCTAssertEqual(PaletteQuery.parse("watch 8080").intent, .verb(.watch, port: 8080))
        XCTAssertEqual(PaletteQuery.parse("unguard 8080").intent, .verb(.guard, port: 8080))
        XCTAssertEqual(PaletteQuery.parse("free 3000").intent, .verb(.free, port: 3000))
    }

    func testPlainTextStaysASearch() {
        XCTAssertEqual(PaletteQuery.parse("node"), PaletteQuery(intent: .none, rowFilter: "node"))
        XCTAssertEqual(PaletteQuery.parse("kill me"), PaletteQuery(intent: .none, rowFilter: "kill me"), "not a port number")
        XCTAssertEqual(PaletteQuery.parse("kill 99999"), PaletteQuery(intent: .none, rowFilter: "kill 99999"), "out of range")
        XCTAssertEqual(PaletteQuery.parse("   "), PaletteQuery(intent: .none, rowFilter: ""))
        XCTAssertEqual(PaletteQuery.parse("3000"), PaletteQuery(intent: .none, rowFilter: "3000"))
    }

    func testCommandsAndFreePort() {
        XCTAssertEqual(PaletteQuery.parse(">").commandMatches, PaletteQuery.Command.allCases)
        XCTAssertEqual(PaletteQuery.parse("> work").commandMatches, [.workbench])
        XCTAssertEqual(PaletteQuery.parse(">HIST").commandMatches, [.history])
        XCTAssertTrue(PaletteQuery.parse("> nothing here").commandMatches.isEmpty)
        XCTAssertEqual(PaletteQuery.parse("free port").intent, .freePort(near: 3000))
        XCTAssertEqual(PaletteQuery.parse("free-port 8000").intent, .freePort(near: 8000))
        XCTAssertEqual(PaletteQuery.parse("freeport").intent, .freePort(near: 3000))
    }

    func testActionsResolveAgainstTheLivePorts() throws {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        let owner = AgentOwner(name: "Cursor", sessionPid: 7, source: .processTree)
        let ports = [port(3000, pid: 812, owner: owner), port(5173, pid: 813)]

        let kill = try XCTUnwrap(PaletteAction.resolve(PaletteQuery.parse("kill 3000"), ports: ports, manager: manager))
        XCTAssertEqual(kill.title, "Kill :3000")
        XCTAssertEqual(kill.detail, "node (PID 812) · owned by Cursor (session 7)")
        XCTAssertTrue(kill.isDestructive)
        XCTAssertTrue(kill.isRunnable)

        let free = try XCTUnwrap(PaletteAction.resolve(PaletteQuery.parse("kill 4000"), ports: ports, manager: manager))
        XCTAssertEqual(free.title, ":4000 is already free")
        XCTAssertFalse(free.isRunnable)

        let watch = try XCTUnwrap(PaletteAction.resolve(PaletteQuery.parse("watch 5173"), ports: ports, manager: manager))
        XCTAssertEqual(watch.kind, .watch(5173, on: true))
        XCTAssertEqual(watch.detail, "in use by node")

        let command = try XCTUnwrap(PaletteAction.resolve(PaletteQuery.parse("> refresh"), ports: ports, manager: manager))
        XCTAssertEqual(command.kind, .command(.refresh))
        XCTAssertNil(PaletteAction.resolve(PaletteQuery.parse("node"), ports: ports, manager: manager), "a plain search has no action")
    }

    func testSearchMatchesTheSameFieldsEverywhere() {
        let owner = AgentOwner(name: "Claude Code", sessionPid: 1, source: .processTree)
        let managed = ManagedRuntime(kind: .reloader, name: "nodemon", supervisorPid: 5, supervisorName: "node")
        let row = PortInfo(port: 3000, pid: 812, processName: "node", command: "node server.js", user: "me", memoryUsage: "1MB",
                           memorySizeKB: 1, type: .nodejs, projectName: "shop", containerName: "web-1", agentOwner: owner, managedBy: managed)
        for needle in ["3000", "NODE", "server", "shop", "web-1", "claude", "nodemon"] {
            XCTAssertTrue(PortSearch.matches(row, needle), needle)
        }
        XCTAssertFalse(PortSearch.matches(row, "python"))
    }

    // MARK: - Workbench groupings

    func testProjectsGroupByPathBusiestFirst() {
        let ports = [
            port(3000, project: "shop", path: "/p/shop", memoryKB: 100),
            port(3001, project: "shop", path: "/p/shop", memoryKB: 100),
            port(4000, project: "api", path: "/p/api", memoryKB: 500),
            port(5000),
        ]
        let groups = WorkbenchModel.projects(from: ports)
        XCTAssertEqual(groups.map(\.name), ["api", "shop", "No project"])
        XCTAssertEqual(groups[1].ports.map(\.port), [3000, 3001])
        XCTAssertEqual(groups[1].memoryKB, 200)
        XCTAssertNil(groups.last?.path)
    }

    func testAgentSessionsAreOrderedLiveEndedEditorUnattributed() {
        let live = AgentOwner(name: "Claude Code", sessionPid: 10, source: .processTree)
        let otherLive = AgentOwner(name: "Claude Code", sessionPid: 20, source: .processTree)
        let ended = AgentOwner(name: "Cursor", source: .environment, sessionEnded: true)
        let editor = AgentOwner(name: "VS Code", source: .environment, confidence: .editorTerminal)
        let ports = [
            port(3000, owner: live), port(3001, owner: live), port(3002, owner: otherLive),
            port(4000, owner: ended), port(5000, owner: editor), port(6000),
        ]
        let sessions = AgentSessions.groups(from: ports)
        XCTAssertEqual(sessions.map(\.kind), [.live, .live, .ended, .editor, .unattributed])
        XCTAssertEqual(sessions[0].ports.map(\.port), [3000, 3001], "two windows of one tool are two sessions")
        XCTAssertEqual(sessions[0].subtitle, "session 10 · from process tree")
        XCTAssertEqual(sessions[2].title, "Cursor")
        XCTAssertEqual(sessions[3].title, "VS Code terminal")
        XCTAssertEqual(sessions[4].title, "No agent")
        XCTAssertEqual(AgentSessions.orphaned(ports).map(\.port), [4000])
    }
}
