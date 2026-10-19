import Foundation

/// Turns the core's English messages into the app's language. The core keeps
/// English so its messages stay stable in logs and in the HTTP API. Each English
/// message is the key in Localizable.strings; a message with values in it is
/// matched by a pattern, and the captured values fill the `%@` slots of its key.
public enum CoreText {
    /// Messages that carry values, as (pattern, format key). Captures fill the
    /// format's `%@` slots in order.
    static let templates: [(pattern: String, key: String)] = [
        ("^io error at (.+): (.+)$", "io error at %@: %@"),
        ("^failed to parse (.+): (.+)$", "failed to parse %@: %@"),
        ("^failed to serialize (.+): (.+)$", "failed to serialize %@: %@"),
        ("^config key not found: (.+)$", "config key not found: %@"),
        ("^config value for (.+) failed validation: (.+)$", "config value for %@ failed validation: %@"),
        ("^failed to apply (.+) to the OS: (.+)$", "failed to apply %@ to the OS: %@"),
        ("^HTTP API port (.+): (.+)$", "HTTP API port %@: %@"),
        ("^invalid data directory choice: (.+)$", "invalid data directory choice: %@"),
        ("^concurrent storage change: (.+)$", "concurrent storage change: %@"),
        ("^applied but failed to persist the tree: (.+)$", "applied but failed to persist the tree: %@"),
        ("^no access: (.+)$", "no access: %@"),
        ("^io: (.+)$", "io: %@"),
        ("^invalid hosts content: (.+)$", "invalid hosts content: %@"),
        ("^write (.+): (.+)$", "write %@: %@"),
        ("^read (.+): (.+)$", "read %@: %@"),
        ("^restore (.+): (.+)$", "restore %@: %@"),
        ("^response body too large: (.+) bytes exceeds limit of (.+) bytes$",
         "response body too large: %@ bytes exceeds limit of %@ bytes"),
        ("^Invalid domain: (.+)$", "Invalid domain: %@"),
        ("^DNS service returned HTTP (.+)\\.$", "DNS service returned HTTP %@."),
        ("^invalid pattern: (.+)$", "invalid pattern: %@"),
        ("^command timed out after (.+)s$", "command timed out after %@s"),
        ("^error_([0-9]+)$", "Server returned HTTP %@."),
        ("^expected a string at args\\[([0-9]+)\\]$", "expected a string at args[%@]"),
        ("^find_replace_one: invalid request: (.+)$", "find_replace_one: invalid request: %@"),
        ("^payload too large: ([0-9]+) bytes$", "payload too large: %@ bytes"),
        ("^DNS server returned status (.+)\\. The DNS service can be changed in Preferences\\.$",
         "DNS server returned status %@. The DNS service can be changed in Preferences."),
    ]

    /// The localized text for a core message. Messages without a translation are
    /// returned unchanged. Captured values are localized too, so a message such as
    /// "config value for X failed validation: expected ..." translates its reason.
    public static func localized(_ message: String) -> String {
        let text = message as NSString
        let whole = NSRange(location: 0, length: text.length)
        for template in templates {
            guard let regex = try? NSRegularExpression(pattern: template.pattern),
                  let match = regex.firstMatch(in: message, range: whole) else { continue }
            let values: [CVarArg] = (1..<match.numberOfRanges).map {
                localized(text.substring(with: match.range(at: $0))) as NSString
            }
            return String(format: NSLocalizedString(template.key, comment: ""), arguments: values)
        }
        return NSLocalizedString(message, comment: "")
    }
}
