import XCTest
@testable import PortNannyCore

/// CommandRunner against children that misbehave: every tool PortNanny runs
/// (docker, pm2, launchctl, lsof, ps) is a child it does not control.
final class CommandRunnerHostileTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pn-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes an executable shell script and returns its path.
    private func tool(_ name: String, _ body: String) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    func testAHungChildTimesOutInsteadOfFreezingTheCaller() throws {
        let hung = try tool("hung", "sleep 30")
        let start = Date()
        XCTAssertThrowsError(try CommandRunner.run(hung, [], timeout: 0.5)) { error in
            guard case CommandRunner.CommandError.timedOut = error else { return XCTFail("expected a timeout, got \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "a hung tool must never hold up a refresh")
    }

    func testAGrandchildHoldingThePipeDoesNotHangTheCaller() throws {
        // The child exits at once; the grandchild it leaves keeps stdout open.
        // The caller must not wait on it. The grandchild itself is left alone
        // on purpose: pm2 starts its daemon this way, and killing the process
        // group would take down a daemon the person relies on.
        let marker = scratch.appendingPathComponent("grandchild.pid").path
        let leaky = try tool("leaky", "sh -c 'echo $$ > \(marker); sleep 30' &\necho done")
        let start = Date()
        XCTAssertThrowsError(try CommandRunner.run(leaky, [], timeout: 0.5)) { error in
            XCTAssertEqual(error as? CommandRunner.CommandError, .timedOut("leaky"), "a held pipe counts as a hang")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "an orphaned pipe must never block a refresh")

        // Only the grandchild this test started is cleaned up.
        let pidText = (try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let grandchild = Int32(pidText) { kill(grandchild, SIGKILL) }
    }

    func testOutputThatIsNotUTF8IsATypedErrorNotACrash() throws {
        let binary = try tool("binary", "printf '\\377\\376\\375'")
        XCTAssertThrowsError(try CommandRunner.run(binary, [])) { error in
            guard case CommandRunner.CommandError.notUTF8 = error else { return XCTFail("expected notUTF8, got \(error)") }
        }
    }

    func testAMissingExecutableSaysItCouldNotStart() {
        XCTAssertThrowsError(try CommandRunner.run(scratch.appendingPathComponent("absent").path, [])) { error in
            guard case CommandRunner.CommandError.couldNotStart(let command, _) = error else {
                return XCTFail("expected couldNotStart, got \(error)")
            }
            XCTAssertEqual(command, "absent")
        }
    }

    func testAFailingToolKeepsItsOwnReasonInTheError() throws {
        let docker = try tool("docker", "echo 'Error response from daemon: No such container: web' >&2\nexit 1")
        XCTAssertThrowsError(try CommandRunner.run(docker, ["stop", "web"])) { error in
            XCTAssertEqual(error as? CommandRunner.CommandError,
                           .failed(command: "docker", exitCode: 1, detail: "Error response from daemon: No such container: web"))
            XCTAssertEqual(error.localizedDescription, "docker failed (exit 1): Error response from daemon: No such container: web",
                           "a person can tell a missing container from a stopped daemon")
        }
    }

    func testAToolThatFloodsStderrCannotBlockOnAFullPipe() throws {
        // 8 MB on stderr and then an exit: with stderr unread, the tool would
        // block forever on a full pipe.
        let noisy = try tool("noisy", "head -c 8388608 /dev/zero | tr '\\0' 'e' >&2\necho ok")
        let start = Date()
        XCTAssertEqual(try CommandRunner.run(noisy, [], timeout: 15).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testAFloodOfOutputIsRefusedWithoutReadingItAllIntoMemory() throws {
        // 64 MB on stdout, twice the cap: it used to come back whole.
        let flood = try tool("flood", "head -c 67108864 /dev/zero | tr '\\0' 'a'")
        let start = Date()
        XCTAssertThrowsError(try CommandRunner.run(flood, [], timeout: 20)) { error in
            XCTAssertEqual(error as? CommandRunner.CommandError, .outputTooLarge("flood"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 25, "past the cap it keeps draining, so the tool still exits")
    }

    func testOutputJustUnderTheCapIsStillReturnedWhole() throws {
        let big = try tool("big", "head -c 1048576 /dev/zero | tr '\\0' 'b'")
        XCTAssertEqual(try CommandRunner.run(big, [], timeout: 15).utf8.count, 1_048_576)
    }
}
