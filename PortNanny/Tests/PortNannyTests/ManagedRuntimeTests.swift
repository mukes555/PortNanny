import XCTest
@testable import PortNannyCore

/// Phase B2: supervisors that would undo a plain kill, the verbs that stop
/// them, and refusals that reach the person.
final class ManagedRuntimeTests: XCTestCase {

    private func table(_ rows: [(Int, Int, String)]) -> ProcessTable {
        let lines = rows.map { "\($0.0) \($0.1) 1024 0.0 05:00 \($0.2)" }.joined(separator: "\n")
        return ProcessTable(psOutput: lines)
    }

    private let noLaunchd: (Int) -> String? = { _ in nil }
    private let noPM2: (Int) -> [String: String] = { _ in [:] }

    private func detect(_ pid: Int, in t: ProcessTable, type: PortInfo.PortType = .nodejs, container: String? = nil,
                        launchd: @escaping (Int) -> String? = { _ in nil }, pm2: @escaping (Int) -> [String: String] = { _ in [:] }) -> ManagedRuntime? {
        ManagedRuntime.detect(pid: pid, containerName: container, type: type, in: t, launchdLabel: launchd, pm2Facts: pm2)
    }

    // MARK: - Reloaders

    /// A tmux server keeps the argv of the command that opened the session,
    /// so `tmux new -s build tsc --watch` matched the watch-mode signature.
    /// `kill 3000` then planned a tree kill from tmux down: every pane in the
    /// session, the person's editor and any other server in it.
    func testTmuxIsWhereTheAncestorWalkStops() {
        let session = table([
            (100, 1, "tmux new -s build tsc --watch"),
            (200, 100, "/bin/zsh"),
            (300, 200, "node server.js"),
        ])
        XCTAssertNil(detect(300, in: session), "tmux supervises a session, not the server inside it")

        let nodemonInsideTmux = table([
            (100, 1, "tmux new -s build"),
            (200, 100, "/bin/zsh"),
            (250, 200, "node /usr/local/bin/nodemon server.js"),
            (300, 250, "node server.js"),
        ])
        XCTAssertEqual(detect(300, in: nodemonInsideTmux)?.name, "nodemon", "a real supervisor below tmux is still found")
    }

    /// End-to-end testing found `portnanny kill` on a Docker-published port
    /// answering "a container `docker ps` can name" and stopping nothing,
    /// because it scanned without asking for container names and so never
    /// had one. whois asked, and printed the very command kill would not run.
    func testAKillOnADockerPortAsksForTheContainerName() {
        let unnamed = PortInfo(port: 45016, pid: 9, processName: "com.docker.backend",
                               command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", user: "me",
                               memoryUsage: "1MB", memorySizeKB: 1024, type: .docker)
        XCTAssertTrue(CLIKill.needsContainerNames([unnamed]), "a nameless container is exactly when the name is worth fetching")

        let named = PortInfo(port: 45016, pid: 9, processName: "com.docker.backend",
                             command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", user: "me",
                             memoryUsage: "1MB", memorySizeKB: 1024, type: .docker, containerName: "web")
        XCTAssertFalse(CLIKill.needsContainerNames([named]), "already named, so no second scan")

        let node = PortInfo(port: 3000, pid: 10, processName: "node", command: "node server.js", user: "me",
                            memoryUsage: "1MB", memorySizeKB: 1024, type: .nodejs)
        XCTAssertFalse(CLIKill.needsContainerNames([node]), "no docker in sight, no docker ps")
        XCTAssertFalse(CLIKill.needsContainerNames([]), "nothing to kill, nothing to ask")
    }

    /// The name is what turns a refusal into a runnable stop command.
    func testTheContainerNameIsWhatMakesADockerStopPossible() {
        let named = ManagedRuntime.detect(pid: 9, containerName: "web", type: .docker, in: .empty)
        XCTAssertEqual(named?.stopCommand(force: false), "docker stop -- web")
        XCTAssertEqual(named?.stopCommand(force: true), "docker kill -- web")

        let nameless = ManagedRuntime.detect(pid: 9, containerName: nil, type: .docker, in: .empty)
        XCTAssertEqual(nameless?.kind, .docker, "still recognised as Docker")
        XCTAssertNil(nameless?.stopCommand(force: false), "but nothing to run, which is why kill must ask for the name")
    }

    func testNodemonParentIsAReloader() throws {
        let t = table([(100, 1, "/bin/zsh"), (700, 100, "node /app/node_modules/.bin/nodemon server.js"), (812, 700, "node /app/server.js")])
        let managed = try XCTUnwrap(detect(812, in: t))
        XCTAssertEqual(managed.kind, .reloader)
        XCTAssertEqual(managed.name, "nodemon")
        XCTAssertEqual(managed.supervisorPid, 700)
        XCTAssertEqual(managed.supervisorName, "node")
        XCTAssertNil(managed.stopCommand)
        XCTAssertEqual(managed.label, "nodemon (PID 700)")
        XCTAssertEqual(managed.short, "nodemon")
    }

