import XCTest
@testable import PortNannyCore

/// Phase C1: leases on free ports, and the commands around them.
final class ReservationTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!
    private var store: ReservationStore!

    override func setUp() {
        suite = "com.mukes555.PortNanny.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = ReservationStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // A lease pinned to a session pid ends with that process, so the sessions
    // here are processes that outlive the test: this one and its parent.
    private let claude = AgentOwner(name: "Claude Code", sessionPid: Int(getpid()), sessionKey: "abc", source: .processTree)
    private let otherClaude = AgentOwner(name: "Claude Code", sessionPid: Int(getppid()), sessionKey: "def", source: .processTree)
    private let cursor = AgentOwner(name: "Cursor", sessionPid: 30, source: .processTree)

    private func lease(_ port: Int, by owner: AgentOwner, ttl: TimeInterval = 600, at date: Date = Date()) -> Reservation {
        Reservation(port: port, owner: owner.name, sessionKey: owner.sessionKey, sessionPid: owner.sessionPid, reason: "test", createdAt: date, ttl: ttl)
    }

    func testTTLParsingAndClamping() {
        XCTAssertEqual(Reservation.parseTTL("10m"), 600)
        XCTAssertEqual(Reservation.parseTTL("2h"), 7200)
        XCTAssertEqual(Reservation.parseTTL("90s"), 90)
        XCTAssertEqual(Reservation.parseTTL("1d"), 86400)
        XCTAssertEqual(Reservation.parseTTL("15"), 900, "a bare number is minutes")
        XCTAssertNil(Reservation.parseTTL("soon"))
        XCTAssertNil(Reservation.parseTTL("0m"))
        let long = Reservation(port: 1, owner: "x", ttl: 10 * 86400)
        XCTAssertEqual(long.expiresAt.timeIntervalSince(long.createdAt), Reservation.maxTTL, "a day at most")
        XCTAssertEqual(ElapsedFormat.humanize(seconds: 3900), "1h 5m")
        XCTAssertEqual(ElapsedFormat.humanize(seconds: 90), "1m")
    }

    func testLeasesRoundTripWithISODates() throws {
        let original = lease(3000, by: claude)
        let data = try JSONEncoder().encode(original)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"expiresAt\":\"20"), "ISO 8601, not a float: \(text)")
        let decoded = try JSONDecoder().decode(Reservation.self, from: data)
        XCTAssertEqual(decoded.port, 3000)
        XCTAssertEqual(decoded.owner, "Claude Code")
        XCTAssertEqual(decoded.sessionKey, "abc")
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, original.expiresAt.timeIntervalSince1970, accuracy: 1)
    }

    func testHoldersAndStrangers() {
        let mine = lease(3000, by: claude)
        XCTAssertTrue(mine.isHeld(by: claude))
        XCTAssertFalse(mine.isHeld(by: otherClaude), "another session of the same tool is a stranger")
        XCTAssertFalse(mine.isHeld(by: cursor))
        XCTAssertFalse(mine.isHeld(by: AgentOwner(name: "Claude Code", source: .declared)), "a lease pinned to a session needs that session, not just the name")
        let nameOnly = Reservation(port: 3002, owner: "Claude Code")
        XCTAssertTrue(nameOnly.isHeld(by: AgentOwner(name: "Claude Code", source: .declared)), "a lease without a session matches by name")
        XCTAssertFalse(mine.isHeld(by: nil, user: "mbp"))
        let personal = Reservation(port: 3001, owner: "mbp")
        XCTAssertTrue(personal.isHeld(by: nil, user: "mbp"))
        XCTAssertFalse(personal.isHeld(by: claude))
    }

    func testStoreReservesRenewsConflictsAndPrunes() throws {
        try store.reserve(lease(3000, by: claude), by: claude)
        XCTAssertEqual(store.all().map(\.port), [3000])
        XCTAssertThrowsError(try store.reserve(lease(3000, by: cursor), by: cursor)) { error in
            XCTAssertEqual(error as? ReservationStore.Conflict, .heldByAnother(store.reservation(for: 3000)!))
        }
        let renewed = lease(3000, by: claude, ttl: 1200)
        try store.reserve(renewed, by: claude)
        // The store keeps whole seconds (ISO 8601), so compare to the second.
        XCTAssertEqual(store.reservation(for: 3000)?.expiresAt.timeIntervalSince1970 ?? 0, renewed.expiresAt.timeIntervalSince1970, accuracy: 1, "the holder renews")

        try store.reserve(lease(3001, by: cursor, ttl: 1, at: Date(timeIntervalSinceNow: -5)), by: cursor)
        XCTAssertEqual(store.all().map(\.port), [3000], "an expired lease is gone")
        XCTAssertEqual(store.portsReservedByOthers(for: cursor), [3000])
        XCTAssertEqual(store.portsReservedByOthers(for: claude), [])

        let held = try XCTUnwrap(store.reservation(for: 3000))
        XCTAssertEqual(store.release(port: 3000, by: cursor), .heldByAnother(held))
        XCTAssertEqual(store.release(port: 3000, by: cursor, force: true), .released(held))
        XCTAssertEqual(store.release(port: 3000, by: claude), .none)
        XCTAssertNil(defaults.data(forKey: DefaultsKey.reservations), "an empty store leaves no key behind")
    }

    func testGuardTreatsLeasesLikeOwners() {
        let theirs = lease(3000, by: cursor)
        XCTAssertTrue(KillDecision.forReservation(caller: claude, reservation: theirs, asAgent: true).isRefusal)
        XCTAssertEqual(KillDecision.forReservation(caller: cursor, reservation: theirs, asAgent: true), .allow)
        XCTAssertEqual(KillDecision.forReservation(caller: claude, reservation: nil, asAgent: true), .allow)
        if case .warn(let reason) = KillDecision.forReservation(caller: nil, reservation: theirs, asAgent: false) {
            XCTAssertTrue(reason.contains("reserved by Cursor (session 30)"), reason)
        } else {
            XCTFail("a person is warned, never refused")
        }
        let terminal = AgentOwner(name: "VS Code", source: .environment, confidence: .editorTerminal)
        XCTAssertFalse(KillDecision.forReservation(caller: terminal, reservation: theirs, asAgent: true).isRefusal, "editor terminals are people here too")
    }

    func testFreePortSkipsOtherPeoplesLeases() {
        XCTAssertEqual(PortNannyCLI.firstFreePort(prefer: 3000, range: 3000...3005, listening: [3000, 3001]), 3002)
    }

    func testReserveReleaseAndExecParse() {
        var expected = CLICommand.ReserveOptions(port: 3000)
        expected.ttl = 7200
        expected.reason = "e2e"
        expected.json = true
        XCTAssertEqual(CLIArguments.parse(["reserve", "3000", "--for", "2h", "--reason", "e2e", "--json"]), .success(.reserve(expected)))
        XCTAssertEqual(CLIArguments.parse(["reserve"]), .failure(.missingTarget))
        XCTAssertEqual(CLIArguments.parse(["reserve", "3000", "--for", "later"]), .failure(.invalidNumber("later", option: "--for")))
        XCTAssertEqual(CLIArguments.parse(["release", "3000", "--force"]), .success(.release(port: 3000, force: true, json: false)))
        XCTAssertEqual(CLIArguments.parse(["reservations", "--json"]), .success(.reservations(json: true)))

        var exec = CLICommand.ExecOptions()
        exec.port = 3000
        exec.command = ["npm", "run", "dev"]
        XCTAssertEqual(CLIArguments.parse(["exec", "--port", "3000", "--", "npm", "run", "dev"]), .success(.exec(exec)))
        var free = CLICommand.ExecOptions()
        free.prefer = 8000
        free.preferWasGiven = true
        free.range = 8000...8999
        free.reserve = false
        free.owner = "bot"
        free.command = ["python", "-m", "http.server"]
        XCTAssertEqual(CLIArguments.parse(["exec", "--free-port", "--prefer=8000", "--no-reserve", "--owner", "bot", "python", "-m", "http.server"]), .success(.exec(free)))
        XCTAssertEqual(CLIArguments.parse(["exec", "--port", "3000"]), .failure(.missingValue("exec [--port N | --free-port] -- <command>")))
        XCTAssertEqual(CLIArguments.parse(["exec", "--bogus", "cmd"]), .failure(.unknownOption("--bogus", command: "exec")))
        XCTAssertTrue(CLIArguments.usage(for: "exec").contains("PORT"))
        XCTAssertTrue(CLIArguments.usage(for: "reserve").contains("--for"))
    }

    func testReservationOutputsStayWithinTheWrittenSchema() throws {
        let keys = try Set(XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(lease(3000, by: claude))) as? [String: Any]).keys)
        XCTAssertTrue(keys.isSubset(of: Set(OutputSchemas.reservation.keys)), "\(keys)")
        XCTAssertNotNil(OutputSchemas.render("reserve"))
        XCTAssertNotNil(OutputSchemas.render("reservations"))
        XCTAssertTrue(OutputSchemas.commands.contains("release"))
    }
}
