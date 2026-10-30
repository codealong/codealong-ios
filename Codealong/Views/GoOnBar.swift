import SwiftUI

/// What a tap on the bar over the box can do to a page on the way on, besides what a swipe does to
/// it (`SwipeOn` on a session's screen, `ReviewSwipeOn` on a PR's page).
protocol GoOnPick: Hashable {
    var label: String { get }
    var symbol: String { get }
    /// The time it snoozes to: it goes under Snooze in the bar's menu.
    var time: Snooze.For? { get }
}

/// What going on from a session's screen to the next that waits on you can do to it. A swipe, Go
/// to next in the menu and ⌘] mark it seen, which opening it doesn't; a tap on the bar over the
/// box offers the rest, and the one picked is done as it goes on. Leave as it is goes on without
/// marking it anything, so a turn that ended stays in Your turn, or one that asks you something
/// in Needs you, and comes round again after the rest. A snooze runs for a time the menus offer,
/// as the session's own Snooze does (`Snooze`), or for one picked.
enum SwipeOn: GoOnPick {
    case keep, seen, done, archive
    case snooze(Snooze.For)

    var label: String {
        switch self {
        case .keep: "Leave as it is"
        case .seen: "Mark as seen"
        case .done: "Mark as done"
        case .archive: "Archive"
        case .snooze(let time): "Snooze \(Snooze.phrase(time.picked()))"
        }
    }

    /// As the session's menu draws the same.
    var symbol: String {
        switch self {
        case .keep: Going.later.symbol
        case .seen: "eye"
        case .done: "checkmark.circle"
        case .archive: "archivebox"
        case .snooze: "moon.zzz"
        }
    }

    var time: Snooze.For? {
        if case .snooze(let time) = self { return time }
        return nil
    }

    /// What the bar's menu offers besides marking it seen, as it is now (`Going.offered`).
    static func offers(row: SessionRow?, pending: Pending?, acted: Bool) -> [SwipeOn] {
        Going.offered([.keep, .done, .archive] + Snooze.For.offered.map(SwipeOn.snooze), besides: .seen) {
            Going.of($0, row: row, pending: pending, acted: acted)
        }
    }
}

/// What going on from a PR waiting on your review can do to it: a swipe skips it, so it comes
/// round again after the rest, as the Mac's ⌘E does, and a tap on the bar offers snoozing your
/// review of it instead, as its Snooze review does, for a time the menus offer (`Snooze`) or one
/// picked.
enum ReviewSwipeOn: GoOnPick {
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

    var time: Snooze.For? {
        if case .snooze(let time) = self { return time }
        return nil
    }

    /// What the bar's menu offers besides coming back to it later, as it is now.
    static func offers(pr: PrRow?, acted: Bool) -> [ReviewSwipeOn] {
        Going.offered(Snooze.For.offered.map(ReviewSwipeOn.snooze), besides: .later) { Going.of($0, pr: pr, acted: acted) }
    }
}

extension Snooze.For {
    /// The times the menus offer now, in their order.
    static var offered: [Snooze.For] { allCases.filter { $0.choice() != nil } }
}

/// What going on from a page does to what it shows: what a swipe does, or what was picked from the
/// bar's menu (`SwipeOn` on a session's screen, `ReviewSwipeOn` on a PR's page), where that
/// applies. A session you've replied to or answered here is left to the turn you gave it, one at
/// work is left to its work (Mark as done would only be held by it), and one that waits on you to
/// allow a call or answer its questions comes round again after the rest, as it did before there
/// was a choice; a snooze picked for one is done whatever it waits on. A PR you reviewed here, or
/// one that doesn't wait on your review, is left as it is.
enum Going: Hashable {
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
        // Left as it is, one there was something to mark seen in still waits on you.
        case .keep: return row.seenable ? .later : .on
        case .seen: return row.seenable ? .seen : .on
        case .done: return row.status == .working ? .working : .done
        case .archive: return row.status == .working ? .working : row.archived ? .on : .archive
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

    /// It in the bar's menu, where picking it goes on.
    var title: String {
        switch self {
        case .seen: SwipeOn.seen.label
        case .done: SwipeOn.done.label
        case .archive: SwipeOn.archive.label
        case .on, .working: "Go on"
        case .later: "Come back to it later"
        case .snooze(let phrase): "Snooze \(phrase)"
        }
    }

    /// Of `picks`, what the bar's menu offers besides `swipe`, what a swipe does: the ones that do
    /// something else to it, each once, in their order. Mark as done or Archive on one at work, or
    /// any pick on one you've replied to here, would only go on as the swipe does.
    static func offered<Pick>(_ picks: [Pick], besides swipe: Pick, _ going: (Pick) -> Going) -> [Pick] {
        var does = [going(swipe)]
        return picks.filter { pick in
            let it = going(pick)
            guard it != .working, !does.contains(it) else { return false }
            does.append(it)
            return true
        }
    }
}

/// Over a session's reply box or a PR's review box while you go through what waits on you: what a
/// swipe does to this one, and how many more wait on you. The whole bar is one control: a tap
/// opens a menu of what can be done to it on the way, what a swipe does nearest, and picking one
/// does it and goes on, to the next or on the last to the end of what waits. With nothing else to
/// do to it (you've replied here, say), a tap goes on as a swipe does.
struct GoOnBar<Pick: GoOnPick>: View {
    let next: Onward
    /// How many wait on you after this one, the next among them.
    let left: Int
    /// What a swipe does to this one.
    let going: Going
    /// What else can be done to it on the way, in the menu's order (`Going.offered`).
    var offers: [Pick] = []
    /// Pick a time… under Snooze: asks for a time to snooze it to, then goes on.
    var pickTime: (() -> Void)?
    /// Does a pick to it and goes on; nil for what a swipe does.
    let go: (Pick?) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var symbolWidth: CGFloat = 22

    var body: some View {
        Group {
            if offers.isEmpty {
                Button { go(nil) } label: { pill(menu: false) }
                    .buttonStyle(.plain)
                    .accessibilityHint(next == .end ? "Goes on to the end of what waits on you" : "Goes on to the next")
            } else {
                Menu {
                    menu
                } label: {
                    pill(menu: true)
                }
                // What a swipe does nearest the finger, the menu opening up from the bar.
                .menuOrder(.priority)
                // A menu's label takes the tint: this one reads as the bar's words.
                .tint(.primary)
                .accessibilityHint("Opens what to do to it on the way to the next")
            }
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    private var menu: some View {
        Button(going.title, systemImage: going.symbol) { go(nil) }
        Divider()
        ForEach(offers.filter { $0.time == nil }, id: \.self) { pick in
            Button(pick.label, systemImage: pick.symbol) { go(pick) }
        }
        let snoozes = offers.filter { $0.time != nil }
        if !snoozes.isEmpty {
            Menu("Snooze", systemImage: "moon.zzz") {
                ForEach(snoozes, id: \.self) { pick in
                    Button(pick.time?.picked().label ?? pick.label) { go(pick) }
                }
                if let pickTime {
                    Button("Pick a time…", systemImage: "calendar", action: pickTime)
                }
            }
        }
    }

    private func pill(menu: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: going.symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(going.words)
                    .font(.subheadline.weight(.semibold))
                Text(count)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            // Up, where the menu opens; on, where a tap goes on.
            Image(systemName: menu ? "chevron.up" : "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect(cornerRadius: 22))
    }

    /// How many wait on you after this one.
    private var count: String {
        if next == .end { return "Nothing else waits on you" }
        return left == 1 ? "1 more waits on you" : "\(left) more wait on you"
    }
}
