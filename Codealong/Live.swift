import Foundation

/// The Mac writes live times into what a session says, `{ago:<ms>}` and `{for:<ms>}`, and code as
/// backtick spans; this turns them into text for now.
enum Live {
    static func text(_ s: String, now: Date) -> AttributedString {
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let token = rest[rest.index(after: open)..<close]
            if let ms = token.split(separator: ":").last.flatMap({ Int64($0) }) {
                if token.hasPrefix("ago:") {
                    out += ago(ms, now: now) + " ago"
                } else if token.hasPrefix("for:") {
                    out += "for " + span(ms, now: now)
                } else {
                    out += rest[open...close]
                }
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: out, options: options)) ?? AttributedString(out)
    }

    /// How long ago a time in milliseconds was, briefly: `now`, `4m`, `3h`, `2d`.
    static func ago(_ ms: Int64, now: Date) -> String {
        let secs = max(0, now.timeIntervalSince1970 - Double(ms) / 1000)
        return brief(secs)
    }

    private static func span(_ ms: Int64, now: Date) -> String {
        brief(max(0, now.timeIntervalSince1970 - Double(ms) / 1000))
    }

    private static func brief(_ secs: Double) -> String {
        switch secs {
        case ..<60: return "now"
        case ..<3600: return "\(Int(secs / 60))m"
        case ..<86400: return "\(Int(secs / 3600))h"
        default: return "\(Int(secs / 86400))d"
        }
    }
}
