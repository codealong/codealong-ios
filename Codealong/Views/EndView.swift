import SwiftUI

/// The end of what waits on you: going on from the last of it comes here, by a swipe, Finish over
/// the box, ⌘] or Send and finish, as the Mac's waiting window says nothing waits once you're
/// through. It says how the last one went, as the screen gone on to always does, and how many
/// sessions are at work. It isn't the end for long: what comes to wait on you while it's open is
/// offered over its foot, and a swipe or a tap goes on to it, as on any page. The one you went on
/// from to it isn't offered until it changes (a new turn, a new call to allow), though: marked
/// seen, it still waits until its Mac has that, and skipped, it would come straight back. Swiping
/// back goes to it.
struct EndView: View {
    /// Its key in the list's path, which no session's (`@<Mac>:<key>`) or PR's (`pr:`) can be.
    nonisolated static let key = "end"
    /// Shows another page in this one's place.
    var go: (String) -> Void = { _ in }
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The inbox's project: what's offered stays in it.
    @AppStorage("project") private var project = ""
    /// The page gone on from to this one, as it was then.
    @State private var left: Waiting?
    /// How the page gone on from went, and what a swipe did to it once its Mac answered.
    @State private var said: String?
    @State private var swipe = Swipe()
    /// The check has drawn in: it draws as the page takes the swipe's place.
    @State private var drawn = false

    init(left: Waiting?, go: @escaping (String) -> Void = { _ in }) {
        self.go = go
        _left = State(initialValue: left)
    }

    /// The page you went on from to this one, or before it, while it's still listed.
    private var before: Waiting? { store.previous(of: Self.key) }
    /// What's come to wait on you since, the next first.
    private var offer: [Waiting] {
        store.queue(after: Self.key, project: project).filter { !($0.key == left?.key && $0.stamp == left?.stamp) }
    }

    var body: some View {
        Paged(swipe: swipe, key: Self.key, next: offer.first.map(Onward.to), back: before, leaves: false, ready: true) {
            EndMessage(nothing: offer.isEmpty, drawn: drawn) { dismiss() }
                .contentShape(.rect)
                .gesture(QueueSwipe(back: before != nil, moved: { swipe.moved($0) }, ended: swiped))
                .safeAreaInset(edge: .bottom) {
                    EndFoot(offer: offer, said: said) { goOn(to: $0) }
                }
        }
        // What's come in is a swipe away; on a keyboard, ⌘] as on the Mac.
        .background {
            if let next = offer.first {
                // Unseen, at no size: one that takes no touches takes no keys either.
                Button("Next") { goOn(to: next) }
                    .keyboardShortcut("]", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TitleBlock(key: swipe.to?.key ?? Self.key)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ImproveButton()
            }
        }
        .onAppear {
            store.showing = Self.key
            if let outcome = store.outcome {
                said = outcome
                store.outcome = nil
            }
            takeLateOutcome()
        }
        // After its first frame, which the glance it takes the place of drew without the check.
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            drawn = true
        }
        .onDisappear {
            if store.showing == Self.key { store.showing = nil }
        }
        .onChange(of: store.lateOutcomes) { _, _ in takeLateOutcome() }
        // You're through: felt as the check draws, not when something new is what's here.
        .sensoryFeedback(.success, trigger: drawn) { _, now in now && offer.isEmpty }
    }

    /// A swipe let go: far or fast enough toward what's that way, it slides there; otherwise the
    /// page settles back.
    private func swiped(_ distance: CGFloat, _ speed: CGFloat) {
        let ahead = distance < 0
        let target = ahead ? offer.first : distance > 0 ? before : nil
        guard swipe.letGo(distance, speed, toward: target != nil), let target else { return }
        if ahead {
            goOn(to: target, speed: speed)
        } else {
            store.outcome = nil
            slide(to: target.key, back: true, speed: speed) { store.back(to: target.key) }
        }
    }

