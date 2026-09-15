import XCTest
@testable import PortNannyCore
@testable import PortNanny

final class GuardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Isolate persisted watch/guard state
        UserDefaults.standard.removeObject(forKey: "PortNanny.watchedPorts")
        UserDefaults.standard.removeObject(forKey: "PortNanny.guardedPorts")
    }

    func testGuardingImpliesWatching() {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        manager.stopAutoRefresh()

        manager.toggleGuard(4242)
        XCTAssertTrue(manager.isGuarded(4242))
        XCTAssertTrue(manager.isWatched(4242))
    }

    func testUnwatchingRemovesGuard() {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        manager.stopAutoRefresh()

        manager.toggleGuard(4242)
        manager.toggleWatch(4242) // unwatch
        XCTAssertFalse(manager.isWatched(4242))
        XCTAssertFalse(manager.isGuarded(4242))
    }

    func testToggleGuardOffLeavesWatchOn() {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        manager.stopAutoRefresh()

        manager.toggleGuard(4242)
        manager.toggleGuard(4242) // guard off
        XCTAssertFalse(manager.isGuarded(4242))
        XCTAssertTrue(manager.isWatched(4242), "removing a guard should not silently unwatch")
    }

    /// Reproduced on 2.2.1: guarding the port a dev server was on killed that
    /// server on the next scan. The guard is for whatever arrives later.
    /// pid 999999 is one macOS never assigns, so no real process is at risk.
    func testGuardingABusyPortLeavesTheServerAlreadyThereAlone() {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        let server = Self.server(pid: 999_999)
        manager.activePorts = [server]
        manager.hasCompletedFirstScan = true

        manager.toggleGuard(server.port)
        manager.processWatchedPorts(with: [server])

        XCTAssertNil(manager.guardStrikes[server.port], "the guard went for the server it was set up to protect")
        XCTAssertTrue(manager.isGuarded(server.port))
    }

    /// Watching a busy port announced ":45019 is in use" about the server
    /// that was already there.
    func testWatchingABusyPortDoesNotReportItAsNewlyTaken() {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        let server = Self.server(pid: 999_999)
        manager.activePorts = [server]

        manager.toggleWatch(server.port)
        let nextScan = [server.port: PortManager.occupantIdentity(pid: server.pid, name: server.processName)]
        let events = PortManager.watchEvents(watched: manager.watchedPorts, previous: manager.watchedOccupancy, current: nextScan)

        XCTAssertEqual(events, [])
    }

    /// The seed must not blind the watch: a different process on the port
    /// is still news.
    func testWatchingABusyPortStillReportsAReplacement() {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        let server = Self.server(pid: 999_999)
        manager.activePorts = [server]

        manager.toggleWatch(server.port)
        let restarted = [server.port: PortManager.occupantIdentity(pid: 999_998, name: server.processName)]
        let events = PortManager.watchEvents(watched: manager.watchedPorts, previous: manager.watchedOccupancy, current: restarted)

        XCTAssertEqual(events, [PortManager.WatchEvent(port: server.port, kind: .occupied(by: "node"))])
    }

    private static func server(pid: Int) -> PortInfo {
        // Owned by whoever runs the tests: the guard never touches another
        // user's process, so a made-up user would pass for the wrong reason.
        PortInfo(port: 45019, pid: pid, processName: "node", command: "node", user: NSUserName(), memoryUsage: "1MB", memorySizeKB: 1, type: .nodejs)
    }
}
