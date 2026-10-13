import SwiftUI

/// A session in the list, as the Mac's panel lists one: its state, its title with the words that
/// matched, what it's doing or asking (or the line of what was said that matched), and where it
/// is, with how long its state has lasted. Compact, in the list by project under its worktree, it
/// is its state, title and time on one line, as Codex's phone app lists a folder's chats.
struct QuickSessionRow: View {
    let row: SessionRow
    var said: SaidHit?
    var words: [String] = []
    let showDevice: Bool
    var showProject = true
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A snoozed one waits apart, unmarked, as on the Mac.
            StatusMark(status: row.snoozedUntil == nil ? row.status : .idle, stalled: row.stalled, waiting: row.waitsInBackground)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Marked.text(row.title, words: words))
                        .font(.body.weight(wantsYou ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let until = row.snoozedUntil {
                            Label(Clock.until(until, now: context.date), systemImage: "moon.zzz")
                                .accessibilityLabel("Snoozed, back in \(Clock.until(until, now: context.date))")
                        } else {
                            Text(Clock.ago(row.statusSince ?? row.lastActivity, now: context.date))
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                if !compact {
                    if let said {
                        Text("\(said.you ? "You: " : "")\(Marked.text(said.snippet, words: words))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let detail = row.detail, !detail.isEmpty {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(Clock.text(detail, now: context.date))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Text(place)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, compact ? 6 : 3)
        .opacity(row.deviceOnline ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var wantsYou: Bool {
        row.section == .needsYou || row.section == .yourTurn
    }

    /// Where it is, as the Mac's panel says it: the account and the worktree, and the Mac and
    /// project when those aren't plain.
    private var place: String {
        var parts: [String] = []
        if showDevice { parts.append(Names.short(row.deviceName)) }
        if showProject { parts.append(row.project) }
        parts.append(row.account)
        parts.append(row.worktree)
        return parts.joined(separator: " · ")
    }
}

/// A PR in the list: its number and title, who it waits on, and where it stands, its checks or
/// its review, with how much it changes.
struct QuickPrRow: View {
    let pr: PrRow
    var words: [String] = []
    var showProject = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Text(verbatim: "#\(pr.number)").foregroundStyle(.secondary)) \(Marked.text(pr.title, words: words))")
                        .font(.body.weight(pr.waits ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Clock.ago((pr.waits ? pr.requestedAt : nil) ?? pr.updatedAt, now: context.date))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                if let meta {
                    Text(meta)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if let s = standing.symbol {
                        Image(systemName: s).font(.caption.weight(.bold))
                    }
                    Text(standing.words)
                    Spacer(minLength: 4)
                    if pr.additions + pr.deletions > 0 {
                        Text("+\(pr.additions) −\(pr.deletions)")
                            .font(.footnote.monospaced())
                            .foregroundStyle(Color.secondary)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(standing.color)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityHint(pr.slug.isEmpty ? "Opens it on GitHub" : "Opens it")
    }

    /// Its repo, where the list spans projects, and who it's by or who asked for your review.
    private var meta: String? {
        var parts: [String] = []
        if showProject { parts.append(pr.repo) }
        if pr.waits {
            parts.append(pr.requestedBy.map { "\($0) asked you" } ?? "your review is asked for")
        } else if let until = pr.snoozedUntil, pr.reviewRequested {
            parts.append("review back in \(Clock.until(until, now: .now))")
        } else if !pr.mine, let author = pr.author {
            parts.append(author)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where it stands, as GitHub's merge box would lead with it.
    private var standing: (symbol: String?, words: String, color: Color) {
        switch pr.state {
        case "merged": return ("arrow.triangle.merge", "Merged", .purple)
        case "closed": return ("xmark.circle", "Closed", .secondary)
        default: break
        }
        if pr.failing > 0 { return ("xmark", pr.failing == 1 ? "1 check failing" : "\(pr.failing) checks failing", .red) }
        if pr.state == "draft" { return (nil, "Draft", .secondary) }
        if pr.state == "changes" { return ("exclamationmark.bubble", "Changes asked for", .orange) }
        if pr.merge == "conflicts" { return ("exclamationmark.triangle", "Conflicts", .orange) }
        if pr.pending > 0 { return ("clock", "Checks running", .secondary) }
        if pr.state == "approved" { return ("checkmark", pr.merge == "clean" ? "Approved · ready to merge" : "Approved", Self.passed) }
        if pr.passed > 0 { return ("checkmark", "Checks passed", Self.passed) }
        return (nil, "Open", .secondary)
    }

    /// Green dark enough to read as words on white, and the system's own on black.
    private static let passed = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.12, green: 0.55, blue: 0.23, alpha: 1) })

    private var symbol: String {
        switch pr.state {
        case "merged": "arrow.triangle.merge"
        case "closed": "xmark.circle"
        default: "arrow.triangle.pull"
        }
    }

    private var color: Color {
        switch pr.state {
        case "merged": .purple
        case "closed": .secondary
        case "draft": .secondary
        default: pr.waits ? .orange : pr.failing > 0 ? .red : .green
        }
    }
}

/// A Mac's suggestion for what's typed: what it would do, why, where, and how likely.
struct SuggestionRow: View {
    let suggestion: Suggestion
    let composer: Composer
    let showDevice: Bool

    var body: some View {
        let said = describe
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: said.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 28, height: 28)
                .background(Color.primary, in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(said.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text("\(Int((suggestion.p * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(sureColor)
                }
                Text(said.why)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(said.place)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var sureColor: Color {
        switch suggestion.sureness {
        case .sure: .primary
        case .likely: .secondary
        case .unsure: Color.secondary.opacity(0.6)
        }
    }

    /// What the row says, as the Mac's panel words it.
    private var describe: (symbol: String, title: String, why: String, place: String) {
        if let x = suggestion.session {
            let place = [showDevice ? Names.short(x.deviceName) : nil, x.account, x.worktree].compactMap { $0 }.joined(separator: " · ")
            // How old it is leads, so an old session isn't mistaken for the one you started this morning.
            let age = x.startedAt.map { "Started \(Clock.ago($0, now: .now)) ago. " } ?? ""
            if suggestion.kind == .open {
                return x.status == .needs
                    ? ("arrow.up.forward", "Answer “\(x.title)”", "\(age)It’s waiting on you, so it opens and you answer there.", place)
                    : ("arrow.up.forward", "Open “\(x.title)”", age + (x.detail.map { String(Clock.text($0, now: .now).characters) } ?? ""), place)
            }
            let why = !x.live
                ? "It isn’t running: its Mac resumes it with this prompt."
                : x.status == .working
                    ? "It’s working, so this waits for its turn to end."
                    : x.inApp && x.harness == "Claude Code"
                        ? "It gets this as a message from another session, in the Claude app."
                        : "It gets this as its next message."
            return ("paperplane", "Send to “\(x.title)”", age + why, place)
        }
        guard let w = suggestion.worktree else { return ("plus", "Start a new session", "", "") }
        if w.chat {
            return ("plus", "Start a chat in no project", composer.happens(in: w, newWorktree: false), "No project")
        }
        let tree = composer.takesNewWorktree && suggestion.newWorktree
        let title = tree ? "Start in a new worktree of \(w.repo)" : "Start in \(w.main ? "\(w.name) (main)" : w.name)"
        let place = [w.project, w.repo].joined(separator: " · ")
        return ("plus", title, composer.happens(in: w, newWorktree: tree), place)
    }
}

/// A session's state as a small dot: orange when it needs you, red on an error, blue (breathing)
/// while it works, the accent color when it's your turn, and nothing when it's idle. One working
/// only in that it waits on a command it left running (a CI watch, a build) is a still clock, as
/// on the Mac.
struct StatusMark: View {
    let status: Status
    let stalled: Bool
    var waiting = false

    var body: some View {
        if waiting && status == .working && !stalled {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 10)
                .accessibilityLabel("Waiting on a command it left running")
        } else {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .working && !stalled)
                .frame(width: 10)
                .accessibilityLabel(label)
        }
    }

    private var color: Color {
        if stalled { return .orange }
        switch status {
        case .needs: return .orange
        case .error: return .red
        case .working: return .blue
        case .unread: return .accentColor
        case .idle, .stopped: return .clear
        }
    }

    private var label: String {
        if stalled { return "Stuck" }
        switch status {
        case .needs: return "Needs you"
        case .error: return "Error"
        case .working: return "Working"
        case .unread: return "Your turn"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        }
    }
}