    func testAShellBetweenReloaderAndChildIsSkipped() {
        let t = table([(700, 1, "node nodemon server.js"), (701, 700, "sh -c node server.js"), (812, 701, "node server.js")])
        XCTAssertEqual(detect(812, in: t)?.supervisorPid, 700)
        let plain = table([(100, 1, "/bin/zsh"), (812, 100, "node server.js")])
        XCTAssertNil(detect(812, in: plain), "a plain shell parent supervises nothing")
    }

    func testOtherReloadersAreNamed() {
        let cases: [(String, String)] = [
            ("node /p/node_modules/next/dist/bin/next dev", "next dev"),
            ("node --watch server.js", "watch mode"),
            ("/venv/bin/python /venv/bin/uvicorn app:app --reload", "uvicorn --reload"),
            ("/venv/bin/gunicorn app:app -w 4", "gunicorn"),
            ("cargo watch -x run", "cargo watch"),
        ]
        for (parent, name) in cases {
            let t = table([(700, 1, parent), (812, 700, "worker")])
            XCTAssertEqual(detect(812, in: t)?.name, name, parent)
        }
    }

    func testAParentRunningTheSameCommandIsAReloader() {
        let t = table([(700, 1, "python manage.py runserver"), (812, 700, "python manage.py runserver")])
        let managed = detect(812, in: t)
        XCTAssertEqual(managed?.kind, .reloader)
        XCTAssertEqual(managed?.name, "python reloader")
        XCTAssertEqual(managed?.supervisorPid, 700)
    }

    // MARK: - pm2, launchd, Docker

    func testPM2OutranksAReloaderAndNamesTheApp() {
        let t = table([(50, 1, "PM2 v5.3.0: God Daemon (/Users/me/.pm2)"), (700, 50, "node nodemon server.js"), (812, 700, "node server.js")])
        let named = detect(812, in: t, pm2: { _ in ["name": "api", "pm_id": "3"] })
        XCTAssertEqual(named?.kind, .pm2)
        XCTAssertEqual(named?.name, "api")
        XCTAssertEqual(named?.stopCommand, "pm2 stop api")
        XCTAssertEqual(named?.stopArguments, ["pm2", "stop", "api"])
        XCTAssertEqual(detect(812, in: t, pm2: { _ in ["pm_id": "3"] })?.stopCommand, "pm2 stop 3")
        let unknown = detect(812, in: t)
        XCTAssertEqual(unknown?.kind, .pm2)
        XCTAssertNil(unknown?.stopCommand)
    }

    func testLaunchdOutranksAReloaderButOnlyForServices() {
        let t = table([(700, 1, "node nodemon server.js"), (812, 700, "node server.js")])
        let brew = detect(812, in: t, launchd: { $0 == 700 ? "homebrew.mxcl.redis" : nil })
        XCTAssertEqual(brew?.kind, .launchd)
        XCTAssertEqual(brew?.supervisorPid, 700)
        XCTAssertEqual(brew?.stopCommand, "brew services stop redis")
        let agent = detect(812, in: t, launchd: { _ in "com.me.agent" })
        XCTAssertEqual(agent?.stopArguments, ["launchctl", "bootout", "gui/\(getuid())/com.me.agent"])
        XCTAssertEqual(detect(812, in: t, launchd: { _ in "application.com.google.Chrome.1" })?.kind, .reloader, "an app LaunchServices opened is not a service")
        let plain = table([(812, 1, "/opt/homebrew/bin/postgres")])
        XCTAssertNil(detect(812, in: plain, launchd: { _ in "com.apple.controlcenter" }), "Apple's agents are never offered to launchctl")
        XCTAssertEqual(detect(812, in: plain, launchd: { _ in "homebrew.mxcl.postgresql@15" })?.supervisorPid, 812, "a job that listens itself")
        XCTAssertNil(detect(812, in: plain), "a reparented orphan under launchd is not a job")
    }

    func testDockerContainerAndDockerDesktop() {
        let t = table([(812, 1, "com.docker.backend")])
        let container = detect(812, in: t, type: .docker, container: "web-1")
        XCTAssertEqual(container?.kind, .docker)
        XCTAssertEqual(container?.stopArguments, ["docker", "stop", "--", "web-1"])
        XCTAssertEqual(container?.short, "container")
        let desktop = detect(812, in: t, type: .docker)
        XCTAssertEqual(desktop?.name, "Docker Desktop")
        XCTAssertNil(desktop?.stopCommand)
    }

    func testQuotingAndLaunchctlParsing() {
        XCTAssertEqual(ManagedRuntime.shellQuoted("api"), "api")
        XCTAssertEqual(ManagedRuntime.shellQuoted("my app"), "'my app'")
        XCTAssertEqual(ManagedRuntime.shellQuoted("a'b"), "'a'\\''b'")
        XCTAssertEqual(LaunchdJobs.parse("PID\tStatus\tLabel\n123\t0\tcom.x\n-\t0\tcom.y\n"), [123: "com.x"])
    }

    // MARK: - Kill plans

    private func port(_ pid: Int, managedBy: ManagedRuntime?) -> PortInfo {
        PortInfo(port: 3000, pid: pid, processName: "node", command: "node server.js", user: "me", memoryUsage: "1MB",
                 memorySizeKB: 1, type: .nodejs, managedBy: managedBy)
    }

