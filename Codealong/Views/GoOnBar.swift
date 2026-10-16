import SwiftUI

/// What going on to the next session that waits on you does to the one you go on from: a swipe
/// across the conversation, Next over the box, Go to next in the menu and ⌘] all do it. You pick it
/// over the reply box, and it's kept for every session after.
enum SwipeOn: String, CaseIterable, Identifiable {
    case seen, done, archive

    var id: Self { self }

    var label: String {
        switch self {
        case .seen: "Mark as seen"
        case .done: "Mark as done"
        case .archive: "Archive"
        }
    }

    /// As the session's menu draws the same.
    var symbol: String {
        switch self {
        case .seen: "eye"
        case .done: "checkmark.circle"
        case .archive: "archivebox"
        }
    }

    /// The bar's menu on a session's screen.
    static func picker(_ pick: Binding<SwipeOn>) -> some View {
        Picker("When you go on to the next", selection: pick) {
            ForEach(allCases) { c in
                Label(c.label, systemImage: c.symbol).tag(c)
            }
        }
        .pickerStyle(.inline)
    }
}

/// What going on from a PR waiting on your review does to it, picked over its review box and kept
/// for every PR after: it comes round again after the rest, as the Mac's ⌘E skips it, or your
/// review of it is snoozed, as its Snooze review does, for a time the menus offer (`Snooze`).
enum ReviewSwipeOn: String, CaseIterable, Identifiable {
    case later, quarter, hour, hours, morning

    var id: Self { self }

    /// The snooze it is, as the menus offer it now; nil for coming back to it later.
    func snooze(now: Date = .now) -> Snooze.Choice? {
        // In the order `Snooze.choices` offers them.
        let offered = Snooze.choices(now: now)
        switch self {
        case .later: return nil
        case .quarter: return offered[0]
        case .hour: return offered[1]
        case .hours: return offered[2]
        case .morning: return offered[3]
        }
    }

    var label: String {
        snooze().map { "Snooze \(Snooze.phrase($0))" } ?? "Come back to it later"
    }

    var symbol: String { self == .later ? Going.later.symbol : "moon.zzz" }

    /// The bar's menu on a PR's page.
    static func picker(_ pick: Binding<ReviewSwipeOn>) -> some View {
        Picker("When you go on to the next", selection: pick) {
            ForEach(allCases) { c in
                Label(c.label, systemImage: c.symbol).tag(c)
            }
        }
        .pickerStyle(.inline)
    }
}

/// What going on from a page does to what it shows: what you picked (`SwipeOn` on a session's
/// screen, `ReviewSwipeOn` on a PR's page), where that applies. A session you've replied to or
/// answered here is left to the turn you gave it, one at work is left to its work (Mark as done
/// would only be held by it), and one that waits on you to allow a call or answer its questions
/// comes round again after the rest, as it did before there was a choice. A PR you reviewed here,
/// or one that doesn't wait on your review, is left as it is.
enum Going: Equatable {
    case seen, done, archive
    /// Nothing more is done to it: you've replied here, or there's nothing in it to mark seen.
    case on
    /// It's at work, so Mark as done or Archive leaves it be.
    case working
    /// It waits on an answer from you, or a PR on your review, so it comes round again after the
    /// rest.
    case later
    /// Your review of a PR is snoozed, for as long as this says ("for 1 hour").
    case snooze(String)

    static func of(_ pick: SwipeOn, row: SessionRow?, pending: Pending?, acted: Bool) -> Going {
        guard let row, !acted else { return .on }
        // Before its Mac has said what it waits on, its status says it waits on something.
        if pending != nil || (row.status == .needs && !row.seenable) { return .later }
        switch pick {
        case .seen: return row.seenable ? .seen : .on
        case .done: return row.status == .working ? .working : .done
        case .archive: return row.status == .working ? .working : .archive
        }
    }

    static func of(_ pick: ReviewSwipeOn, pr: PrRow?, acted: Bool) -> Going {
        guard let pr, pr.waits, !acted else { return .on }
        return pick.snooze().map { .snooze(Snooze.phrase($0)) } ?? .later
    }

