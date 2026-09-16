import XCTest
@testable import PortNannyCore

/// What reaches Notification Center. A watched port that an agent restarted
/// every few seconds produced a banner per change, each with a sound, and
/// with the screen locked macOS delivered the whole queue at unlock.
final class NotificationGateTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testAFlappingPortIsAnnouncedOncePerMinute() {
        let gate = NotificationGate()
        XCTAssertEqual(gate.verdict(port: 3000, kind: .portTaken, now: start), .post(sound: true))

        // The server goes up and down every two seconds for a minute.
        for second in stride(from: 2, through: 58, by: 2) {
            let verdict = gate.verdict(port: 3000, kind: .portTaken, now: start.addingTimeInterval(Double(second)))
            XCTAssertEqual(verdict, .hold, "second \(second) should be counted, not announced")
        }
        XCTAssertEqual(gate.verdict(port: 3000, kind: .portTaken, now: start.addingTimeInterval(61)), .post(sound: true),
                       "a minute later it may speak again")
    }

    func testOnlyTheFirstOfABurstMakesASound() {
        let gate = NotificationGate()
        XCTAssertEqual(gate.verdict(port: 3000, kind: .portTaken, now: start), .post(sound: true))
        XCTAssertEqual(gate.verdict(port: 5173, kind: .portTaken, now: start.addingTimeInterval(1)), .post(sound: false))
        XCTAssertEqual(gate.verdict(port: 8080, kind: .portTaken, now: start.addingTimeInterval(2)), .post(sound: false))
        XCTAssertEqual(gate.verdict(port: 9000, kind: .portTaken, now: start.addingTimeInterval(3)), .hold,
                       "a fourth in half a minute is a summary, not a fourth banner")
    }

    func testFreedAndTakenAreDifferentNews() {
        let gate = NotificationGate()
        XCTAssertEqual(gate.verdict(port: 3000, kind: .portTaken, now: start), .post(sound: true))
        XCTAssertEqual(gate.verdict(port: 3000, kind: .portFreed, now: start.addingTimeInterval(1)), .post(sound: false),
                       "the port freeing up is not the same event as it being taken")
    }

    func testNothingIsPostedWhileTheScreenIsAway() {
        let gate = NotificationGate()
        gate.isAway = true
        for minute in 0..<30 {
            XCTAssertEqual(gate.verdict(port: 3000, kind: .portTaken, now: start.addingTimeInterval(Double(minute) * 60)), .hold)
        }
        XCTAssertEqual(gate.verdict(port: 5173, kind: .portFreed, now: start), .hold)

        let summary = gate.takeSummary()
        XCTAssertEqual(summary?.count, 31)
        XCTAssertEqual(summary?.ports, [3000, 5173], "in the order they first happened")
        XCTAssertNil(gate.takeSummary(), "a summary is said once")
    }

    func testTheSummaryNamesAFewPortsAndCountsTheRest() {
        XCTAssertEqual(NotificationGate.summaryBody(count: 1, ports: [3000]),
                       "1 change on :3000. PortNanny has the details.")
        XCTAssertEqual(NotificationGate.summaryBody(count: 12, ports: [3000, 5173]),
                       "12 changes on :3000, :5173. PortNanny has the details.")
        XCTAssertEqual(NotificationGate.summaryBody(count: 40, ports: [3000, 5173, 8080, 9000]),
                       "40 changes on :3000, :5173 and 2 more. PortNanny has the details.")
    }

    func testComingBackDoesNotReplayTheQueue() {
        let gate = NotificationGate()
        gate.isAway = true
        for second in 0..<100 {
            _ = gate.verdict(port: 3000, kind: .portTaken, now: start.addingTimeInterval(Double(second)))
        }
        gate.isAway = false
        XCTAssertEqual(gate.takeSummary()?.count, 100, "counted")
        XCTAssertEqual(gate.verdict(port: 3000, kind: .portTaken, now: start.addingTimeInterval(200)), .post(sound: true),
                       "and the next real change is announced normally")
    }
}