    func testReloaderPlanSignalsTheSupervisorTree() {
        let t = table([(700, 1, "node nodemon"), (812, 700, "node server.js")])
        let reloader = ManagedRuntime(kind: .reloader, name: "nodemon", supervisorPid: 700, supervisorName: "node")
        let plan = CLIKill.plan(for: port(812, managedBy: reloader), force: false, table: t)
        XCTAssertEqual(plan.signalPid, 700)
        XCTAssertTrue(plan.killTree)
        XCTAssertEqual(plan.substitution, "stop nodemon (PID 700) instead of node (PID 812) on :3000, because nodemon would restart it")
        let forced = CLIKill.plan(for: port(812, managedBy: reloader), force: true, table: t)
        XCTAssertEqual(forced.signalPid, 812)
        XCTAssertNil(forced.substitution)
    }

    func testPM2PlanRunsTheVerbOrExplains() {
        let pm2 = ManagedRuntime(kind: .pm2, name: "api", stop: ["pm2", "stop", "api"])
        let runnable = CLIKill.plan(for: port(812, managedBy: pm2), force: false, table: .empty) { _ in "/usr/local/bin/pm2" }
        XCTAssertEqual(runnable.command, ["/usr/local/bin/pm2", "stop", "api"])
        XCTAssertEqual(runnable.commandText, "pm2 stop api")
        XCTAssertNil(runnable.blocked)
        let missing = CLIKill.plan(for: port(812, managedBy: pm2), force: false, table: .empty) { _ in nil }
        XCTAssertTrue(missing.blocked?.contains("Run `pm2 stop api` (pm2 is not on PATH here)") == true, missing.blocked ?? "")
        XCTAssertNil(CLIKill.plan(for: port(812, managedBy: pm2), force: true, table: .empty).blocked, "--force kills the listener itself")
    }

    func testDockerPlanNeverKillsTheBackend() {
        let container = ManagedRuntime(kind: .docker, name: "web-1", stop: ["docker", "stop", "--", "web-1"])
        let forced = CLIKill.plan(for: port(812, managedBy: container), force: true, table: .empty) { _ in "/usr/local/bin/docker" }
        XCTAssertEqual(forced.command, ["/usr/local/bin/docker", "kill", "--", "web-1"])
        XCTAssertEqual(forced.commandText, "docker kill -- web-1")
        let desktop = CLIKill.plan(for: port(812, managedBy: ManagedRuntime(kind: .docker, name: "Docker Desktop")), force: true, table: .empty)
        XCTAssertTrue(desktop.blocked?.contains("docker ps") == true)
    }

    func testToolLocatorSearchesPathThenCommonDirectories() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portnanny-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("pm2")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertEqual(ToolLocator.resolve("pm2", path: dir.path, home: "/nonexistent"), tool.path)
        XCTAssertNil(ToolLocator.resolve("nope", path: dir.path, home: "/nonexistent"))
        XCTAssertEqual(ToolLocator.resolve(tool.path, path: "", home: "/nonexistent"), tool.path)
        XCTAssertNotNil(ToolLocator.resolve("ls", path: "", home: "/nonexistent"), "/bin is a common directory")
    }

    // MARK: - Refusals

    func testRefusalPayloadRoundTrips() {
        let payload = RefusalSignal.Payload(port: 3000, processName: "node", owner: "Cursor", caller: "Claude Code (session 1) via CLI")
        XCTAssertEqual(RefusalSignal.Payload(userInfo: payload.userInfo), payload)
        XCTAssertNil(RefusalSignal.Payload(userInfo: ["port": 3000]))
    }

    func testRefusalsAreStoredApartFromKills() throws {
        let suite = "com.mukes555.PortNanny.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = HistoryManager(defaults: defaults)
        store.addEntry(port: 3000, processName: "node", action: .killed, owner: nil, killedBy: "you")
        store.addRefusal(port: 3001, processName: "vite", owner: "Cursor", refused: "Claude Code (session 1) via CLI")
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.first?.action, .refused)
        XCTAssertEqual(store.events.first?.killedBy, "Claude Code (session 1) via CLI")

        let kills = try JSONDecoder().decode([PortHistoryItem].self, from: XCTUnwrap(defaults.data(forKey: DefaultsKey.history)))
        XCTAssertEqual(kills.map(\.action), [.killed], "the kill store never sees an action an older app cannot decode")
        XCTAssertEqual(HistoryManager(defaults: defaults).refusals.count, 1, "another process reads the same refusals")
        store.clearHistory()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertNil(defaults.data(forKey: DefaultsKey.refusals))
    }

    func testManagedRuntimeStaysWithinTheWrittenSchema() throws {
        let runtime = ManagedRuntime(kind: .launchd, name: "homebrew.mxcl.redis", supervisorPid: 1, supervisorName: "redis-server", stop: ["brew", "services", "stop", "redis"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime)) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: Set(OutputSchemas.managedRuntime.keys)), "\(object.keys)")
    }
}
