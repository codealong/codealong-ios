import SwiftUI

/// A session in the list, as the Mac's panel lists one: its state, its title with the words that
/// matched, what it's doing or asking (or the line of what was said that matched), and where it
/// is, with how long its state has lasted. Compact, in the list by project under its worktree, it
/// is its state, title and time on one line, as Codex's phone app lists a folder's chats. Its
/// worktree's PR, where it has one, ends the line that says where it is (`PrBadge`).
struct QuickSessionRow: View {
    let row: SessionRow
    var said: SaidHit?
    var words: [String] = []
    let showDevice: Bool
    var showProject = true
    var compact = false
    /// Its worktree's PR, as the PRs listed have it; none on that PR's own page.
    var pr: PrRow? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusMark(mark: row.mark)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let emblem = row.emblem {
                        EmblemView(emblem: emblem, mac: row.device, size: 18)
                            .onCapitals(of: .body)
                            .padding(.trailing, -2)
                    }
                    Text(Marked.text(row.title, words: words))
                        .font(.body.weight(wantsYou ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // A compact row has no line for its chips.
                    if compact && row.raised != nil {
                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Moved to the top")
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let until = row.snoozedUntil {
                            Label(Clock.until(until, now: context.date), systemImage: "moon.zzz")
                                .accessibilityLabel("Snoozed, back in \(Clock.until(until, now: context.date))")
                        } else if row.archived && row.mark == .archived {
                            // Its mark is the box already.
                            Text(Clock.ago(row.statusSince ?? row.lastActivity, now: context.date))
                                .accessibilityLabel("Archived, \(Clock.ago(row.statusSince ?? row.lastActivity, now: context.date))")
                        } else if row.archived {
                            // Listed only because searches and PRs list archived sessions too; one
                            // at work or waiting on you has that for its mark.
                            Label(Clock.ago(row.statusSince ?? row.lastActivity, now: context.date), systemImage: "archivebox")
                                .accessibilityLabel("Archived, \(Clock.ago(row.statusSince ?? row.lastActivity, now: context.date))")
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
                    if row.labels.isEmpty {
                        whereLine(labels: false)
                    } else {
                        // Its labels beside where it is while they fit, as on the Mac; else on a
                        // line of their own, which ends where the row does, so where it is still shows.
                        ViewThatFits(in: .horizontal) {
                            whereLine(labels: true)
                            VStack(alignment: .leading, spacing: 3) {
                                whereLine(labels: false)
                                labelsText(row.labels)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .accessibilityLabel(labelsSaid(row.labels))
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, compact ? 6 : 3)
        .opacity(row.deviceOnline ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    /// Its marks (Top, On the side, Finished, Seen by agent), its labels with `labels`, and where
    /// it is.
    private func whereLine(labels: Bool) -> some View {
        HStack(spacing: 6) {
            if row.raised != nil {
                Chip(words: "Top", symbol: "arrow.up", tint: .orange)
            }
            if row.aside {
                Chip(words: "On the side", symbol: "bubble.left.and.bubble.right", tint: .blue)
            }
            if let finished = row.finished {
                Chip(words: finished.label, symbol: finished.sure ? "checkmark.seal.fill" : "checkmark.seal", tint: finished.sure ? .green : .secondary)
            }
            if row.agentSeen != nil {
                Chip(words: "Seen by agent", symbol: "eye", tint: .secondary)
            }
            if labels {
                ForEach(row.labels, id: \.id) { SessionLabelChip(label: $0) }
            }
            Text(place)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            // After where it is, which gives way to it: the worktree's name is cut short first.
            if let pr {
                PrBadge(pr: pr)
            }
        }
    }

    private var wantsYou: Bool {
        row.section == .needsYou || row.section == .yourTurn
    }

    /// Where it is, as the Mac's panel says it: the account and the worktree, and the Mac and
    /// project when those aren't plain. Then the headless runs its commands started, which the
    /// list counts here rather than listing, as the Mac's row does on a chip; or, for a headless
    /// run listed as a session of its own (no session on a linked Mac ran it), that it is one.
    private var place: String {
        var parts: [String] = []
        if showDevice { parts.append(Names.short(row.deviceName)) }
        if showProject { parts.append(row.project) }
        parts.append(row.account)
        parts.append(row.worktree)
        if row.runs > 0 {
            let runs = row.runs == 1 ? "1 run" : "\(row.runs) runs"
            parts.append(row.runsWorking > 0 ? "\(runs), \(row.runsWorking) at work" : runs)
        }
        if row.headless { parts.append("headless") }
        return parts.joined(separator: " · ")
    }
}

/// A word on a row that says something of it, as the Mac's chips do: Top, On the side, Finished,
/// Seen by agent (and the labels you put on it, `SessionLabelChip`). Its page says who and why,
/// which a Mac's tooltip does there.
private struct Chip: View {
    let words: String
    let symbol: String
    let tint: Color

    var body: some View {
        // A label's icon keeps a width of its own, which leaves a gap wider than the word here.
        HStack(spacing: 2) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(words)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A PR in the list: its number and title, who it waits on, and where it stands, its checks or
/// its review, with how much it changes.
struct QuickPrRow: View {
    let pr: PrRow
    var words: [String] = []

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
                // Its labels after its repo, as many as fit, as the Mac's row has them after its title.
                HStack(spacing: 8) {
                    Text(meta)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                    if !pr.labels.isEmpty {
                        PrLabels(labels: pr.labels, compact: true)
                    }
                }
                .lineLimit(1)
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

    /// Its repo, which tells two repos' numbers apart, and who it's by or who asked for your
    /// review.
    private var meta: String {
        var parts = [pr.repo]
        if pr.waits {
            parts.append(pr.requestedBy.map { "\($0) asked you" } ?? "your review is asked for")
        } else if let until = pr.snoozedUntil, pr.reviewRequested {
            parts.append("review back in \(Clock.until(until, now: .now))")
        } else if !pr.mine, let author = pr.author {
            parts.append(author)
        }
        return parts.joined(separator: " · ")
    }

    /// Where it stands, as the core says it (`PrStanding`): GitHub's merge box's lead.
    private var standing: (symbol: String?, words: String, color: Color) {
        (pr.standing.symbol, pr.standing.words, pr.standing.color)
    }

    private var symbol: String { pr.mark.symbol }

    private var color: Color { pr.mark.color }
}

/// A session's PR at the end of the line that says where it is, as small as it can say it: its
/// icon in its mark's color, its number, and where it stands as a symbol where that says more than
/// the icon (checks passed or failing, approved, your move). Its page says the rest.
struct PrBadge: View {
    let pr: PrRow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: pr.mark.symbol)
                .foregroundStyle(pr.mark.color)
            Text(verbatim: "#\(pr.number)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            if let symbol = pr.standing.symbol, symbol != pr.mark.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(pr.standing.color)
            }
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PR \(pr.number), \(pr.standing.words)")
    }
}

extension PrStanding {
    /// What's drawn beside its words, where anything is.
    var symbol: String? {
        switch kind {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .failing: "xmark"
        case .agentApproves: "checkmark.seal"
        case .agentReviewing: "hourglass"
        case .turn(let turn, _): TurnLabel.symbol(kind: turn)
        case .changes: "exclamationmark.bubble"
        case .conflicts: "exclamationmark.triangle"
        case .checksRunning: "clock"
        // Approved only before its latest commits: GitHub still counts it, so it says so in amber.
        case .staleApproval: "clock.badge.exclamationmark"
        case .approved, .checksPassed: "checkmark"
        case .draft, .open: nil
        }
    }

    var color: Color {
        switch kind {
        case .merged: .purple
        case .failing: .red
        case .agentApproves, .approved, .checksPassed: .prPassed
        case .turn(_, let yours): yours ? .orange : .secondary
        case .changes, .conflicts, .staleApproval: .orange
        case .closed, .agentReviewing, .draft, .checksRunning, .open: .secondary
        }
    }
}

extension PrMark {
    var symbol: String {
        switch self {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .open, .draft, .waits, .failing: "arrow.triangle.pull"
        }
    }

    var color: Color {
        switch self {
        case .merged: .purple
        case .closed, .draft: .secondary
        case .waits: .orange
        case .failing: .red
        case .open: .green
        }
    }
}

extension Color {
    /// A PR's green: dark enough to read as words on white, and the system's own on black.
    static let prPassed = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.12, green: 0.55, blue: 0.23, alpha: 1) })
}

/// A Mac's suggestion for what's typed: what it would do, where, why, and how likely, as the start
/// bar lists it over its capsule, short so that three fit over the keyboard: where leads the line
/// under the title, so two sessions of a title are told apart before a tap sends to one.
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
                .background(Color(.label), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(said.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int((suggestion.p * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(sureColor)
                }
                Group {
                    if said.place.isEmpty {
                        Text(said.why)
                    } else {
                        Text("\(Text(said.place).monospaced().foregroundStyle(.tertiary))  \(said.why)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
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

/// A session's state as a small mark, as the core reads it (`Mark`, the Mac's SessionGlyph): an
/// orange dot when it needs you or is stuck, red on an error, blue (breathing) while it works, the
/// accent color when it's your turn, and nothing when it's idle. One working only in that it
/// waits, on what its turn left running (a CI watch, a build, its agents) or, set aside, on its
/// side conversation, is a still clock; one hearing a meeting is a recording light; an archived
/// one is a box.
struct StatusMark: View {
    let mark: Mark

    /// A turn's own state where there's no session's row to read it from (a side conversation's
    /// turn, what a session waits on).
    init(status: Status, stalled: Bool, waiting: Bool = false) {
        mark = switch status {
        case _ where stalled: .stuck
        case .working where waiting: .waiting
        case .needs: .needs
        case .error: .error
        case .working: .working
        case .unread: .unread
        case .idle, .stopped: .quiet
        }
    }

    init(mark: Mark) {
        self.mark = mark
    }

    var body: some View {
        switch mark {
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 10)
                .accessibilityLabel("Waiting")
        case .hearing:
            // A recording light in a ring, beating as the Mac's does.
            Image(systemName: "record.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 10)
                .accessibilityLabel("Listening")
        case .archived:
            Image(systemName: "archivebox")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .accessibilityLabel("Archived")
        default:
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: mark == .working)
                .frame(width: 10)
                .accessibilityLabel(label)
        }
    }

    private var color: Color {
        switch mark {
        case .needs, .stuck: .orange
        case .error: .red
        case .working, .waiting: .blue
        case .unread: .accentColor
        case .hearing: .red
        case .archived, .quiet: .clear
        }
    }

    private var label: String {
        switch mark {
        case .needs: "Needs you"
        case .stuck: "Stuck"
        case .error: "Error"
        case .working: "Working"
        case .waiting: "Waiting"
        case .unread: "Your turn"
        case .hearing: "Listening"
        case .archived: "Archived"
        case .quiet: "Idle"
        }
    }
}
