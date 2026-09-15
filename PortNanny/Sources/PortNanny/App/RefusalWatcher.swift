import AppKit
import PortNannyCore
import UserNotifications

/// Turns a refusal the CLI just issued into a notification the person can
/// act on: stop the server themselves, or open PortNanny and look.
final class RefusalWatcher: NSObject, UNUserNotificationCenterDelegate {
    private let portManager: PortManager
    private let reveal: () -> Void

    init(portManager: PortManager, reveal: @escaping () -> Void) {
        self.portManager = portManager
        self.reveal = reveal
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refused(_:)), name: RefusalSignal.name, object: nil)
        guard Notifier.isAvailable else { return }
        Notifier.registerCategories()
        UNUserNotificationCenter.current().delegate = self
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Any local process can post the signal; only a refusal the CLI wrote
    /// to the shared store moments ago is believed, and its own words are
    /// what the notification shows.
    @objc private func refused(_ notification: Notification) {
        guard let posted = RefusalSignal.Payload(userInfo: notification.userInfo) else { return }
        portManager.history.reload()
        guard let recorded = Self.recordedRefusal(matching: posted, in: portManager.history.refusals) else {
            Log.kill.info("ignored a refusal signal with no matching record for :\(posted.port)")
            return
        }
        guard portManager.notifies(.refusal) else { return }
        Notifier.sendRefusal(recorded, sound: portManager.notificationSound)
    }

    static func recordedRefusal(matching posted: RefusalSignal.Payload, in refusals: [PortHistoryItem], now: Date = Date()) -> RefusalSignal.Payload? {
        let match = refusals.first { item in
            item.action == .refused && item.port == posted.port && item.processName == posted.processName
                && now.timeIntervalSince(item.timestamp) < 60
        }
        guard let match else { return nil }
        return RefusalSignal.Payload(port: match.port, processName: AgentSignatures.cleanedLabel(match.processName),
                                     owner: match.owner.map(AgentSignatures.cleanedLabel), caller: AgentSignatures.cleanedLabel(match.killedBy ?? "an agent"))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        switch response.actionIdentifier {
        case Notifier.stopAnywayAction:
            guard let payload = RefusalSignal.Payload(userInfo: response.notification.request.content.userInfo) else { return }
            // A fresh scan finds the current occupant; the usual confirmation
            // (owner, clients, lease, supervisor) applies before anything dies.
            let manager = portManager
            manager.killPortNumber(payload.port, respectProtected: true, initiator: .user) { target in
                KillFlow(portManager: manager).requestKill(target, force: false, killTree: false)
                return false
            }
        case UNNotificationDismissActionIdentifier:
            return
        default:
            // Any other click is on the banner itself. Watch and guard banners
            // carry no payload, and used to do nothing at all when clicked.
            reveal()
        }
    }
}
