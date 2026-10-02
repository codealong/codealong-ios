import SwiftUI

/// One session: its conversation, what it waits on you to allow, and a box to reply. It follows the
/// session as it goes: a change in the Mac's feed brings in what came since.
///
/// It also works through what waits on you, as the Mac's session panel does with ⌘⏎: once you've
/// replied or answered, the most urgent session still waiting on you is a tap away above the box,
/// and holding Send sends and goes on at once. The chevron at the top skips to it; one skipped
/// comes round again after the rest.
///
/// As on the Mac, it opens at the newest and reads older pages as you scroll up, holding your
/// place. The prompt behind what's in view, once it's gone off the top, stays pinned there, two
/// lines of it, so what you asked stays in mind while you read what came of it; a tap brings it
/// up. A long turn can write more than a page, so when the first page doesn't start with a prompt,
/// the core reads back for the one before it, and it's pinned from the start.
struct SessionView: View {
    let key: String
    /// Shows another session in this one's place.
    var go: (String) -> Void = { _ in }
    @Environment(Store.self) private var store
    /// The inbox's project: what's next stays in it.
    @AppStorage("project") private var project = ""
    /// You replied or answered here, so what's next is offered.
    @State private var acted = false
    @Environment(\.dismiss) private var dismiss
    @State private var conversation: Conversation?
    @State private var items: [Item] = []
    @State private var hasOlder = false
    @State private var loadingOlder = false
    /// Your prompt before the pages read, when the first doesn't start with one.
    @State private var earlier: Item?
    /// Where each of your prompts read so far is against the top of what's in view. Kept as where
    /// they are on screen, not in the conversation, so a page going in above changes nothing.
    @State private var promptPlaces: [String: PromptPlace] = [:]
    /// Where what's in view starts on screen, below the bars: the top your prompts go off.
    @State private var viewTop: CGFloat = 0
    /// Moves the conversation to hold your place as a page goes in above.
    @State private var position = ScrollPosition(edge: .bottom)
    /// The prompt pinned over the top of the conversation.
    @State private var pinned: String?
    /// Where it's scrolled to, kept apart from what's drawn: it changes every frame of a scroll, and
    /// only what it means (a page to read, a prompt to pin) should redraw.
    @State private var scroll = ScrollSpot()
    @State private var pending: Pending?
    /// An answer on its way to the Mac: the card takes no other until it's there, so a second tap
    /// can't send another whose failure hides how the first went.
    @State private var answering: Choice?
    /// The call last answered here. The Mac can still say it waits on it for a moment after, and
    /// it isn't offered again.
    @State private var answered: String?
    @State private var problem: String?
    @State private var loading = true
    @State private var draft = ""
    @State private var sending = false
    @State private var said: String?
    /// The reply it's writing, while it takes a turn Codealong runs on its Mac.
    @State private var live: Live?
    @State private var watching = false
    @State private var stopping = false
    /// Scrolled to the newest: new items keep it there. Scrolled up to read, it stays put.
    @State private var atBottom = true
    @FocusState private var typing: Bool
    /// The send button's size, which a line of the reply box matches; it grows with the text size.
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32
    /// Between the send button and the reply box's edge.
    private let replyInset: CGFloat = 6
    /// Reads the page before once you're this close to the top, so it's usually in before you
    /// get there: a page comes from the Mac, which can take a moment.
    private let nearTop: CGFloat = 900

    private var row: SessionRow? { store.sessions.first { $0.key == key } }
    /// What waits on you after this one; the first is next.
    private var after: [SessionRow] { store.queue(after: key, project: project) }

