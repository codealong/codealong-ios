import SwiftUI

/// A session's screen or a PR's page, going along what waits on you: the page follows a swipe
/// across it (`QueueSwipe`, which the page puts on what it scrolls), and the page it goes to comes
/// in beside it, the next from the right and the one you came from from the left, drawn as its
/// own page first draws it (`Glance`). The page decides where a swipe let go goes and what it does
/// on the way (`Swipe.letGo`, `Swipe.slide`).
struct Paged<Page: View>: View {
    let swipe: Swipe
    /// The page's key in the list's path.
    let key: String
    /// What waits on you next, and what you came from: where a swipe goes.
    let next: Waiting?
    let back: Waiting?
    /// Going on takes this page out of what waits on you (marked done or archived, say), so the
    /// next page's own next leaves it out; otherwise it comes round again after the rest.
    let leaves: Bool
    /// The page has read what it shows: what's beside it is read after, not to hold that up.
    let ready: Bool
    @ViewBuilder let page: Page
    @Environment(Store.self) private var store

    var body: some View {
        // Side by side in a stack, so the page beside it sits in the same safe area and lines up
        // with it.
        ZStack {
            besides
            page.modifier(FollowsSwipe(swipe: swipe, next: nextKey != nil, back: backKey != nil))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { swipe.width = $0 }
        // What's beside it, read ahead so it slides in as it is: again as what's next changes (one
        // answered elsewhere, a new one waiting) or moves.
        .task(id: reads) { await read() }
    }

    /// The pages a swipe goes to; once it's sliding, the one it slides to on its side. The other
    /// stays as it was: one going away as the slide began moved the page's own slide onto the one
    /// coming in.
    private var nextKey: String? { swipe.to.flatMap { $0.back ? nil : $0.key } ?? next?.key }
    private var backKey: String? { swipe.to.flatMap { $0.back ? $0.key : nil } ?? back?.key }

    @ViewBuilder
    private var besides: some View {
        let next = nextKey, back = backKey
        ZStack {
            if let next {
                Glance(key: next, kept: swipe.kept[next], said: swipe.to?.key == next ? store.outcome : nil, from: (key, leaves: leaves))
                    .modifier(FollowsSwipe(swipe: swipe, next: true, back: back != nil, at: 1))
            }
            if let back {
                Glance(key: back, kept: swipe.kept[back], said: swipe.to?.key == back ? store.outcome : nil)
                    .modifier(FollowsSwipe(swipe: swipe, next: next != nil, back: true, at: -1))
            }
        }
    }

    /// What `read` reads for: what's beside the page, and when the next last moved.
    private var reads: String {
        guard ready else { return "" }
        return "\(next.map { "\($0.key)@\($0.stamp)" } ?? "")|\(back?.key ?? "")"
    }

    /// Reads what's beside the page: the next from its Mac first when it hasn't been lately, so it
    /// slides in as it is. A session's conversation is kept here; a PR's page in the store.
    private func read() async {
        guard ready else { return }
        var kept: [String: Kept] = [:]
        for (waiting, fresh) in [(back, false), (next, true)] {
            switch waiting {
            case .session(let row): kept[row.key] = await store.kept(row.key, read: fresh)
            case .pr(let pr): if fresh { await store.readAhead(pr) }
            case nil: break
            }
        }
        // Not while it slides: the one sliding in stays as it was drawn.
        guard swipe.to == nil, !Task.isCancelled else { return }
        swipe.kept = kept
    }
}

/// What waits on you beside the page shown, as a swipe brings it in: a session or a PR, drawn as
/// its own page first draws it, so the page takes its place without a change.
struct Glance: View {
    let key: String
    /// What the phone keeps of a session's conversation.
    let kept: Kept?
    /// How the page gone on from went, as this one will say it.
    let said: String?
    /// The page a swipe goes on from to this one, and whether that leaves what waits on you: nil
    /// going back to one.
    var from: (key: String, leaves: Bool)?

    var body: some View {
        if key.hasPrefix(PrView.prefix) {
            PrGlance(key: String(key.dropFirst(PrView.prefix.count)), said: said, from: from)
        } else {
            SessionGlance(key: key, kept: kept ?? Kept(), said: said, from: from)
        }
    }
}

/// What waits on a page's next page after it, as that page will have it once a swipe has gone on
/// to it: the page gone on from left out when going on took it out of what waits on you, else
/// after the rest.
@MainActor
func waitingAfter(_ key: String, from: (key: String, leaves: Bool)?, store: Store, project: String) -> [Waiting] {
    let queue = store.queue(after: key, project: project)
    guard let from else { return queue }
    let rest = queue.filter { $0.key != from.key }
    return from.leaves ? rest : rest + queue.filter { $0.key == from.key }
}

/// What a page is called in its bar: a session's title with its emblem, and its Mac and project
/// under it; a PR's number. Sliding to another, the page names that one: its own takes a moment to
/// draw once the slide is over.
struct TitleBlock: View {
    let key: String
    @Environment(Store.self) private var store

