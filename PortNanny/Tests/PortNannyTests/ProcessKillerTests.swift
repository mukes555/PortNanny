import XCTest
import Foundation
@testable import PortNannyCore
@testable import PortNanny

final class ProcessKillerTests: XCTestCase {

    let killer = ProcessKiller()

    func testNamesMatchHandlesTruncationAndEmpties() {
        // lsof truncation tolerance (both directions)
        XCTAssertTrue(ProcessKiller.namesMatch(expected: "com.docker.backend", actual: "com.docke"))
        XCTAssertTrue(ProcessKiller.namesMatch(expected: "node", actual: "node"))
        XCTAssertTrue(ProcessKiller.namesMatch(expected: "Node", actual: "node")) // case-insensitive
        XCTAssertFalse(ProcessKiller.namesMatch(expected: "node", actual: "python"))
        // Empty means "can't verify" and must NOT match (was: hasPrefix("") always true)
        XCTAssertFalse(ProcessKiller.namesMatch(expected: "", actual: "anything"))
        XCTAssertFalse(ProcessKiller.namesMatch(expected: "anything", actual: ""))
        XCTAssertFalse(ProcessKiller.namesMatch(expected: "", actual: ""))
    }

    func testRejectsNonPositivePids() {
        // kill(0)/kill(-1) would signal whole process groups.
        XCTAssertThrowsError(try killer.killProcess(pid: 0))
        XCTAssertThrowsError(try killer.killProcess(pid: -1))
        // Past a 32-bit pid: narrowing it to pid_t trapped and took the whole
        // process down rather than reporting a bad argument.
        XCTAssertThrowsError(try killer.killProcess(pid: 9_999_999_999))
        XCTAssertFalse(killer.isProcessRunning(9_999_999_999))
    }

    /// A kill that signalled nothing is not a kill: the process had exited
    /// while a dialog stood open, and History recorded it as killed anyway.
    func testAProcessThatHadAlreadyExitedIsNotReportedAsKilled() throws {
        let process = Process()
        process.launchPath = "/bin/sleep"
        process.arguments = ["0.05"]
        try process.run()
        let pid = Int(process.processIdentifier)
        process.waitUntilExit()

        let outcome = try killer.killProcess(pid: pid, expectedName: "sleep")
        XCTAssertFalse(outcome.signalled)
        XCTAssertTrue(outcome.childrenNotKilled.isEmpty)
    }

    func testAKillThatSignalledReportsThat() throws {
        let process = Process()
        process.launchPath = "/bin/sleep"
        process.arguments = ["100"]
        try process.run()
        addTeardownBlock { process.terminate() }

        let outcome = try killer.killProcess(pid: Int(process.processIdentifier), expectedName: "sleep")
        XCTAssertTrue(outcome.signalled)
    }

    func testIdentityMismatchRefusesToKill() throws {
        let process = Process()
        process.launchPath = "/bin/sleep"
        process.arguments = ["100"]
        try process.run()
        let pid = Int(process.processIdentifier)

        addTeardownBlock {
            process.terminate()
        }

        XCTAssertThrowsError(
            try killer.killProcess(pid: pid, expectedName: "definitely-not-sleep")
        )
        XCTAssertTrue(killer.isProcessRunning(pid), "Process must survive an identity mismatch")
    }

    func testMatchingIdentityKills() throws {
        let process = Process()
        process.launchPath = "/bin/sleep"
        process.arguments = ["100"]
        try process.run()
        let pid = Int(process.processIdentifier)

        addTeardownBlock {
            process.terminate()
        }

        try killer.killProcess(pid: pid, expectedName: "sleep")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(killer.isProcessRunning(pid))
    }

    func testKillProcessTerminatesProcess() throws {
        // 1. Spawn a process (sleep)
        let process = Process()
        process.launchPath = "/bin/sleep"
        process.arguments = ["100"]
        try process.run()
        
        let pid = Int(process.processIdentifier)
        
        // 2. Ensure it's running
        XCTAssertTrue(killer.isProcessRunning(pid), "Process should be running initially")
        
        // 3. Kill it
        try killer.killProcess(pid: pid)
        
        // 4. Wait a moment for OS to clean up
        Thread.sleep(forTimeInterval: 0.1)
        
        // 5. Verify it's gone
        XCTAssertFalse(killer.isProcessRunning(pid), "Process should be terminated")
        
        // Cleanup just in case
        process.terminate()
    }
    
    func testKillTreeTerminatesChild() throws {
        // 1. Spawn a parent process that spawns a child
        // We use a shell script to create a hierarchy: sh -> sleep
        // 'sleep 100 & wait' keeps sh alive waiting for sleep.
        
        let treeProcess = Process()
        treeProcess.launchPath = "/bin/sh"
        treeProcess.arguments = ["-c", "sleep 100 & wait"]
        try treeProcess.run()
        
        let treePid = Int(treeProcess.processIdentifier)
        Thread.sleep(forTimeInterval: 0.5)
        
        let scanner = PortScanner()
        let treeChildren = scanner.getChildProcesses(pid: treePid)
        XCTAssertFalse(treeChildren.isEmpty, "Should have child processes")
        
        let childPid = treeChildren.first?.pid ?? -1
        
        // 2. Kill the parent tree
        try killer.killProcess(pid: treePid, killTree: true)
        
        Thread.sleep(forTimeInterval: 0.5)
        
        // 3. Verify parent is dead
        XCTAssertFalse(killer.isProcessRunning(treePid), "Parent should be dead")
        
        // 4. Verify child is dead
        if childPid > 0 {
            XCTAssertFalse(killer.isProcessRunning(childPid), "Child process (PID: \(childPid)) should also be dead")
        }
        
        // Cleanup
        treeProcess.terminate()
    }
}
