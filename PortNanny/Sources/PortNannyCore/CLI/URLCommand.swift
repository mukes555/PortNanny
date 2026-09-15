import Foundation

/// The `portnanny://` scheme, parsed apart from the app delegate so it can be
/// tested: `portnanny://kill/3000`, `portnanny://kill/3000?force=1`,
/// `portnanny://show`.
public enum URLCommand: Equatable {
    case kill(port: Int, force: Bool)
    case show

    public static func parse(_ url: URL) -> URLCommand? {
        switch url.host {
        case "kill":
            // Exactly one segment: `portnanny://kill/9999/3000` reads to a
            // person as :9999 but used to act on the last segment.
            let segments = url.pathComponents.filter { $0 != "/" }
            guard segments.count == 1, let port = Int(segments[0]), (1...65535).contains(port) else { return nil }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let force = components?.queryItems?.contains { $0.name == "force" && $0.value == "1" } ?? false
            return .kill(port: port, force: force)
        case "show":
            return .show
        default:
            return nil
        }
    }
}