    /// The conversation as it reads: what was said, and each run of tool calls between as one.
    private var entries: [Entry] {
        var out: [Entry] = []
        var run: [Item] = []
        for item in items {
            if item.kind == .tool {
                run.append(item)
                continue
            }
            if !run.isEmpty { out.append(.tools(run)) }
            run = []
            out.append(.said(item))
        }
        if !run.isEmpty { out.append(.tools(run)) }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack scrolled to its end by the bottom anchor or `scrollTo` goes
                // by row heights it guessed, and on a phone it could stop there with no rows built
                // for what's on screen, a blank page until you dragged it. What's shown is the pages
                // of 60 items read so far, a few unless you scroll a long way back.
                VStack(alignment: .leading, spacing: 14) {
                    if hasOlder {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Loading earlier")
                    } else if !loading && !items.isEmpty {
                        Text("The start of the session")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(entries) { entry in
                        switch entry {
                        case .said(let item) where item.kind == .you:
                            ItemView(item: item)
                                .onGeometryChange(for: PromptPlace.self) { [viewTop] geo in
                                    PromptPlace(geo.frame(in: .global), top: viewTop)
                                } action: { place in
                                    promptPlaces[item.id] = place
                                }
                                .id(item.id)
                        case .said(let item): ItemView(item: item)
                        case .tools(let calls): ToolRun(calls: calls)
                        }
                    }
                    if let live {
                        LiveReply(live: live)
                    }
                    if loading && items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, now in
                atBottom = now
            }
            // The top of what's in view, below the bars, in the conversation's coordinates. Its
            // height goes with it: a page too short to scroll is near the top without moving.
            .onScrollGeometryChange(for: ScrollSpot.Place.self) { geo in
                .init(offset: geo.contentOffset.y, inset: geo.contentInsets.top, height: geo.contentSize.height)
            } action: { was, place in
                scrolled(from: was, to: place)
            }
            // A page that went in above while it scrolled goes in once it's still.
            .onScrollPhaseChange { _, phase in
                scroll.still = phase == .idle
                if scroll.still, let waiting = scroll.waiting { show(waiting) }
            }
            .onChange(of: items.count) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: live?.text) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: promptPlaces) { _, _ in repin() }
            .onChange(of: earlier?.id) { _, _ in repin() }
            // Takes no room: it floats over the top of the conversation while it has a prompt.
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { viewTop = $0 }
                    if let prompt = pinnedPrompt {
                        PinnedPrompt(text: prompt.text) {
                            Task { await bringUp(prompt.id, proxy: proxy) }
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: pinned)
            }
        }
        .safeAreaInset(edge: .bottom) { bottom }
        .navigationTitle(row?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(row?.title ?? "Session").font(.headline).lineLimit(1)
                    if let row {
                        Text("\(Names.short(row.deviceName)) · \(row.project)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if let next = after.first {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { moveOn(to: next) } label: {
                        Label("Next", systemImage: "chevron.down")
                    }
                    .keyboardShortcut("]", modifiers: .command)
                    .accessibilityLabel("Next that waits on you: \(next.title)")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canStop {
                        Button("Stop", systemImage: "stop.circle") { Task { await stop() } }
                    }
                    Button("Archive", systemImage: "archivebox") {
                        store.archive(key)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: key) { await open() }
        // The Mac's feed says the session moved: bring in what came since.
        .onChange(of: row?.lastActivity) { _, _ in Task { await refresh() } }
        // A turn that ends while it's shown here has been seen.
        .onChange(of: row?.status) { _, status in
            if status == .unread { store.markSeen(key) }
        }
        // A reply being written comes as a change the core reports.
        .onChange(of: store.tick) { _, _ in
            guard watching, let conv = conversation else { return }
            let now = conv.live()
            // The turn ended: the reply stays up until the conversation has it, so the list never
            // shrinks under where it's scrolled to.
            if now == nil, live != nil {
                Task {
                    await refresh()
                    live = conv.live()
                }
            } else {
                live = now
            }
        }
        .onDisappear {
            if watching, let conv = conversation {
                Task.detached { conv.unwatch() }
            }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 8) {
            if let pending {
                ApprovalCard(pending: pending, canAct: canAct, why: whyNot, answering: answering) { choice in
                    Task { await answer(pending, choice) }
                }
            }
            if canStop {
                Button(role: .destructive) {
                    Task { await stop() }
                } label: {
                    Label(stopping ? "Stopping…" : "Stop this turn", systemImage: "stop.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(stopping)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let said {
                Text(said).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if acted, let next = after.first {
                NextButton(next: next, more: after.count - 1, showDevice: store.devices.count > 1, showProject: project.isEmpty) { moveOn(to: next) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // The reply box floats over the conversation in glass, as a control, not a bar. A line
            // of text is as tall as the send button, so the button sits centered in the pill, and
            // as the text grows it stays at the bottom, as far from the edges as before.
            HStack(alignment: .bottom, spacing: 8) {
                TextField(canAct ? "Reply" : (whyNot ?? "Reply"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .disabled(!canAct || sending)
                    .frame(minHeight: sendSize)
                    // ⌘⏎ on a keyboard sends and goes on, as on the Mac.
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command), canSend else { return .ignored }
                        Task { await send(thenNext: true) }
                        return .handled
                    }
                Button {
                    Task { await send() }
                } label: {
                    // Accent while there's something to send, a quiet grey while there isn't.
                    let ready = canSend || sending
                    ZStack {
                        Circle().fill(ready ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        if sending {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: sendSize / 2, weight: .bold))
                                .foregroundStyle(ready ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        }
                    }
                    .frame(width: sendSize, height: sendSize)
                    // The margin around it takes a tap too.
                    .contentShape(.circle.inset(by: -replyInset))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                // Held, as Messages offers its send options: send and go straight on.
                .contextMenu {
                    if let next = after.first {
                        Button {
                            Task { await send(thenNext: true) }
                        } label: {
                            Label("Send and go to next", systemImage: "arrow.forward")
                            Text(next.title)
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, replyInset)
            .padding(.vertical, replyInset)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: sendSize / 2 + replyInset))
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    /// Only a Mac with remote control on takes a reply or an answer from here.
    private var canAct: Bool { whyNot == nil }

    private var canSend: Bool { canAct && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A turn Codealong runs on its Mac can be stopped from here.
    private var canStop: Bool { canAct && row?.hosted == true && row?.status == .working }

    private var whyNot: String? {
        guard let row, let device = store.devices.first(where: { $0.key == row.device }) else { return "That session isn't on a linked Mac any more" }
        if !device.online { return "\(device.name) isn't connected" }
        if !device.remoteControl { return "Remote control is off on \(device.name)" }
        return nil
    }

    private func open() async {
        guard conversation == nil, let conv = store.conversation(key) else { return }
        conversation = conv
        // Moved on to from another: say how that one went.
        if let outcome = store.outcome {
            said = outcome
            store.outcome = nil
        }
        await refresh()
        loading = false
        if row?.status == .unread { store.markSeen(key) }
        // A turn longer than the first page: the prompt behind it, to pin from the start.
        await lookBack()
        // A session Codealong runs sends its reply as it's written, while it's shown here.
        if row?.hosted == true {
            watching = await Task.detached { conv.watch() }.value
            live = conv.live()
        }
    }

    private func refresh() async {
        guard let conv = conversation else { return }
        do {
            show(try await Task.detached { try conv.refresh() }.value)
            problem = nil
        } catch {
            problem = words(error)
        }
        // What it waits on you for comes from the Mac only when it's waiting.
        if row?.status == .needs {
            let now = try? await Task.detached { try conv.pending() }.value
            pending = now?.id == answered ? nil : now
        } else {
            pending = nil
        }
    }

    /// The scroll view moved, or what's in it changed size.
    private func scrolled(from was: ScrollSpot.Place, to place: ScrollSpot.Place) {
        scroll.top = place.top
        // A page went in above: what's in view moves down with it, so it holds still. At the end,
        // or in a conversation shorter than the screen, the scroll view has done it already. By the
        // offset, not `top`: a short conversation sits at the bottom by a top inset that changes
        // with its height. (A position's y is `top`, the offset with the inset.)
        switch scroll.hold {
        case .pageIn where place.height != was.height:
            let short = (place.height - was.height) - (place.offset - was.offset)
            if abs(short) > 0.5 {
                scroll.hold = .scrolling(to: place.top + short)
                position.scrollTo(y: place.top + short)
                scroll.top += short
            } else {
                scroll.hold = .none
                repin()
            }
        case .scrolling(let to) where abs(place.top - to) < 1:
            scroll.hold = .none
            // After this layout's prompts have said where they are, which comes after this.
            Task { repin() }
        default:
            break
        }
        readOlderIfNear()
    }

    /// Reads the page before what's read.
    private func older() async {
        guard let conv = conversation, hasOlder, !loadingOlder, scroll.waiting == nil else { return }
        loadingOlder = true
        let all = try? await Task.detached { try conv.older() }.value
        loadingOlder = false
        guard let all else { return }
        show(all)
        // Still near the top, or too short to scroll up at all: the page before that too.
        readOlderIfNear()
    }

    /// Shows the conversation as the core has it now. A page that went in above waits for the
    /// scroll view to be still: moved while it scrolls, what's in view would jump back with the
    /// scroll's own motion. Once in, the geometry action holds what's in view where it was.
    private func show(_ all: [Item]) {
        guard let conv = conversation else { return }
        let above = !items.isEmpty && all.first?.id != items.first?.id
        if above && !scroll.still {
            scroll.waiting = all
            return
        }
        scroll.waiting = nil
        if above {
            scroll.hold = .pageIn
            // A page that changes no height (calls folded into a run already shown) has nothing
            // to hold.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if scroll.hold != .none {
                    scroll.hold = .none
                    repin()
                }
            }
        }
        items = all
        hasOlder = conv.hasOlder()
        if above { Task { await lookBack() } }
    }

    /// Your prompt before the pages read, when what's read doesn't start with one, to pin while
    /// you read what came of it. The core keeps the pages it reads for scrolling up.
    private func lookBack() async {
        guard let conv = conversation, hasOlder, let first = items.first, first.kind != .you else {
            earlier = nil
            return
        }
        let found = try? await Task.detached { try conv.promptBefore() }.value
        // A page read meanwhile asks again for its own.
        if items.first?.id == first.id { earlier = found }
    }

    private func readOlderIfNear() {
        // Once the scroll view has laid out what's read: until then it doesn't know where it is.
        guard hasOlder, !loadingOlder, scroll.waiting == nil, scroll.hold == .none, !items.isEmpty, scroll.top < nearTop else { return }
        Task { await older() }
    }

    /// Your prompt pinned over the top: one read, or the one before the pages read.
    private var pinnedPrompt: Item? {
        guard let pinned else { return nil }
        if earlier?.id == pinned { return earlier }
        return items.first { $0.id == pinned }
    }

    /// Pins the prompt behind what's in view once the whole of it is above the top: the latest that
    /// starts above it, unless it's still partly in view; with none read up there, the one before
    /// the pages read.
    private func repin() {
        // Until the page going in above is held, your prompts are measured where it pushed them.
        guard scroll.hold == .none else { return }
        let behind = items.last { $0.kind == .you && (promptPlaces[$0.id] ?? .below) != .below }
        let next: String?
        if let behind {
            next = promptPlaces[behind.id] == .gone ? behind.id : nil
        } else if let earlier, !items.contains(where: { $0.id == earlier.id }) {
            next = earlier.id
        } else {
            next = nil
        }
        if next != pinned { pinned = next }
    }

    /// Brings one of your prompts to the top of the view, reading back to it when it's before the
    /// pages read.
    private func bringUp(_ id: String, proxy: ScrollViewProxy) async {
        while !items.contains(where: { $0.id == id }) || scroll.hold != .none {
            // A page already on its way, waiting for the scroll to stop or being held comes first.
            if loadingOlder || scroll.waiting != nil || scroll.hold != .none {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let had = items.count
            await older()
            if items.count == had && scroll.waiting == nil { return }
        }
        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
    }

    /// Sends the box; with `thenNext`, goes on to what waits on you once it's gone. One that
    /// fails stays, saying why.
    private func send(thenNext: Bool = false) async {
        guard let conv = conversation else { return }
        let text = draft
        sending = true
        defer { sending = false }
        do {
            let result = try await Task.detached { try conv.send(text: text) }.value
            draft = ""
            typing = false
            done(result, outcome: "Sent to “\(title)”.", thenNext: thenNext)
        } catch {
            said = words(error)
        }
    }

    private func answer(_ p: Pending, _ choice: Choice) async {
        guard let conv = conversation, answering == nil else { return }
        answering = choice
        defer { answering = nil }
        do {
            let result = try await Task.detached { try conv.answer(id: p.id, choice: choice) }.value
            answered = p.id
            pending = nil
            done(result, outcome: choice == .deny ? "Denied “\(title)”." : "Allowed “\(title)” to go on.")
        } catch {
            said = words(error)
        }
    }

    /// A reply or an answer went: this one is dealt with until it waits on you anew, and what's
    /// next is offered, or gone on to.
    private func done(_ result: String, outcome: String, thenNext: Bool = false) {
        store.dealtWith(key)
        if thenNext, let next = after.first {
            moveOn(to: next, outcome: outcome)
            return
        }
        said = after.isEmpty ? "\(result) Nothing else waits on you." : result
        withAnimation(.snappy) { acted = true }
    }

    /// Shows `next` in this one's place, saying there how this one went once you've acted here.
    /// Left without a reply, this one comes round again after the rest.
    private func moveOn(to next: SessionRow, outcome: String? = nil) {
        if !acted && outcome == nil { store.passedOver(key) }
        store.outcome = outcome ?? (acted ? said : nil)
        go(next.key)
    }

    private var title: String { row?.title ?? "Session" }

    private func stop() async {
        guard let conv = conversation else { return }
        stopping = true
        defer { stopping = false }
        do {
            try await Task.detached { try conv.stop() }.value
            said = "Stopped."
        } catch {
            said = words(error)
        }
    }
}

/// The next session that waits on you, offered once you've replied or answered: its title, where
/// it is, and how many more wait after it.
private struct NextButton: View {
    let next: SessionRow
    let more: Int
    let showDevice: Bool
    /// The inbox shows every project, so it says which it's in.
    let showProject: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StatusMark(status: next.status, stalled: next.stalled)
                VStack(alignment: .leading, spacing: 1) {
                    Text(next.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next: \(next.title)")
        .accessibilityHint(more > 0 ? "\(more) more wait on you after it" : "The last that waits on you")
    }

    /// Where it is, and how many wait after it.
    private var place: String {
        var parts: [String] = []
        if showDevice { parts.append(Names.short(next.deviceName)) }
        if showProject { parts.append(next.project) }
        if more > 0 { parts.append("\(more) more after it") }
        if parts.isEmpty { parts.append("The last that waits on you") }
        return parts.joined(separator: " · ")
    }
}

/// A tool call the session waits on you to allow.
private struct ApprovalCard: View {
    let pending: Pending
    let canAct: Bool
    let why: String?
    /// The answer on its way, if one is.
    let answering: Choice?
    let answer: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Clock.text(pending.label, now: .now)).font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            if let input = pending.input, !input.isEmpty {
                // A plan is prose to read; anything else is a command or a change, shown as is.
                ScrollView {
                    if pending.plan {
                        MarkdownText(text: input).font(.subheadline)
                    } else {
                        Text(input).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
                .frame(maxHeight: pending.plan ? 320 : 120)
            }
            if let cannot = pending.cannot {
                Text(cannot).font(.footnote).foregroundStyle(.secondary)
            } else if canAct {
                HStack {
                    Button(answering == .deny ? "Denying…" : "Deny", role: .destructive) { answer(.deny) }
                        .buttonStyle(.bordered)
                    Spacer()
                    if pending.always {
                        Button(answering == .always ? "Allowing…" : "Always allow") { answer(.always) }
                            .buttonStyle(.bordered)
                    }
                    Button(allowLabel) { answer(.allow) }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(answering != nil)
            } else if let why {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 20))
    }

    private var allowLabel: String {
        switch (pending.plan, answering == .allow) {
        case (true, true): "Approving…"
        case (true, false): "Approve"
        case (false, true): "Allowing…"
        case (false, false): "Allow"
        }
    }
}

/// Where the conversation is scrolled to, and a page waiting for it to stop. A class, so a scroll
/// writes it without redrawing.
@MainActor private final class ScrollSpot {
    /// The top of what's in view, in the conversation's coordinates. Nothing is near it until the
    /// scroll view says where it is.
    var top: CGFloat = .infinity
    /// The scroll view isn't moving: a page can go in above without its motion undoing the hold.
    var still = true
    /// The conversation with a page above, waiting for the scroll view to be still.
    var waiting: [Item]?
    /// How far along holding your place a page going in above is.
    var hold = Hold.none

    enum Hold: Equatable {
        case none
        /// It's going in; the next layout says how far it pushed what's in view.
        case pageIn
        /// What's in view is being moved back to where it was.
        case scrolling(to: CGFloat)
    }

    struct Place: Equatable {
        var offset: CGFloat
        var inset: CGFloat
        var height: CGFloat
        var top: CGFloat { offset + inset }
    }
}

/// Where one of your prompts is against the top of what's in view.
private enum PromptPlace: Equatable {
    /// The whole of it is above the top.
    case gone
    /// It starts above the top and is still partly in view.
    case atTop
    case below

    init(_ frame: CGRect, top: CGFloat) {
        if frame.maxY < top + 8 {
            self = .gone
        } else if frame.minY < top + 2 {
            self = .atTop
        } else {
            self = .below
        }
    }
}

/// Your prompt behind what's in view, two lines of it over the top of the conversation; a tap
/// brings the whole of it up.
private struct PinnedPrompt: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                    .font(.subheadline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .accessibilityLabel("Your prompt: \(text)")
        .accessibilityHint("Shows it in the conversation")
    }
}

/// A piece of the conversation: something said, or a run of tool calls.
private enum Entry: Identifiable {
    case said(Item)
    case tools([Item])

    var id: String {
        switch self {
        case .said(let item): item.id
        case .tools(let calls): "run:" + (calls.first?.id ?? "")
        }
    }
}

/// One thing said: your prompts on the right, the agent's replies as text, notes small between.
private struct ItemView: View {
    let item: Item

    var body: some View {
        switch item.kind {
        case .you:
            HStack {
                Spacer(minLength: 40)
                Text(inline(item.text))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 16))
                    .textSelection(.enabled)
            }
        case .agent:
            MarkdownText(text: item.text)
        case .tool:
            ToolLine(item: item)
        case .note:
            Text(inline(item.text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A run of tool calls between what was said: the latest as a line, the ones before it folded
/// into one that says how many and which tools, as the Mac's panel does. Plain text, no icons:
/// the calls are the quiet part of the conversation.
private struct ToolRun: View {
    let calls: [Item]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Folding one line into one saves nothing, so two calls show as two.
            if calls.count > 2 {
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    Text(open ? "Hide \(calls.count - 1) tool calls" : summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(calls.dropLast(), id: \.id) { ToolLine(item: $0) }
                }
            } else {
                ForEach(calls.dropLast(), id: \.id) { ToolLine(item: $0) }
            }
            if let last = calls.last {
                ToolLine(item: last)
            }
        }
    }

    /// "4 tool calls · Bash, Read · 1 failed" for the ones before the latest.
    private var summary: String {
        let earlier = calls.dropLast()
        var names: [String] = []
        for call in earlier {
            let name = call.text.components(separatedBy: " · ").first ?? call.text
            if !names.contains(name) { names.append(name) }
        }
        var parts = ["\(earlier.count) tool calls", names.prefix(3).joined(separator: ", ")]
        let failed = earlier.filter(\.failed).count
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

/// A tool call as one quiet line, red when it failed, that opens to what went in and came out.
private struct ToolLine: View {
    let item: Item
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                Text(inline(item.text))
                    .font(.caption)
                    .foregroundStyle(item.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(open ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.failed ? "Failed: \(item.text)" : item.text)
            if open {
                if let input = item.input, !input.isEmpty { Block(text: input) }
                if let output = item.output, !output.isEmpty { Block(text: output, failed: item.failed) }
            }
        }
    }
}

/// Inline Markdown, code spans and emphasis, keeping the text's own line breaks.
private func inline(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
}

/// The reply a session Codealong runs is writing, as it comes, and the tool it's running.
private struct LiveReply: View {
    let live: Live

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !live.text.isEmpty {
                MarkdownText(text: live.text)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(live.tool.map { Clock.text($0, now: .now) } ?? AttributedString("Writing…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Block: View {
    let text: String
    var failed = false

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(failed ? .red : .primary)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}
