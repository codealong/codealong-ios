import Foundation

/// The times a snooze can run to, as the Mac's menus offer them (snooze.ts `snoozeChoices`): a few
/// from now, the next morning at nine (still this morning before five), and the Monday morning
/// after it. A snoozed session stays off Needs you and Your turn on every device until then, and
/// comes back as Your turn.
enum Snooze {
    struct Choice: Identifiable {
        let label: String
        let until: Date
        var id: String { label }
    }

    static func choices(now: Date = .now) -> [Choice] {
        For.allCases.map { $0.choice(now: now) }
    }

    /// Which of the times offered a snooze runs to, kept as which it is rather than when, so a
    /// pick made now is worked out when it's used. In the order the menus offer them.
    enum For: CaseIterable, Hashable {
        case quarter, half, hour, hours, morning, week

        /// It as the menus offer it now.
        func choice(now: Date = .now) -> Choice {
            switch self {
            case .quarter: return Choice(label: "For 15 minutes", until: now.addingTimeInterval(15 * 60))
            case .half: return Choice(label: "For 30 minutes", until: now.addingTimeInterval(30 * 60))
            case .hour: return Choice(label: "For 1 hour", until: now.addingTimeInterval(3600))
            case .hours: return Choice(label: "For 3 hours", until: now.addingTimeInterval(3 * 3600))
            case .morning:
                let morning = Snooze.morning(now: now)
                return Choice(label: "Until \(words(morning, now: now))", until: morning)
            case .week:
                let week = Snooze.week(now: now)
                return Choice(label: "Until \(words(week, now: now))", until: week)
            }
        }
    }

    /// Nine the next morning, or this morning's in the small hours.
    private static func morning(now: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let day = calendar.component(.hour, from: now) < 5 ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? now.addingTimeInterval(12 * 3600)
    }

    /// Nine on the Monday after the next morning: a week on when that morning is a Monday's, so
    /// the two are never the same time.
    private static func week(now: Date) -> Date {
        let calendar = Calendar.current
        let morning = morning(now: now)
        // Weekdays count from Sunday, 1, so Monday is 2.
        let ahead = (2 - calendar.component(.weekday, from: morning) + 7) % 7
        let day = calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: calendar.startOfDay(for: morning)) ?? morning
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? morning.addingTimeInterval(7 * 86400)
    }

    /// A choice as a phrase to go after a verb: "for 1 hour", "until tomorrow 9 AM".
    static func phrase(_ choice: Choice) -> String {
        choice.label.prefix(1).lowercased() + choice.label.dropFirst()
    }

    /// When a snooze ends, as a clock says it (snooze.ts `untilWords`): `3:40 PM` today,
    /// `tomorrow 9 AM`, `Fri 9 AM` within the week, `Oct 3, 9 AM` beyond.
    static func words(_ at: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: at)).day ?? 0
        // A plain space before AM or PM, as the Mac writes it, not the narrow one iOS puts there.
        let clock = at.formatted(.dateTime.hour().minute()).replacingOccurrences(of: ":00", with: "").replacingOccurrences(of: "\u{202F}", with: " ")
        if days <= 0 { return clock }
        if days == 1 { return "tomorrow \(clock)" }
        if days < 7 { return "\(at.formatted(.dateTime.weekday(.abbreviated))) \(clock)" }
        return "\(at.formatted(.dateTime.month(.abbreviated).day())), \(clock)"
    }
}
