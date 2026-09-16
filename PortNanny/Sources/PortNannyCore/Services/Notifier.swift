import Foundation
import UserNotifications

/// System notifications (used by the port watchlist).
///
/// UNUserNotificationCenter crashes when there is no app bundle (e.g. running
/// the bare SwiftPM binary during development), so every call is guarded.
public enum Notifier {

    public static var isAvailable: Bool {
        // A bundle identifier alone is not enough: the xctest runner has one
        // yet UNUserNotificationCenter still throws ("bundleProxyForCurrentProcess
        // is nil"). Only a real .app bundle can use notifications.
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// nil when notifications are unavailable in this build (no .app bundle).
    public static func authorizationStatus(completion: @escaping (UNAuthorizationStatus?) -> Void) {
        guard isAvailable else {
            completion(nil)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    public static let refusalCategory = "PORTNANNY_REFUSAL"
    public static let stopAnywayAction = "PORTNANNY_STOP_ANYWAY"
    public static let showAction = "PORTNANNY_SHOW"

    /// Registers the refusal category so its buttons appear; call once at launch.
    public static func registerCategories() {
        guard isAvailable else { return }
        // .foreground: the confirmation this action opens belongs in front of
        // whatever the person is using, not behind it.
        let stop = UNNotificationAction(identifier: stopAnywayAction, title: "Stop it anyway", options: [.destructive, .foreground])
        let show = UNNotificationAction(identifier: showAction, title: "Show in PortNanny", options: [.foreground])
        let category = UNNotificationCategory(identifier: refusalCategory, actions: [stop, show], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// "Claude Code was refused :3000" with the buttons a person needs to
    /// settle it; `port` rides along for the action handler.
    public static func sendRefusal(_ payload: RefusalSignal.Payload, sound: Bool = true) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        let caller = AgentSignatures.cleanedLabel(payload.caller.components(separatedBy: " via ").first ?? payload.caller)
        content.title = "\(caller) was refused :\(payload.port)"
        let owner = payload.owner.map { " owned by \(AgentSignatures.cleanedLabel($0))" } ?? " that nobody claims"
        content.body = "It asked to stop \(AgentSignatures.cleanedLabel(payload.processName))\(owner). Stop it yourself, or leave it running."
        content.sound = sound ? .default : nil
        content.categoryIdentifier = refusalCategory
        content.userInfo = payload.userInfo
        post(UNNotificationRequest(identifier: "refusal-\(payload.port)", content: content, trigger: nil))
    }

    /// `id` identifies what the banner is about (a port, a summary), so a
    /// later one about the same thing replaces it in Notification Center.
    /// Every banner used to carry a fresh UUID, so a port that changed forty
    /// times left forty banners waiting for the person to come back.
    public static func send(title: String, body: String, sound: Bool = true, id: String = UUID().uuidString) {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil

        post(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Posts a notification, asking for permission first if that has never
    /// happened. Watch, Guard and the Settings switch ask when the person
    /// opts in, but a refusal banner and a watchlist carried over from
    /// PortKilla reach here with the question never put, and macOS drops
    /// everything an unauthorized app sends: those banners never appeared.
    private static func post(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    center.add(request)
                }
            case .denied:
                return
            default:
                center.add(request)
            }
        }
    }
}