    /// Goes on to what's come in, as from any page: there's nothing here to mark or pass over,
    /// and it's left off the trail, so swiping back from there goes to what you were on before.
    private func goOn(to next: Waiting, speed: CGFloat = 0) {
        guard swipe.to == nil else { return }
        store.outcome = nil
        slide(to: next.key, back: false, speed: speed)
    }

    /// Slides this page away and `target`'s in after it, then does `then` and shows `target` in
    /// its place, starting as it was drawn sliding in.
    private func slide(to target: String, back: Bool, speed: CGFloat = 0, then: @escaping () -> Void = {}) {
        if !target.hasPrefix(PrView.prefix) {
            store.slidIn = (target, Opening(kept: swipe.kept[target] ?? Kept(), said: nil))
        }
        swipe.slide(to: target, back: back, speed: speed, reduceMotion: reduceMotion, go: go, then: then)
    }

    /// Says how what a swipe did to what was gone on from went, once its Mac has answered, unless
    /// this page is sliding away: the one sliding in says it.
    private func takeLateOutcome() {
        guard !store.lateOutcomes.isEmpty, store.showing == Self.key, swipe.to == nil else { return }
        said = store.lateOutcomes.joined(separator: "\n")
        store.lateOutcomes = []
    }
}

/// The end of what waits beside the page shown, as a swipe brings it in: drawn as its page first
/// draws it, the check not yet drawn in.
struct EndGlance: View {
    /// How the page gone on from went, as this one will say it.
    let said: String?
    /// The page a swipe goes on from to this one, which it doesn't offer.
    let from: String?
    @Environment(Store.self) private var store
    @AppStorage("project") private var project = ""

    var body: some View {
        let offer = store.queue(after: EndView.key, project: project).filter { $0.key != from }
        EndMessage(nothing: offer.isEmpty, drawn: false) {}
            .safeAreaInset(edge: .bottom) {
                EndFoot(offer: offer, said: said) { _ in }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// What the end of what waits says: nothing else waits, with how many sessions are at work and
/// what shows up here; or that something new does, which its foot offers.
private struct EndMessage: View {
    let nothing: Bool
    let drawn: Bool
    let back: () -> Void
    @Environment(Store.self) private var store
    @AppStorage("project") private var project = ""

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(nothing ? "Nothing else waits on you" : "Something new waits on you")
            } icon: {
                Image(systemName: nothing ? "checkmark.circle" : "tray.and.arrow.down")
                    .symbolEffect(.drawOn, isActive: nothing && !drawn)
            }
        } description: {
            if let words {
                Text(words)
            }
        } actions: {
            Button("Back to the list", action: back)
                .buttonStyle(.glass)
        }
    }

    /// How many sessions are at work (the core's count, as the list's note has it), and with
    /// nothing waiting, that what does will show up here.
    private var words: String? {
        let working = store.quick(project: project, query: "", said: [], ranked: []).working
        let atWork: String? = switch working {
        case 0: nil
        case 1: "1 session is working."
        default: "\(working) sessions are working."
        }
        let comes = nothing ? "What waits on you next shows up here as it comes." : nil
        let both = [atWork, comes].compactMap { $0 }
        return both.isEmpty ? nil : both.joined(separator: " ")
    }
}

/// Over the end page's foot: how the page gone on from went, as any page gone on to says it, and
/// what's come to wait on you since, to go on to.
private struct EndFoot: View {
    let offer: [Waiting]
    let said: String?
    let goOn: (Waiting) -> Void
    @Environment(Store.self) private var store
    @AppStorage("project") private var project = ""

    var body: some View {
        VStack(spacing: 8) {
            if let said {
                Text(said).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let next = offer.first {
                GoOnBar(next: .to(next), more: offer.count - 1, showDevice: store.devices.count > 1, showProject: project.isEmpty, going: .on, picked: "", picks: false, choices: { EmptyView() }) { goOn(next) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(.snappy, value: offer.first?.key)
    }
}
