import Foundation

/// The Mac writes live times into what a session says, `{ago:<ms>}` and `{for:<ms>}`, and code as
/// backtick spans; the core writes `{in:<ms>}` for a time to come. This turns them into text for
/// now, as the Mac's format.ts `withTimes` does: `{ago:}` is `4m ago`, `{for:}` how long since,
/// `14m`, the Mac writing any "for" before it ("Stuck on `npm test` for {for:<ms>}").
enum Clock {
    static func text(_ s: String, now: Date) -> AttributedString {
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let token = rest[rest.index(after: open)..<close]
            if let ms = token.split(separator: ":").last.flatMap({ Int64($0) }) {
                if token.hasPrefix("ago:") {
                    let past = ago(ms, now: now)
                    out += past == "now" ? "just now" : past + " ago"
                } else if token.hasPrefix("for:") {
                    out += duration(ms, now: now)
                } else if token.hasPrefix("in:") {
                    out += "in " + until(ms, now: now)
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

    /// How long until a time in milliseconds, briefly: `4m`, `3h`, `2d`.
    static func until(_ ms: Int64, now: Date) -> String {
        let secs = max(60, Double(ms) / 1000 - now.timeIntervalSince1970)
        return brief(secs)
    }

    /// How long running work has gone, as the Mac's format.ts `duration` says it: `<1m`, `14m`,
    /// `2h 5m`, `1d 3h`.
    static func duration(_ ms: Int64, now: Date) -> String {
        let mins = Int(max(0, now.timeIntervalSince1970 - Double(ms) / 1000) / 60)
        switch mins {
        case ..<1: return "<1m"
        case ..<60: return "\(mins)m"
        case ..<1440: return mins % 60 == 0 ? "\(mins / 60)h" : "\(mins / 60)h \(mins % 60)m"
        default: return "\(mins / 1440)d \(mins / 60 % 24)h"
        }
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

extension Date {
    /// A time the core gives, in milliseconds since the epoch.
    init(ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// This time as the core takes one, in milliseconds since the epoch.
    var ms: Int64 { Int64(timeIntervalSince1970 * 1000) }
}