    /// What the bar says it does.
    var words: String {
        switch self {
        case .seen: "Swipe to mark as seen"
        case .done: "Swipe to mark as done"
        case .archive: "Swipe to archive"
        case .on: "Swipe to go on"
        case .working: "It’s working: swipe to go on"
        case .later: "Swipe to come back to it later"
        case .snooze(let phrase): "Swipe to snooze \(phrase)"
        }
    }

    var symbol: String {
        switch self {
        case .seen: SwipeOn.seen.symbol
        case .done: SwipeOn.done.symbol
        case .archive: SwipeOn.archive.symbol
        case .on, .working: "arrow.forward"
        case .later: "clock.arrow.circlepath"
        case .snooze: "moon.zzz"
        }
    }

    /// What going on does to this one, for VoiceOver on Next.
    var spoken: String? {
        switch self {
        case .seen: "Marks this one seen"
        case .done: "Marks this one done"
        case .archive: "Archives this one"
        case .on: nil
        case .working: "Leaves this one to its work"
        case .later: "This one comes round again after the rest"
        case .snooze(let phrase): "Snoozes your review of this one \(phrase)"
        }
    }
}

/// Over a session's reply box or a PR's review box while something else waits on you: what going
/// on to it does to this one, and what it goes to. The first line says what a swipe does here, and
/// its menu picks what going on does from then on (`SwipeOn`, `ReviewSwipeOn`); under it, the
/// next session or PR, which a tap goes on to as the swipe does.
struct GoOnBar<Choices: View>: View {
    let next: Waiting
    let more: Int
    let showDevice: Bool
    /// The inbox shows every project, so it says which it's in.
    let showProject: Bool
    let going: Going
    /// What's picked now, for VoiceOver.
    let picked: String
    /// The menu's choices.
    @ViewBuilder let choices: () -> Choices
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Where it is goes under what the swipe does when the line can't hold both in full: a
            // menu's label otherwise gave up its room, and what the swipe does was cut short.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    choice.fixedSize()
                    Spacer(minLength: 8)
                    placeText.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    choice
                    placeText
                }
            }
            Button(action: action) {
                HStack(spacing: 10) {
                    switch next {
                    case .session(let row):
                        StatusMark(status: row.status, stalled: row.stalled, waiting: row.waitsInBackground)
                        HStack(spacing: 5) {
                            if let emblem = row.emblem {
                                EmblemView(emblem: emblem, size: 15)
                            }
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                    case .pr(let pr):
                        // Waiting on your review, in the color of what needs you.
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(pr.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text("Next")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(nextWords)
            .accessibilityHint([going.spoken, more > 0 ? "\(more) more wait on you after it" : "The last that waits on you"].compactMap { $0 }.joined(separator: ". "))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var nextWords: String {
        switch next {
        case .session(let row): "Next: \(row.title)"
        case .pr(let pr): "Next: your review of #\(pr.number), \(pr.title)"
        }
    }

    /// What a swipe does here, and the menu that picks what going on does.
    private var choice: some View {
        Menu {
            choices()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: going.symbol)
                Text(going.words)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .contentShape(.rect)
        }
        // Gray, under the session it goes to: a menu's label takes the tint, which washed out.
        .tint(.secondary)
        .accessibilityLabel(going.words)
        .accessibilityHint("Picks what going on to the next does. Now: \(picked)")
    }

    private var placeText: some View {
        Text(place)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    /// What the next is, where it is, and how many wait after it.
    private var place: String {
        var parts: [String] = []
        let (device, project): (String, String) = switch next {
        case .session(let row): (row.deviceName, row.project)
        case .pr(let pr): (pr.deviceName, pr.project)
        }
        if case .pr(let pr) = next { parts.append("Review #\(pr.number)") }
        if showDevice { parts.append(Names.short(device)) }
        if showProject { parts.append(project) }
        if more > 0 { parts.append("\(more) more after it") }
        if parts.isEmpty { parts.append("The last that waits on you") }
        return parts.joined(separator: " · ")
    }
}
