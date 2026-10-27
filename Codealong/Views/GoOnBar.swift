import SwiftUI

/// What going on to the next session that waits on you does to the one you go on from: a swipe
/// across the conversation, Next over the box, Go to next in the menu and ⌘] all do it. You pick it
/// over the reply box for the session you're on: each starts at Mark as seen, what going on did
/// before there was a choice, so marking one done or snoozing one doesn't carry over to the next.
/// A snooze runs for a time the menus offer, as the session's own Snooze does (`Snooze`).
enum SwipeOn: Hashable {
    case seen, done, archive
    case snooze(Snooze.For)

    var label: String {
        switch self {
        case .seen: "Mark as seen"
        case .done: "Mark as done"
        case .archive: "Archive"
        case .snooze(let time): "Snooze \(Snooze.phrase(time.picked()))"
        }
    }

    /// As the session's menu draws the same.
    var symbol: String {
        switch self {
        case .seen: "eye"
        case .done: "checkmark.circle"
        case .archive: "archivebox"
        case .snooze: "moon.zzz"
        }
    }

    /// The bar's menu on a session's screen: what to mark it, then its times to snooze to, as the
    /// session's own menu has them.
    @ViewBuilder
    static func picker(_ pick: Binding<SwipeOn>) -> some View {
        Picker("When you go on to the next", selection: pick) {
            ForEach([SwipeOn.seen, .done, .archive], id: \.self) { c in
                Label(c.label, systemImage: c.symbol).tag(c)
            }
        }
        .pickerStyle(.inline)
        snoozes(pick) { SwipeOn.snooze($0) }
    }
}

/// What going on from a PR waiting on your review does to it, picked over its review box for the
/// PR you're on, each starting at the first: it comes round again after the rest, as the Mac's ⌘E
/// skips it, or your review of it is snoozed, as its Snooze review does, for a time the menus
/// offer (`Snooze`).
enum ReviewSwipeOn: Hashable {
    case later
    case snooze(Snooze.For)

    /// The snooze it is, as the menus offer it now; nil for coming back to it later.
    func snoozeChoice(now: Date = .now) -> Snooze.Choice? {
        if case .snooze(let time) = self { return time.picked(now: now) }
        return nil
    }

    var label: String {
        snoozeChoice().map { "Snooze \(Snooze.phrase($0))" } ?? "Come back to it later"
    }

    var symbol: String { self == .later ? Going.later.symbol : "moon.zzz" }

    /// The bar's menu on a PR's page.
    @ViewBuilder
    static func picker(_ pick: Binding<ReviewSwipeOn>) -> some View {
        Picker("When you go on to the next", selection: pick) {
            Label(ReviewSwipeOn.later.label, systemImage: ReviewSwipeOn.later.symbol).tag(ReviewSwipeOn.later)
        }
        .pickerStyle(.inline)
        snoozes(pick) { ReviewSwipeOn.snooze($0) }
    }
}

/// Snooze in the bar's menu, opening on the times a snooze can run to now, as the Snooze in a
/// session's or a PR's own menu does; the one picked is checked.
private func snoozes<Pick: Hashable>(_ pick: Binding<Pick>, _ as: @escaping (Snooze.For) -> Pick) -> some View {
    Menu("Snooze", systemImage: "moon.zzz") {
        Picker("Snooze", selection: pick) {
            ForEach(Snooze.For.allCases.filter { $0.choice() != nil }, id: \.self) { time in
                Text(time.picked().label).tag(`as`(time))
            }
        }
        .pickerStyle(.inline)
    }
}

/// What going on from a page does to what it shows: what you picked (`SwipeOn` on a session's
/// screen, `ReviewSwipeOn` on a PR's page), where that applies. A session you've replied to or
/// answered here is left to the turn you gave it, one at work is left to its work (Mark as done
/// would only be held by it), and one that waits on you to allow a call or answer its questions
/// comes round again after the rest, as it did before there was a choice; a snooze picked for one
/// is done whatever it waits on. A PR you reviewed here, or one that doesn't wait on your review, is
/// left as it is.
enum Going: Equatable {
    case seen, done, archive
    /// Nothing more is done to it: you've replied here, or there's nothing in it to mark seen.
    case on
    /// It's at work, so Mark as done or Archive leaves it be.
    case working
    /// It waits on an answer from you, or a PR on your review, so it comes round again after the
    /// rest.
    case later
    /// It's snoozed, a session or your review of a PR, for as long as this says ("for 1 hour").
    case snooze(String)

