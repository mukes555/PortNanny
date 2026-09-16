import XCTest
@testable import PortNannyCore
@testable import PortNanny

/// The app-side review fixes: dialogs, bulk kills, notifications, badges.
final class ReviewFixesUITests: XCTestCase {

    private func port(_ number: Int, pid: Int = 1, name: String = "node", owner: AgentOwner? = nil, connections: Int = 0,
                      managedBy: ManagedRuntime? = nil, reservation: Reservation? = nil, project: String? = nil) -> PortInfo {
        PortInfo(port: number, pid: pid, processName: name, command: "\(name) server.js", user: "me", memoryUsage: "1MB", memorySizeKB: 1,
                 type: .nodejs, projectName: project, projectPath: project.map { "/p/\($0)" }, agentOwner: owner, connections: connections,
                 managedBy: managedBy, reservation: reservation)
    }

    func testEveryKillDialogCarriesTheSameWarnings() {
        let live = AgentOwner(name: "Claude Code", sessionPid: 10, source: .processTree)
        let theirs = Reservation(port: 3000, owner: "Cursor", sessionKey: nil, sessionPid: 30, reason: "t", createdAt: Date(), ttl: 600)
        let busy = port(3000, owner: live, connections: 2, reservation: theirs)
        let warnings = KillFlow.warnings(for: busy)
        XCTAssertEqual(warnings.count, 3, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("Claude Code"), warnings[0])
        XCTAssertEqual(warnings[1], "2 clients are connected to it right now.")
        XCTAssertTrue(warnings[2].contains("reserved by Cursor"), warnings[2])
        XCTAssertEqual(KillFlow.warnings(for: port(3001)), [])
    }

    func testBulkKillsLeaveSupervisedServersForTheirOwnVerb() {
        let pm2 = ManagedRuntime(kind: .pm2, name: "api", stop: ["pm2", "stop", "api"])
        let targets = [port(3000), port(3001, name: "Cursor Helper"), port(3002, managedBy: pm2)]
        let (killable, supervised) = KillFlow.bulkTargets(targets) { $0 == "Cursor Helper" }
        XCTAssertEqual(killable.map(\.port), [3000])
        XCTAssertEqual(supervised.map(\.port), [3002])
        let note = KillFlow.skippedNote(supervised)
        XCTAssertTrue(note.hasPrefix("Skipped, because a supervisor would restart them: :3002 ("), note)
        XCTAssertTrue(note.hasSuffix("Stop those one at a time so the right verb is used."), note)
    }

    func testRefusalNotificationsOnlyRepeatWhatTheCLIRecorded() {
        let posted = RefusalSignal.Payload(port: 3000, processName: "node", owner: "Cursor", caller: "anyone")
        XCTAssertNil(RefusalWatcher.recordedRefusal(matching: posted, in: []), "a signal with no record behind it is noise")
        let record = PortHistoryItem(port: 3000, processName: "node", action: .refused, owner: "Cursor\u{1b}[31m", killedBy: "Claude Code (session 1) via CLI")
        let shown = RefusalWatcher.recordedRefusal(matching: posted, in: [record])
        XCTAssertEqual(shown?.caller, "Claude Code (session 1) via CLI", "the notification says what the store says, not what the signal said")
        XCTAssertEqual(shown?.owner, "Cursor [31m", "control characters never reach a notification")
        XCTAssertNil(RefusalWatcher.recordedRefusal(matching: posted, in: [record], now: Date(timeIntervalSinceNow: 120)), "an old record does not back a fresh signal")
        let kill = PortHistoryItem(port: 3000, processName: "node", action: .killed)
        XCTAssertNil(RefusalWatcher.recordedRefusal(matching: posted, in: [kill]), "a kill is not a refusal")
    }

    func testBadgesCountWhatThePanesShow() {
        let live = AgentOwner(name: "Claude Code", sessionPid: 10, source: .processTree)
        let otherLive = AgentOwner(name: "Claude Code", sessionPid: 20, source: .processTree)
        let ended = AgentOwner(name: "Cursor", source: .environment, sessionEnded: true)
        let editor = AgentOwner(name: "VS Code", source: .environment, confidence: .editorTerminal)
        let ports = [
            port(3000, owner: live, project: "shop"), port(3001, owner: live, project: "shop"), port(3002, owner: otherLive, project: "api"),
            port(4000, owner: ended), port(5000, owner: editor), port(6000),
        ]
        XCTAssertEqual(WorkbenchModel.projectCount(of: ports), WorkbenchModel.projects(from: ports).count)
        XCTAssertEqual(AgentSessions.sessionCount(of: ports), AgentSessions.groups(from: ports).count)
        XCTAssertEqual(WorkbenchModel.projectCount(of: ports), 3)
        XCTAssertEqual(AgentSessions.sessionCount(of: ports), 5)
    }

    func testSignatureReflectsConnections() {
        let quiet = port(3000, connections: 0)
        let busy = port(3000, connections: 3)
        XCTAssertNotEqual(PortManager.stableSignature([quiet]), PortManager.stableSignature([busy]), "a client count change must republish the row")
    }
}
