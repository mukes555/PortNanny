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

    // MARK: - Every process shares one History

    /// Each `portnanny free` and MCP `kill_port` builds its own store. It assumed
    /// the default limit, so one agent kill cut a History of 500 down to 50.
    func testAnAgentKillKeepsTheHistoryLengthThePersonChose() throws {
        let (defaults, suite) = freshDefaults()
        defaults.set(500, forKey: DefaultsKey.historyLimit)
        let app = HistoryManager(defaults: defaults, lockName: suite)
        app.maxHistoryItems = 500
        for port in 1...120 {
            app.addEntry(port: port, processName: "node", action: .killed)
        }

        let agentProcess = HistoryManager(defaults: defaults, lockName: suite)
        agentProcess.addEntry(port: 45019, processName: "vite", action: .killed, killedBy: "Claude Code")

        XCTAssertEqual(HistoryManager(defaults: defaults, lockName: suite).history.count, 121)
    }

    /// A stored limit outside what Settings offers is ignored, as the app does.
    func testAnImpossibleStoredHistoryLimitFallsBackToTheDefault() throws {
        let (defaults, suite) = freshDefaults()
        defaults.set(3, forKey: DefaultsKey.historyLimit)
        XCTAssertEqual(HistoryManager(defaults: defaults, lockName: suite).maxHistoryItems, HistoryManager.defaultLimit)
        defaults.set("lots", forKey: DefaultsKey.historyLimit)
        XCTAssertEqual(HistoryManager(defaults: defaults, lockName: suite).maxHistoryItems, HistoryManager.defaultLimit)
    }

    /// Changing the limit in Settings saved the app's own copy of History,
    /// dropping every kill an agent had recorded since the app last read it.
    func testChangingTheLimitKeepsKillsAnotherProcessRecorded() throws {
        let (defaults, suite) = freshDefaults()
        let app = HistoryManager(defaults: defaults, lockName: suite)
        let agentProcess = HistoryManager(defaults: defaults, lockName: suite)
        agentProcess.addEntry(port: 45019, processName: "vite", action: .killed, killedBy: "Codex")

        app.maxHistoryItems = 100

        XCTAssertEqual(HistoryManager(defaults: defaults, lockName: suite).history.map(\.port), [45019])
    }

    // MARK: - Command lines a process chose itself

    /// Redaction runs on every listener of every scan. The key patterns used
    /// to backtrack over every way of splitting a run of word characters, so
    /// one process with a long argument froze the menu bar, the CLI and the
    /// guard: 800 characters took 2.6s, a few kilobytes took minutes.
    func testALongArgumentDoesNotStallRedaction() {
        let hostile = "node --serve " + String(repeating: "token", count: 2000) + " --port 3000"
        let started = Date()
        _ = CommandRedaction.redact(hostile)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "10 KB of one word must not take a second")
    }

    func testALongArgumentDoesNotHideASecretAfterIt() {
        let hostile = "node " + String(repeating: "token", count: 2000) + " --api-key=sk-live-9"
        XCTAssertFalse(CommandRedaction.redact(hostile).contains("sk-live-9"))
    }

    /// "\r\n" is one Swift Character of two scalars, and the sanitizer used
    /// to pass any multi-scalar character through untouched: a process could
    /// name itself so that `portnanny list` printed an extra row.
    func testACarriageReturnInAProcessNameIsNeutralised() {
        let spoofed = CommandRedaction.printable("node\r\n3000  evil  1 MB")
        XCTAssertFalse(spoofed.contains("\r"))
        XCTAssertFalse(spoofed.contains("\n"))
        XCTAssertTrue(spoofed.hasPrefix("node"))
        XCTAssertEqual(CommandRedaction.printable("vite ⚡️ dev"), "vite ⚡️ dev", "only control characters go")
    }

    // MARK: - Arguments, leases and links

    /// `--range` on its own is in the help text and in the agent docs, and it
    /// was rejected: the preferred port nobody had asked for was still 3000,
    /// outside the range.
    func testARangeOnItsOwnMovesThePreferredPortIntoIt() {
        guard case .success(.freePort(let prefer, let range, _))? = CLIArguments.parse(["free-port", "--range", "5000-5999"]) else {
            return XCTFail("`free-port --range 5000-5999` was rejected")
        }
        XCTAssertEqual(range, 5000...5999)
        XCTAssertEqual(prefer, 5000)

        guard case .success(.exec(let options))? = CLIArguments.parse(["exec", "--range", "5000-5999", "--", "npm", "run", "dev"]) else {
            return XCTFail("`exec --range 5000-5999` was rejected")
        }
        XCTAssertEqual(options.range, 5000...5999)
        XCTAssertEqual(options.prefer, 5000)
    }

    func testAPreferredPortStillWinsAndStillHasToBeInTheRange() {
        guard case .success(.freePort(let prefer, _, _))? = CLIArguments.parse(["free-port", "--range", "5000-5999", "--prefer", "5500"]) else {
            return XCTFail("a preferred port inside the range is fine")
        }
        XCTAssertEqual(prefer, 5500)
        guard case .failure? = CLIArguments.parse(["free-port", "--range", "5000-5999", "--prefer", "9000"]) else {
            return XCTFail("a preferred port outside the range is the person's mistake, and is still reported")
        }
    }

    /// The lease reason is shown by `reservations` and `whois`, and quoted
    /// back to other agents in the refusal they get.
    func testALeaseReasonDoesNotCarryASecret() {
        let lease = Reservation(port: 45019, owner: "Claude Code", reason: "exec: node --token=sk-live-9 server.js")
        XCTAssertNotNil(lease.reason)
        XCTAssertFalse(lease.reason?.contains("sk-live-9") ?? true)
    }

    func testAKillLinkActsOnTheOnlyPortItNames() {
        XCTAssertEqual(URLCommand.parse(URL(string: "portnanny://kill/3000")!), .kill(port: 3000, force: false))
        XCTAssertNil(URLCommand.parse(URL(string: "portnanny://kill/9999/3000")!), "it reads as :9999 and used to kill :3000")
        XCTAssertNil(URLCommand.parse(URL(string: "portnanny://kill/abc/3000")!))
    }

    // MARK: - Who is still running

    /// An npm or pip install runs the agent through an interpreter, so its
    /// processes are called "node" or "python3". Nothing matched them, the
    /// live session read as ended, and `kill --orphaned` (advertised as safe
    /// for anyone) would then reap that agent's running server.
    func testAnAgentInstalledThroughNpmOrPipIsStillRecognised() {
        XCTAssertEqual(AgentAttribution.match(command: "/usr/local/bin/gemini --yolo", executableName: "gemini")?.name, "Gemini CLI")
        XCTAssertEqual(AgentAttribution.match(command: "node /usr/local/bin/gemini --yolo", executableName: "node")?.name, "Gemini CLI")
        XCTAssertEqual(AgentAttribution.match(command: "python3 /Users/me/.local/bin/aider", executableName: "python3")?.name, "Aider")
        XCTAssertEqual(AgentAttribution.match(command: "node /opt/homebrew/bin/copilot", executableName: "node")?.name, "Copilot CLI")
    }

    func testAProjectNamedAfterAnAgentIsNotThatAgent() {
        XCTAssertNil(AgentAttribution.match(command: "node /Users/me/projects/gemini/server.js", executableName: "node"))
        XCTAssertNil(AgentAttribution.match(command: "node server.js", executableName: "node"))
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

    // MARK: - A port nobody here can see is not therefore free

    /// A listening socket on `address`, closed when the returned handle dies.
    private func listen(on address: String, family: Int32) throws -> (fd: Int32, port: Int) {
        let fd = socket(family, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, address, &sin.sin_addr)
            _ = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        } else {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            inet_pton(AF_INET6, address, &sin6.sin6_addr)
            var v6only: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
            _ = withUnsafePointer(to: &sin6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        return (fd, try XCTUnwrap(localPort(of: fd)))
    }

    private func localPort(of fd: Int32) -> Int? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard ok == 0 else { return nil }
        let isIPv6 = storage.ss_family == sa_family_t(AF_INET6)
        return withUnsafePointer(to: storage) { pointer -> Int in
            if isIPv6 {
                return Int(pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) })
            }
            return Int(pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) })
        }
    }

    func testAListenerOnIPv4LoopbackAloneIsSeenAsHeld() throws {
        let (fd, port) = try listen(on: "127.0.0.1", family: AF_INET)
        defer { close(fd) }
        XCTAssertTrue(PortProbe.isHeld(port))
        XCTAssertFalse(PortProbe.canBind(port))
    }

    /// The old probe tried only the IPv4 wildcard and never saw this.
    func testAListenerOnIPv6LoopbackAloneIsSeenAsHeld() throws {
        let (fd, port) = try listen(on: "::1", family: AF_INET6)
        defer { close(fd) }
        XCTAssertTrue(PortProbe.isHeld(port), "a server bound to ::1 only still owns the port")
        XCTAssertFalse(PortProbe.canBind(port))
    }

    func testAPortThatWasJustReleasedIsFreeAgain() throws {
        let (fd, port) = try listen(on: "127.0.0.1", family: AF_INET)
        close(fd)
        XCTAssertFalse(PortProbe.isHeld(port))
        XCTAssertTrue(PortProbe.canBind(port))
    }

    /// Without SO_REUSEADDR a closed connection's TIME_WAIT failed the bind,
    /// so `free-port` skipped ports any real server could have taken.
    func testAPortInTimeWaitIsNotMistakenForAHeldOne() throws {
        let (listener, port) = try listen(on: "127.0.0.1", family: AF_INET)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &sin.sin_addr)
        _ = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let accepted = accept(listener, nil, nil)
        close(accepted)
        close(listener)
        usleep(200_000)
        close(client)
        XCTAssertFalse(PortProbe.isHeld(port), "TIME_WAIT is not a listener")
        XCTAssertTrue(PortProbe.canBind(port))
    }

    func testImpossiblePortsAreNeverHeld() {
        XCTAssertFalse(PortProbe.isHeld(0))
        XCTAssertFalse(PortProbe.isHeld(-1))
        XCTAssertFalse(PortProbe.isHeld(70_000))
        XCTAssertFalse(PortProbe.canBind(70_000))
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
