import Foundation

/// How many banners actually reach Notification Center, and when.
///
/// A watched port that an agent restarts every few seconds produced a banner
/// per change, each with a sound, each a new notification rather than a
/// replacement. With the screen locked, macOS queued every one of them and
/// delivered the lot at unlock: dozens of banners and dozens of sounds, for
/// one server flapping.
///
/// So: one banner per port per minute, a handful per burst, one sound per
/// burst, nothing at all while the person is away, and a single summary when
/// they come back. The app's own state is always the full truth; a banner is
/// an interruption and is rationed like one.
public final class NotificationGate {

    public enum Verdict: Equatable {
        /// Post it. `sound` is false for the rest of a burst, however loud
        /// the person's preference: one interruption per burst is enough.
        case post(sound: Bool)
        /// Counted, not posted. A summary follows when the burst ends or the
        /// person comes back.
        case hold
    }

    /// One banner per port and kind per minute.
    public static let perPortInterval: TimeInterval = 60
    /// Banners allowed in a window before the rest become a summary.
    public static let burstLimit = 3
    public static let burstWindow: TimeInterval = 30

    /// True while the screen is locked or the display is asleep: nothing is
    /// posted, because macOS would hold it all for the moment of unlock.
    public var isAway = false

    private var lastPosted: [String: Date] = [:]
    private var postedInBurst: [Date] = []
    private var held: [(port: Int, at: Date)] = []
    private let lock = NSLock()

    public init() {}

    public func verdict(port: Int, kind: PortManager.NotificationKind, now: Date = Date()) -> Verdict {
        lock.lock()
        defer { lock.unlock() }

        guard !isAway else {
            hold(port, now)
            return .hold
        }
        let key = "\(kind)-\(port)"
        if let last = lastPosted[key], now.timeIntervalSince(last) < Self.perPortInterval {
            hold(port, now)
            return .hold
        }
        postedInBurst = postedInBurst.filter { now.timeIntervalSince($0) < Self.burstWindow }
        guard postedInBurst.count < Self.burstLimit else {
            hold(port, now)
            return .hold
        }
        let isFirstOfBurst = postedInBurst.isEmpty
        postedInBurst.append(now)
        lastPosted[key] = now
        return .post(sound: isFirstOfBurst)
    }

    /// What was held since the last summary, and nothing afterwards. nil when
    /// there is nothing to say.
    public func takeSummary() -> (count: Int, ports: [Int])? {
        lock.lock()
        defer { lock.unlock() }
        guard !held.isEmpty else { return nil }
        let count = held.count
        // Ordered by first appearance: the port that started it reads first.
        var ports: [Int] = []
        for event in held where !ports.contains(event.port) { ports.append(event.port) }
        held = []
        return (count, ports)
    }

    /// "5 changes on :3000, :5173 and 1 more" for the one banner that stands
    /// in for all of them.
    public static func summaryBody(count: Int, ports: [Int]) -> String {
        let named = ports.prefix(2).map { ":\($0)" }.joined(separator: ", ")
        let rest = ports.count - min(ports.count, 2)
        let where_ = rest > 0 ? "\(named) and \(rest) more" : named
        return "\(count) change\(count == 1 ? "" : "s") on \(where_). PortNanny has the details."
    }

    private func hold(_ port: Int, _ now: Date) {
        // A flapping port can hold hundreds of events in an hour; the count
        // is what matters, not every one of them.
        if held.count < 500 { held.append((port, now)) }
    }
}
