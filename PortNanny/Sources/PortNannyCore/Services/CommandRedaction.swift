import Foundation

/// Command lines are attacker-influenced *and* secret-bearing: dev servers
/// are routinely started with `--token=…`, `DATABASE_URL=postgres://u:p@…`,
/// or `Authorization: Bearer …` in their arguments. Anything PortNanny shows,
/// exports, or hands to an agent goes through here first.
public enum CommandRedaction {
    static let mask = "[redacted]"

    private static let sensitiveNames = "(?:token|secret|passw(?:or)?d|api[-_]?key|apikey|auth|credential|private[-_]?key|access[-_]?key)"

    /// The name of a key that carries a secret: a run of name characters
    /// whose first 64 characters contain one of the words above.
    ///
    /// The shape matters as much as the words. Written the obvious way, as
    /// `[\w.-]*token[\w.-]*`, the two runs and the word all match the same
    /// characters, so the engine tries every way of splitting a run between
    /// them: an 800-character argument took 2.6 seconds and a few kilobytes
    /// took minutes. That ran on every listener of every scan, so one process
    /// with a long argument froze the menu bar, the CLI and the guard with it.
    /// Here the lookahead does the searching, from the start of the run only,
    /// and the run itself is matched once with nothing to backtrack into.
    private static let sensitiveKey = "(?=[\\w.-]{0,64}" + sensitiveNames + ")[\\w.-]{1,256}"
    /// Where a name may begin: not in the middle of a longer one.
    private static let keyStart = "(?<![\\w.-])"

    /// A value runs to whitespace or a quote, so `--token='abc'` keeps its
    /// quotes around the mask.
    private static let value = "(['\"]?)([^\\s'\"]+)"

    private static let flagValue = try! NSRegularExpression(pattern: "(?i)(--?" + sensitiveKey + ")(=|\\s+)" + value)
    private static let envValue = try! NSRegularExpression(pattern: "(?i)\\b((?=[A-Z0-9_]{0,64}" + sensitiveNames + ")[A-Z0-9_]{1,256})(=)" + value)
    /// A JSON secret: `"token": "abc"`. The value runs to the closing
    /// quote so the mask keeps the quotes.
    private static let quotedValue = try! NSRegularExpression(pattern: "(?i)" + keyStart + "([\"\']?" + sensitiveKey + "[\"\']?\\s*:\\s*)([\"\'])([^\"\']+)([\"\'])")
    /// A header secret: `X-API-Key: abc`. "Bearer" is skipped so the token
    /// after it, not the word, is what gets masked.
    private static let headerValue = try! NSRegularExpression(pattern: "(?i)" + keyStart + "(" + sensitiveKey + ":\\s*)(?!bearer\\b)" + value)
    /// Bounded for the same reason: `[^@\s]+@` alone rescanned to the end of
    /// the line from every position, 1.5 seconds for 20 KB of `://a:`.
    private static let urlCredentials = "://[^/\\s:@]{1,128}:[^@\\s]{1,128}@"
    private static let urlPassword = try! NSRegularExpression(pattern: "(://[^/\\s:@]{1,128}:)([^@\\s]{1,128})(@)")
    private static let bearer = try! NSRegularExpression(pattern: "(?i)(bearer\\s+)" + value)

    /// Most command lines carry nothing sensitive; one scan decides that
    /// before the four replacements run on every listener, every refresh.
    private static let anySensitive = try! NSRegularExpression(pattern: "(?i)" + sensitiveNames + "|bearer\\s|" + urlCredentials)

    /// A control character or C1 escape can hide or spoof terminal output;
    /// process names, paths, and reasons pass through here before printing.
    /// Scalar by scalar, not character by character: "\r\n" is a single Swift
    /// Character made of two scalars, and skipping those let a process name
    /// carrying a carriage return write its own row into `portnanny list`.
    public static func printable(_ text: String) -> String {
        var safe = String.UnicodeScalarView()
        for scalar in String(text.prefix(4096)).unicodeScalars {
            let isControl = scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
            safe.append(isControl && scalar != "\t" ? "\u{FFFD}" : scalar)
        }
        return String(safe)
    }

    public static func redact(_ command: String) -> String {
        guard anySensitive.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil else { return command }
        var text = command
        text = replace(flagValue, in: text, with: "$1$2$3" + mask)
        text = replace(envValue, in: text, with: "$1$2$3" + mask)
        text = replace(quotedValue, in: text, with: "$1$2" + mask + "$4")
        text = replace(headerValue, in: text, with: "$1$2" + mask)
        text = replace(urlPassword, in: text, with: "$1" + mask + "$3")
        text = replace(bearer, in: text, with: "$1$2" + mask)
        return text
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
