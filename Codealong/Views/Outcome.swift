import SwiftUI

/// How the page you went on from went, said on the one you went on to in a line of its own: what
/// was done to it, with a mark for that, by its name. One that went as asked is said for a moment,
/// as the Mac's queue says it (useWaitingQueue.ts `NOTICE_MS`), and goes sooner once you write or
/// scroll: left there, under the next session's own notes, it read as that session's. One that
/// didn't stays until something else is said, since you need to know why it comes round again.
/// What its Mac said of it in full (all that Mark as done ended and cleaned up) is a tap away.
struct Outcome: Equatable, Identifiable {
    enum Mark: Equatable {
        case done
        case archived
        case snoozed
        /// A reply, an answer or a review went, or is on its way.
        case sent
        /// Its Mac hasn't said yet how it went.
        case waiting
        /// It didn't go as asked, or went with something its Mac noted (still open on another
        /// Mac, say).
        case problem
        /// What a page you acted on said after that.
        case note
    }

    let mark: Mark
    let words: String
    /// Its Mac's whole account, shown in place of `words` once it's opened.
    var full: String?
    var fades = true
    /// Opened, it stays until something else is said.
    var open = false
    /// Each its own, so one said again with the same words has its own moment.
    let id = UUID()

    init(_ mark: Mark, _ words: String, full: String? = nil, fades: Bool = true) {
        self.mark = mark
        self.words = words
        self.full = full
        self.fades = fades
    }

    static let shown = Duration.seconds(4)

    /// One that didn't go as asked, said in full until something else is.
    static func problem(_ words: String) -> Outcome { Outcome(.problem, words, fades: false) }

    /// Marked done, as its Mac answered: by its name alone where it all went as asked, with its
    /// Mac's account of what ended and was cleaned up a tap away; in its Mac's words where work
    /// under way held it, or its Mac noted something.
    static func done(_ done: DoneOutcome, title: String) -> Outcome {
        if !done.done { return .problem("\(done.message) It wasn’t marked done.") }
        if done.noted { return .problem(done.message) }
        return Outcome(.done, "Done with “\(title)”.", full: done.message)
    }
}

/// Mark as done's question about a session's helpers whose work isn't over, as the Mac's dialog
/// asks it (DoneHelpers.tsx): make them your own, the answer a plain yes gives, or end them too.
/// `asked` is what it's about while it's up; `answer` marks it done as answered.
struct DoneHelpersDialog<Asked>: ViewModifier {
    @Binding var asked: Asked?
    let ask: (Asked) -> DoneHelpersAsk
    let answer: (Asked, HelpersAnswer) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(asked.map(ask)?.title ?? "", isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } }), titleVisibility: .visible, presenting: asked) { a in
            let q = ask(a)
            let shown = q.helpers.map(\.key)
            Button(q.keep) { answer(a, HelpersAnswer(shown: shown, end: false)) }
            Button(q.end, role: .destructive) { answer(a, HelpersAnswer(shown: shown, end: true)) }
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(ask(a).message(now: .now))
        }
    }
}

extension DoneHelpersAsk {
    /// What Mark as done's question says under its title: what each answer does, then each
    /// helper, where it stands and its account, as the Mac's dialog lists them.
    func message(now: Date) -> String {
        let lines = helpers.map { "\($0.title): \(String(Clock.text($0.stands, now: now).characters))" }
        return ([lede, ""] + lines).joined(separator: "\n")
    }
}

/// How the pages gone on from went, a line each (`Outcome`). One that fades goes after its moment
/// unless it's open, and has another once it's closed; one that stays goes when you dismiss it.
/// With `fading` off (the end of what waits, which keeps them until something waits again, and a
/// glance, drawn as its page first draws them) none goes by itself.
struct OutcomeLines: View {
    @Binding var outcomes: [Outcome]
    var fading = true

    var body: some View {
        if !outcomes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(outcomes) { outcome in
                    let id = outcome.id
                    let gone = { withAnimation(.snappy) { outcomes.removeAll { $0.id == id } } }
                    OutcomeLine(outcome: outcome, dismiss: outcome.fades ? nil : gone) {
                        guard let at = outcomes.firstIndex(where: { $0.id == id }) else { return }
                        withAnimation(.snappy) { outcomes[at].open.toggle() }
                    }
                    .task(id: "\(id) \(outcome.open)") {
                        guard fading, outcome.fades, !outcome.open else { return }
                        try? await Task.sleep(for: Outcome.shown)
                        guard !Task.isCancelled else { return }
                        withAnimation(.snappy) { outcomes.removeAll { $0.id == id } }
                    }
                }
            }
            .transition(.opacity)
        }
    }
}

extension [Outcome] {
    /// Lets go of the ones that fade and haven't been opened: you've gone on to write or scroll.
    mutating func letGo() {
        guard contains(where: { $0.fades && !$0.open }) else { return }
        withAnimation(.snappy) { removeAll { $0.fades && !$0.open } }
    }
}

extension View {
    /// Lets go of how the page before went (`outcomes`) as the page says something itself
    /// (`said`), which takes its place, and of the ones that fade as you write there (`draft`),
    /// in a draft kept from before too.
    func lettingGo(of outcomes: Binding<[Outcome]>, saying said: String?, writing draft: String) -> some View {
        onChange(of: said) { _, now in if now != nil { outcomes.wrappedValue = [] } }
            .onChange(of: draft) { _, now in if !now.isEmpty { outcomes.wrappedValue.letGo() } }
    }
}

/// One page's outcome: its mark and a line, cut short where it's long, which a tap opens to all its
/// Mac said and another closes. One that stays is said in full, since it says what didn't go, with
/// a cross to dismiss it.
private struct OutcomeLine: View {
    let outcome: Outcome
    let dismiss: (() -> Void)?
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: toggle) {
                Label {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(outcome.open ? outcome.full ?? outcome.words : outcome.words)
                            .lineLimit(outcome.fades && !outcome.open ? 1 : nil)
                        if outcome.full != nil {
                            Image(systemName: "chevron.down")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(outcome.open ? 180 : 0))
                        }
                        Spacer(minLength: 0)
                    }
                } icon: {
                    mark
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(outcome.full == nil ? "" : outcome.open ? "Shows less" : "Shows all its Mac said")
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
                    .contentShape(.rect.inset(by: -8))
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var mark: some View {
        switch outcome.mark {
        case .waiting:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .archived:
            Image(systemName: SwipeOn.archive.symbol)
        case .snoozed:
            Image(systemName: "moon.zzz")
        case .sent:
            Image(systemName: "arrow.up.circle")
        case .note:
            Image(systemName: "info.circle")
        }
    }
}