    /// `acted`: you replied or answered here, or a message to it is still on its way. Going on
    /// leaves it to that turn, whatever was picked: a snooze would be ended by the prompt as it
    /// lands in the session's record, as its Mac has it (board.rs `apply_snooze`).
    static func of(_ pick: SwipeOn, row: SessionRow?, pending: Pending?, acted: Bool) -> Going {
        guard let row else { return .on }
        // Before its Mac has said what it waits on, its status says it waits on something.
        let waits = pending != nil || (row.status == .needs && !row.seenable)
        switch pick {
        case _ where acted: return .on
        // A snooze picked for this one is done whatever it waits on: it puts nothing off for
        // good, and its Mac snoozes a session at any stage, as its own Snooze does.
        case .snooze(let time): return .snooze(Snooze.phrase(time.picked()))
        case _ where waits: return .later
        case .seen: return row.seenable ? .seen : .on
        case .done: return row.status == .working ? .working : .done
        case .archive: return row.status == .working ? .working : .archive
        }
    }

    static func of(_ pick: ReviewSwipeOn, pr: PrRow?, acted: Bool) -> Going {
        guard let pr, pr.waits, !acted else { return .on }
        return pick.snoozeChoice().map { .snooze(Snooze.phrase($0)) } ?? .later
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
        case .snooze(let phrase): "Snoozes this one \(phrase)"
        }
    }
}

/// Over a session's reply box or a PR's review box while you go through what waits on you: what
/// going on does to this one, and where it goes. The first line says what a swipe does here, and
/// its menu picks what going on does to this one (`SwipeOn`, `ReviewSwipeOn`); under it, the
/// next session or PR, or on the last one Finish, which a tap goes on to as the swipe does.
struct GoOnBar<Choices: View>: View {
    let next: Onward
    let more: Int
    let showDevice: Bool
    /// The inbox shows every project, so it says which it's in.
    let showProject: Bool
    let going: Going
    /// What's picked now, for VoiceOver.
    let picked: String
    /// What going on does can be picked here: the end of what waits has nothing to do to itself.
    var picks = true
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
                    if !place.isEmpty { placeText.fixedSize() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    choice
                    if !place.isEmpty { placeText }
                }
            }
            Button(action: action) {
                HStack(spacing: 10) {
                    switch next {
                    case .to(.session(let row)):
                        StatusMark(status: row.status, stalled: row.stalled, waiting: row.waitsInBackground)
                        HStack(spacing: 5) {
                            if let emblem = row.emblem {
                                EmblemView(emblem: emblem, size: 15)
                            }
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                    case .to(.pr(let pr)):
                        // Waiting on your review, in the color of what needs you.
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(pr.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    case .end:
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("Nothing else waits on you")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(next == .end ? "Finish" : "Next")
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
            .accessibilityHint([going.spoken, next == .end ? nil : more > 0 ? "\(more) more wait on you after it" : "The last that waits on you"].compactMap { $0 }.joined(separator: ". "))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var nextWords: String {
        switch next {
        case .to(.session(let row)): "Next: \(row.title)"
        case .to(.pr(let pr)): "Next: your review of #\(pr.number), \(pr.title)"
        case .end: "Finish: nothing else waits on you"
        }
    }

    /// What a swipe does here, and the menu that picks what going on does.
    @ViewBuilder
    private var choice: some View {
        if picks {
            Menu {
                choices()
            } label: {
                swipeWords(menu: true)
            }
            // Gray, under the session it goes to: a menu's label takes the tint, which washed out.
            .tint(.secondary)
            .accessibilityLabel(going.words)
            .accessibilityHint("Picks what going on to the next does. Now: \(picked)")
        } else {
            swipeWords(menu: false).foregroundStyle(.secondary)
        }
    }

    private func swipeWords(menu: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: going.symbol)
            Text(going.words)
            if menu {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .contentShape(.rect)
    }

    private var placeText: some View {
        Text(place)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    /// What the next is, where it is, and how many wait after it; nothing for the end, which its
    /// line says.
    private var place: String {
        var parts: [String] = []
        let (device, project): (String, String)
        switch next {
        case .to(.session(let row)): (device, project) = (row.deviceName, row.project)
        case .to(.pr(let pr)): (device, project) = (pr.deviceName, pr.project)
        case .end: return ""
        }
        if case .to(.pr(let pr)) = next { parts.append("Review #\(pr.number)") }
        if showDevice { parts.append(Names.short(device)) }
        if showProject { parts.append(project) }
        if more > 0 { parts.append("\(more) more after it") }
        if parts.isEmpty { parts.append("The last that waits on you") }
        return parts.joined(separator: " · ")
    }
}
