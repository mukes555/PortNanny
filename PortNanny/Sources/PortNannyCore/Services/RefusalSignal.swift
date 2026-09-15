import Foundation

/// The CLI tells the running app about a refusal the moment it happens, so
/// the person can resolve it from a notification instead of finding out
/// later. Distributed notifications need no bundle, which the CLI has none of.
public enum RefusalSignal {
    public static let name = Notification.Name("com.mukes555.PortNanny.refused")

    public struct Payload: Equatable {
        public let port: Int
        public let processName: String
        public let owner: String?
        public let caller: String

        public init(port: Int, processName: String, owner: String?, caller: String) {
            self.port = port
            self.processName = processName
            self.owner = owner
            self.caller = caller
        }

        public var userInfo: [String: Any] {
            var info: [String: Any] = ["port": port, "processName": processName, "caller": caller]
            if let owner { info["owner"] = owner }
            return info
        }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo, let port = info["port"] as? Int, let processName = info["processName"] as? String,
                  let caller = info["caller"] as? String else { return nil }
            self.init(port: port, processName: processName, owner: info["owner"] as? String, caller: caller)
        }
    }

    public static func post(_ payload: Payload) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: payload.userInfo, deliverImmediately: true)
    }
}

/// "Show the port list", from one PortNanny process to the one already
/// running. A second copy (opened from a mounted DMG next to the one in
/// Applications) would otherwise sit in the menu bar beside the first, kill
/// twice on every guard, and notify twice for every watch.
public enum ShowSignal {
    public static let name = Notification.Name("com.mukes555.PortNanny.show")

    public static func post() {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