    var body: some View {
        switch store.waiting(key) {
        case .pr(let pr):
            // Verbatim: a localized number would be written #1,244.
            Text(verbatim: "#\(pr.number)").font(.headline)
        case .session(let row):
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if let emblem = row.emblem {
                        EmblemView(emblem: emblem, size: 18)
                    }
                    Text(row.title).font(.headline).lineLimit(1)
                }
                Text("\(Names.short(row.deviceName)) · \(row.project)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        case nil:
            Text(key.hasPrefix(PrView.prefix) ? "PR" : "Session").font(.headline)
        }
    }
}

/// A swipe across a page, kept apart from what's drawn: it changes every frame, and only where the
/// page and the pages beside it sit should redraw, not what's on them.
@MainActor @Observable final class Swipe {
    /// How far it's gone, negative to the left.
    var distance: CGFloat = 0
    /// The pages beside this one are drawn: a swipe is under way, or settling back. Otherwise
    /// they're left out, so iOS's own slide to and from the list doesn't show them.
    var showing = false
    /// How wide the screen is: sliding to another goes this far.
    var width: CGFloat = 0
    /// The page it slides to, once let go far enough or gone on to by a button.
    var to: Slide?
    /// What the phone keeps of the sessions beside the page, by key, read once the page is open.
    var kept: [String: Kept] = [:]

    /// The finger moved, this far from where the swipe began.
    func moved(_ distance: CGFloat) {
        guard to == nil else { return }
        showing = true
        self.distance = distance
    }

    /// A swipe let go: whether it went far or fast enough to go to what's that way (`toward`,
    /// there is something), which the page then slides to; otherwise the page settles back. A
    /// flick back the way it came settles it, however far it went.
    func letGo(_ distance: CGFloat, _ speed: CGFloat, toward: Bool) -> Bool {
        guard to == nil else { return false }
        let away = abs(speed) > 300 && (speed < 0) != (distance < 0)
        let far = !away && (abs(distance) >= width * 0.3 || (abs(distance) > 30 && abs(speed) > 500))
        if far && toward { return true }
        withAnimation(motion(to: 0, speed: speed)) { self.distance = 0 } completion: { [self] in
            if self.distance == 0 && to == nil { showing = false }
        }
        return false
    }

    /// Slides the page away and `target`'s in after it, then does `then` and shows `target` in its
    /// place (`go`), already where it slid to. Gone on to by a button with Reduce Motion on, it's
    /// shown in this one's place at once.
    func slide(to target: String, back: Bool, speed: CGFloat, reduceMotion: Bool, go: @escaping (String) -> Void, then: @escaping () -> Void) {
        guard width > 0, !reduceMotion || distance != 0 else {
            then()
            go(target)
            return
        }
        let end = back ? width : -width
        // All in one change: drawn between a change to where it slides and the slide itself, the
        // page stayed where the finger left it while the one beside it slid over it.
        withAnimation(motion(to: end, speed: speed)) {
            to = Slide(key: target, back: back)
            showing = true
            distance = end
        } completion: {
            then()
            // Already where it slid to: it takes the slide's place without moving again.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { go(target) }
        }
    }

    /// Where the page sits for the swipe: with the finger toward a page beside it; where there's
    /// none, held back more the further it goes, as a scroll view is past its end.
    func offset(next: Bool, back: Bool) -> CGFloat {
        if to != nil || (distance < 0 ? next : back) { return distance }
        guard width > 0 else { return 0 }
        let held = (1 - 1 / (abs(distance) * 0.55 / width + 1)) * width
        return distance < 0 ? -held : held
    }

    /// A curve to `end` that carries on at the speed the finger let go at and eases to a stop,
    /// ending as it looks to end: the page's own screen takes the slide's place then, where a
    /// spring said it was done a quarter of a second after it stopped moving.
    func motion(to end: CGFloat, speed: CGFloat) -> Animation {
        let left = end - distance
        guard abs(left) >= 1 else { return .easeOut(duration: 0.1) }
        // Quicker for a flick, never slower than a third of a second.
        let duration = min(max(abs(left) / max(abs(speed), 1) * 2, 0.18), 0.3)
        // How steeply it starts: the finger's speed toward the end, as a share of the move over
        // its duration; let go still, or from a button, it starts briskly anyway.
        let slope = max(max(speed / left, 0) * duration, 1.6)
        return .timingCurve(0.25, min(0.25 * slope, 1), 0.3, 1, duration: duration)
    }
}

/// Where a swipe let go goes: the next, or back to the page you came from.
struct Slide: Equatable {
    let key: String
    let back: Bool
}

/// Puts a page where a swipe has it: the page's own at 0, the ones beside it a screen to the right
/// (1) or the left (-1), drawn only while a swipe shows them.
struct FollowsSwipe: ViewModifier {
    let swipe: Swipe
    /// There's a page that way to go to.
    let next: Bool
    let back: Bool
    var at: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: swipe.offset(next: next, back: back) + at * swipe.width)
            .opacity(at == 0 || swipe.showing ? 1 : 0)
    }
}
