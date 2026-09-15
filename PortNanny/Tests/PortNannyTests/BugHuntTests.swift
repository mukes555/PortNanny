import XCTest
@testable import PortNannyCore
@testable import PortNanny

/// Regressions for the bugs found by the September 2026 bug hunt: fuzzing,
/// concurrent processes, corrupted stores, and hostile tools. Every behaviour
/// here was reproduced against the shipped 2.2.1 binary before it was fixed.
final class BugHuntTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        suites = []
    }

    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "PortNannyBugHunt.\(UUID().uuidString)"
        suites.append(suite)
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: - One damaged entry must not take the rest with it

    func testDecodingKeepsEveryEntryThatStillDecodes() throws {
        let json = #"[{"port":1,"owner":"a","createdAt":"2026-09-16T00:00:00Z","expiresAt":"2099-01-01T00:00:00Z"},"#
            + #"{"port":2,"owner":"b","createdAt":"2026-09-16T00:00:00Z","expiresAt":"not a date"},"#
            + #"{"port":3,"owner":"c","createdAt":"2026-09-16T00:00:00Z","expiresAt":"2099-01-01T00:00:00Z"}]"#
        let leases = try XCTUnwrap(SharedStore.decodeArray(Reservation.self, from: Data(json.utf8)))
        XCTAssertEqual(leases.map(\.port), [1, 3], "the damaged middle entry goes, its neighbours stay")
    }

    func testDataThatIsNotAnArrayIsReportedAsSuch() {
        XCTAssertNil(SharedStore.decodeArray(Reservation.self, from: Data("not json".utf8)))
        XCTAssertNil(SharedStore.decodeArray(Reservation.self, from: Data(#"{"port":1}"#.utf8)))
        XCTAssertEqual(SharedStore.decodeArray(Reservation.self, from: Data("[]".utf8))?.count, 0)
    }

    /// One mangled date used to make every lease vanish, let a second agent
    /// take a port a live lease still held, and erase the rest on the next write.
    func testADamagedLeaseNeitherHidesNorErasesTheValidOnes() throws {
        let (defaults, suite) = freshDefaults()
        let store = ReservationStore(defaults: defaults, lockName: suite)
        let alice = AgentOwner(name: "Alice", sessionKey: "a", source: .declared)
        let bob = AgentOwner(name: "Bob", sessionKey: "b", source: .declared)
        let carol = AgentOwner(name: "Carol", sessionKey: "c", source: .declared)
        try store.reserve(Reservation(port: 45013, owner: "Alice", sessionKey: "a", ttl: 1800), by: alice)
        try store.reserve(Reservation(port: 45014, owner: "Bob", sessionKey: "b", ttl: 1800), by: bob)
        try store.reserve(Reservation(port: 45015, owner: "Carol", sessionKey: "c", ttl: 1800), by: carol)

        var stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: DefaultsKey.reservations))) as? [[String: Any]])
        stored[1]["expiresAt"] = "not a date"
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: DefaultsKey.reservations)

        XCTAssertEqual(store.all().map(\.port), [45013, 45015], "the two good leases are still visible")

        let mallory = AgentOwner(name: "Mallory", sessionKey: "m", source: .declared)
        XCTAssertThrowsError(try store.reserve(Reservation(port: 45013, owner: "Mallory", sessionKey: "m", ttl: 300), by: mallory),
                             "a port Alice still holds is not handed to someone else")

        try store.reserve(Reservation(port: 45016, owner: "Dave", sessionKey: "d", ttl: 1800), by: AgentOwner(name: "Dave", sessionKey: "d", source: .declared))
        XCTAssertEqual(store.all().map(\.port), [45013, 45015, 45016], "an ordinary write keeps the good leases on disk")
    }

    func testADamagedHistoryEntryDoesNotWipeTheHistoryOnTheNextKill() throws {
        let (defaults, suite) = freshDefaults()
        let history = HistoryManager(defaults: defaults, lockName: suite)
        history.addEntry(port: 3000, processName: "node", action: .killed)
        history.addEntry(port: 5173, processName: "vite", action: .killed)

        var stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: DefaultsKey.history))) as? [[String: Any]])
        stored[0]["action"] = "a word no version of PortNanny knows"
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: DefaultsKey.history)

        history.addEntry(port: 8080, processName: "api", action: .killed)
        let fresh = HistoryManager(defaults: defaults, lockName: suite)
        XCTAssertEqual(Set(fresh.history.map(\.port)), [8080, 3000],
                       "only the unreadable entry is lost; the next kill used to save itself over everything")
    }

    // MARK: - Pids from untrusted places

    /// `CLAUDE_PID=9999999999 portnanny whoami` trapped narrowing to Int32.
    func testCLAUDEPIDIsOnlyAPidWhenItCouldBeOne() {
        let key = AgentSignatures.claudeSessionKey
        XCTAssertEqual(AgentSignatures.claudeSessionPid(in: [key: "4531"]), 4531)
        XCTAssertNil(AgentSignatures.claudeSessionPid(in: [key: "9999999999"]), "past a 32-bit pid")
        XCTAssertNil(AgentSignatures.claudeSessionPid(in: [key: "0"]))
        XCTAssertNil(AgentSignatures.claudeSessionPid(in: [key: "-1"]))
        XCTAssertNil(AgentSignatures.claudeSessionPid(in: [key: "abc"]))
        XCTAssertNil(AgentSignatures.claudeSessionPid(in: [:]))
    }

    func testTheAncestryWalkSkipsAPidNoProcessCanHave() {
        let table = ProcessTable.ancestry(of: Int(getpid()), including: [9_999_999_999, -5, Int.max])
        XCTAssertTrue(table.entries.contains { $0.pid == Int(getpid()) }, "the real chain is still walked")
    }

    /// Any process running as this user can write the shared lease store.
    func testALeaseNamingAnImpossiblePidIsNotOrphanedAndDoesNotTrap() {
        let lease = Reservation(port: 45012, owner: "x", sessionPid: 9_999_999_999, ttl: 600)
        XCTAssertFalse(lease.isOrphaned())
        XCTAssertFalse(Reservation(port: 45012, owner: "x", sessionPid: -1, ttl: 600).isOrphaned())
    }

    // MARK: - The MCP server stays up

    private func reply(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let text = try XCTUnwrap(server.handle(line: line))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// `-1e999` parses to -Infinity, which the encoder raised an uncatchable
    /// exception for, killing the server and every later call in the session.
    func testANonFiniteRequestIDIsRefusedAndTheServerKeepsAnswering() throws {
        let server = MCPServer()
        let refused = try reply(server, #"{"jsonrpc":"2.0","id":-1e999,"method":"ping"}"#)
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(refused["id"] is NSNull)

        let next = try reply(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual(next["id"] as? Int, 2, "the same server answers the next request")
    }

    func testOnlyStringsFiniteNumbersAndNullAreRequestIDs() {
        XCTAssertTrue(MCPServer.isValidRequestID("abc"))
        XCTAssertTrue(MCPServer.isValidRequestID(NSNumber(value: 7)))
        XCTAssertTrue(MCPServer.isValidRequestID(NSNumber(value: 1.5)))
        XCTAssertTrue(MCPServer.isValidRequestID(NSNull()))
        XCTAssertFalse(MCPServer.isValidRequestID(NSNumber(value: Double.infinity)))
        XCTAssertFalse(MCPServer.isValidRequestID(NSNumber(value: Double.nan)))
        XCTAssertFalse(MCPServer.isValidRequestID(kCFBooleanTrue as Any), "true is not an id")
        XCTAssertFalse(MCPServer.isValidRequestID([1]))
        XCTAssertFalse(MCPServer.isValidRequestID(["id": 1]))
    }
}
