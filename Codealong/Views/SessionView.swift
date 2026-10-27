import PhotosUI
import SwiftUI

/// One session: its conversation, what it waits on you to allow, and a box to reply. It follows the
/// session as it goes: a change in the Mac's feed brings in what came since.
///
/// It also works through what waits on you, as the Mac's session panel does with ⌘⏎, PRs waiting
/// on your review among the sessions, in the Mac's order (`Store.queue`): while something else
/// waits on you, a bar over the box names it and says what going on to it does to this one, and a
/// swipe or a tap on it goes on, to a PR's page as to a session's screen; on the last, it offers
/// Finish instead. Holding Send sends and goes on at once. Going on marks it seen, so a turn that ended leaves Your turn and a reply that
/// asks you something leaves Needs you, as it always did, unless the bar's menu picks marking it
/// done, archiving it or snoozing it instead, for this session only (`SwipeOn`). One you replied to here, or one at work, is
/// left as it is, and one skipped while it waits on a call to allow comes round again after the
/// rest (`Going`).
///
/// The box says how a message gets there, as its Mac says (typed into its terminal, its
/// background job, a message from Codealong), once you write: until then it's folded to a line
/// saying who a message goes to, and while a turn runs, stop is in send's place, as in Codex's
/// app. While it waits on a call that can be answered here, what you send denies the call and
/// tells it that instead, as Claude Code's own "No, and tell Claude what to do differently" does.
/// One that isn't running goes on where you pick, on the model you pick, where its Mac offers a
/// choice; a running one says its model beside the box, and switches it where its Mac can. Where
/// its turn can take a message at once, the bolt beside Send sends it into the turn.
/// `/fork [prompt]` forks it into a copy that goes on in the background on its Mac, and you stay
/// where you are, as on the Mac.
///
/// A message goes as the Mac's windows send one: the box clears at once and the message shows at
/// the end of the conversation as sending, then sent, until the session's record has it, so you
/// can go on writing the next; messages to one session go in the order you sent them. One that
/// doesn't go is back in the box, with why. Swiping across the conversation goes along what waits
/// on you (`Paged`): to the left the next, as the Mac's ⌘] does, doing what the bar says, or from
/// the last, the end of what waits (`EndView`), and to the right back to what you came from. The screen follows the finger, with what it goes to
/// beside it, drawn from what the phone keeps (the next is read ahead); let go, it slides the rest
/// of the way, and Next slides the same way. Dragging the conversation, or tapping it, puts the
/// keyboard away.
///
/// As on the Mac, it opens at the newest and reads older pages as you scroll up, holding your
/// place. The prompt behind what's in view, once it's gone off the top, stays pinned there, two
/// lines of it, so what you asked stays in mind while you read what came of it; a tap brings it
/// up. A long turn can write more than a page, so when the first page doesn't start with a prompt,
/// the core reads back for the one before it, and it's pinned from the start. Scrolled up more
/// than half a screen, a button over the foot goes back down to the newest.
struct SessionView: View {
    let key: String
    /// Shows another session in this one's place.
    var go: (String) -> Void = { _ in }
    @Environment(Store.self) private var store
    /// The inbox's project: what's next stays in it.
    @AppStorage("project") private var project = ""
    /// What going on to the next does to this one, as picked over the box: for this session only,
    /// so each starts at marking it seen.
    @State private var swipeOn = SwipeOn.seen
    /// You replied or answered here: going on leaves it to the turn you gave it.
    @State private var acted = false
    /// You're going through what waits on you here (`Store.goingThrough`), as you were once: with
    /// nothing else waiting, going on goes to the end of it, still after you've answered it here
    /// and it no longer waits.
    @State private var goingThrough = false
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
    /// A swipe across the screen, while it goes, and what's beside it.
    @State private var swipe = Swipe()
    /// It's read what it shows: what a swipe goes to is read after.
    @State private var opened = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sending = false
    @State private var said: String?
    /// The reply it's writing, while it takes a turn Codealong runs on its Mac.
    @State private var live: Live?
    @State private var watching = false
    @State private var stopping = false
    /// Scrolled to the newest: new items keep it there. Scrolled up to read, it stays put.
    @State private var atBottom = true
    /// Scrolled up more than half a screen from the newest: a button over the foot goes back to it.
    @State private var scrolledUp = false
    /// How a message gets to it, as its Mac last said.
    @State private var way: Way?
    /// Where it goes on, and on what, while it isn't running: nil for what its Mac offers first.
    @State private var resumePlace: String?
    @State private var resumeModel: String?
    @State private var resumeEffort: String?
    @State private var switching = false
    /// A prompt of yours being edited, to go on from just before it (Edit from here).
    @State private var editing: Item?
    /// Pick a time… in its Snooze menu, asking for the time.
    @State private var snoozing: SnoozePick?
    /// The mode picked here, until its Mac's feed says the one it's in.
    @State private var modePicked: String?
    /// A queued message Send now didn't send into the turn, and why.
    @State private var unsteered: (id: String, why: String)?
    /// When Mark as done was last held here by work under way: done again soon after ends that too.
    @State private var heldAt: Date?
    @State private var finishing = false
    /// You marked it unread here: it's left Your turn, and the screen goes back to the list.
    @State private var markedUnread = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var typing = false
    /// The photo picker is open, and what was picked in it.
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    /// Photos picked or pasted and still being read: the reply waits for them.
    @State private var loadingPhotos = 0
    /// The send button's size, which a line of the reply box matches; it grows with the text size.
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32
    /// Reads the page before once you're this close to the top, so it's usually in before you
    /// get there: a page comes from the Mac, which can take a moment.
    private let nearTop: CGFloat = 900

    /// Opened by a swipe, it starts as the swipe drew it.
    init(key: String, opening: Opening? = nil, go: @escaping (String) -> Void = { _ in }) {
        self.key = key
        self.go = go
        if let opening {
            _items = State(initialValue: opening.kept.items)
            _hasOlder = State(initialValue: opening.kept.hasOlder)
            _loading = State(initialValue: opening.kept.items.isEmpty)
            _said = State(initialValue: opening.said)
            _pending = State(initialValue: opening.kept.pending)
            _way = State(initialValue: opening.kept.way)
        }
    }

    private var row: SessionRow? { store.sessions.first { $0.key == key } }
    /// What you've written here and not sent: the store keeps it, so it's still here when you come
    /// back, and a message that didn't go comes back to it.
    private var draft: String {
        get { store.drafts[key] ?? "" }
        nonmutating set { store.drafts[key] = newValue.isEmpty ? nil : newValue }
    }
    /// The session or PR you went on from to this one: swiping back goes there.
    private var before: Waiting? { store.previous(of: key) }
    /// What waits on you after this one, sessions and PRs; the first is next.
    private var after: [Waiting] { store.queue(after: key, project: project) }
    /// Where going on goes: the next, or on the last, the end of what waits.
    private var onward: Onward? { Onward.of(after, goingThrough: goingThrough) }

    var body: some View {
        // The screen follows a swipe, and what it goes to comes in beside it.
        Paged(swipe: swipe, key: key, next: onward, back: before, leaves: [.done, .archive].contains(going), ready: opened) {
            page.environment(\.imageMac, row?.device)
        }
        // What's next is in the menu and a swipe away; on a keyboard, ⌘] as on the Mac.
        .background {
            if let onward {
                // Unseen, at no size: one that takes no touches takes no keys either.
                Button("Next") { goOn(to: onward) }
                    .keyboardShortcut("]", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .navigationTitle(row?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TitleBlock(key: swipe.to?.key ?? key)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ImproveButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    sessionMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: key) { await open() }
        .onChange(of: store.goingThrough(key, project: project), initial: true) { _, now in
            if now { goingThrough = true }
        }
        // How a message gets there changes as it starts and stops running somewhere.
        .task(id: "\(row?.live == true)\(row?.inApp == true)\(online)") { await readWay() }
        .sheet(item: $editing) { prompt in
            EditFromSheet(title: title, mac: row?.device ?? "", prompt: prompt) { text in
                Task { await editFrom(prompt, text) }
            }
        }
        .sheet(item: $snoozing) { SnoozePicker(pick: $0) }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its harness keeps the name, so it shows there too.")
        }
        // The Mac's feed says the session moved: bring in what came since.
        .onChange(of: row?.lastActivity) { _, _ in Task { await refresh() } }
        // A message its Mac took: read for it at once.
        .task(id: awaitingRecord) { await followSent() }
        // Opened from the feeds saved before its Mac connected, or back after it went away: read
        // what it couldn't.
        .onChange(of: online) { _, now in
            if now { Task { await reconnected() } }
        }
        // Its Mac says the mode it's in now: that's the one shown.
        .onChange(of: row?.mode?.id) { _, _ in modePicked = nil }
        // A turn that ends while it's shown here has been seen; one you marked unread here is
        // left so.
        .onChange(of: row?.status) { _, status in
            if status == .unread && !markedUnread { store.markSeen(key) }
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
            if store.showing == key { store.showing = nil }
            if watching, let conv = conversation {
                Task.detached { conv.unwatch() }
            }
        }
        // A message that didn't go is back in the box: say why.
        .onChange(of: store.sendProblems[key]) { _, _ in sayProblem() }
        // How what a swipe did to the session gone on from went, once its Mac says.
        .onChange(of: store.lateOutcomes) { _, _ in takeLateOutcome() }
    }

    /// The conversation, with the reply box over its foot.
    private var page: some View {
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
                        if let origin = row?.origin {
                            // Where it came from: a fork of another session, or started by one.
                            let words = "\(origin.fork ? "Forked from" : "Started by") \(origin.title.map { "“\($0)”" } ?? "another session")"
                            if store.sessions.contains(where: { $0.key == origin.key }) {
                                Button(words) { go(origin.key) }
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(words).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                            }
                        }
                    }
                    ForEach(Entry.of(items)) { entry in
                        switch entry {
                        case .said(let item) where item.kind == .you:
                            ItemView(item: item, putBack: canAct ? { draft = $0 } : nil, editFrom: canAct && item.editable && row?.edits == true ? { editing = item } : nil)
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
                    ForEach(outgoingShown) { o in
                        OutgoingView(outgoing: o, held: o.held(in: row)) { store.dismissOutgoing(key, id: o.id) }
                    }
                    // After the turn that's running, which they wait on.
                    ForEach(heldShown, id: \.id) { m in
                        HeldView(message: m, sendNow: canAct && row?.steerable == true ? { Task { await steer(m) } } : nil, why: unsteered?.id == m.id ? unsteered?.why : nil)
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
            // Dragging the conversation puts the keyboard away, and so does a tap on it, which still
            // reaches what was tapped. (Interactively, as Messages does it, it went only once the
            // drag reached the keyboard, which reading back rarely does.)
            .scrollDismissesKeyboard(.immediately)
            .accessibilityIdentifier("conversation")
            .simultaneousGesture(TapGesture().onEnded { typing = false })
            .gesture(QueueSwipe(back: before != nil, moved: { swipe.moved($0) }, ended: swiped))
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.atEnd
            } action: { _, now in
                atBottom = now
            }
            // The top of what's in view, below the bars, in the conversation's coordinates. Its
            // height goes with it: a page too short to scroll is near the top without moving.
            .onScrollGeometryChange(for: ScrollSpot.Place.self) { geo in
                .init(offset: geo.contentOffset.y, inset: geo.contentInsets.top, bottom: geo.contentInsets.bottom, height: geo.contentSize.height, atEnd: geo.atEnd, scrolledUp: geo.scrolledUp)
            } action: { was, place in
                scrolled(from: was, to: place, proxy: proxy)
            }
            // A page that went in above while it scrolled goes in once it's still.
            .onScrollPhaseChange { _, phase in
                scroll.still = phase == .idle
                // You took it from there yourself.
                if phase == .interacting {
                    scroll.settling = false
                    scroll.backToEnd = false
                }
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
            // Over the foot of the conversation, above the box, while you read back up it.
            .overlay(alignment: .bottom) {
                if scrolledUp {
                    ToNewest(size: sendSize + 8) { toNewest(proxy: proxy) }
                        .padding(.bottom, 10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: scrolledUp)
            // A bar, as a PR's review box is, with a hard edge: the conversation goes under it
            // rather than reading through what's over the box (how the last one went, which has
            // no glass of its own, was written over its words).
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) { bottom }
        }
    }

    /// The session's menu: stop, rename, fork, where it came from, done, snooze, quiet, seen or
    /// unread, pin, archive; then copying its ID, as the Mac's menu does.
    @ViewBuilder
    private var sessionMenu: some View {
        // A swipe across the screen does it too, and what the bar says goes with it.
        if let onward {
            Button { goOn(to: onward) } label: {
                if let next = onward.waiting {
                    Label("Go to next", systemImage: "arrow.forward")
                    Text(next.title)
                } else {
                    Label("Finish", systemImage: "checkmark.circle")
                    Text("Nothing else waits on you")
                }
            }
            Divider()
        }
        if canStop {
            Button("Stop", systemImage: "stop.circle") { Task { await stop() } }
        }
        Button("Rename…", systemImage: "pencil") {
            newName = row?.name ?? row?.title ?? ""
            renaming = true
        }
        .disabled(!online)
        Button("Fork", systemImage: "arrow.triangle.branch") { Task { await fork("") } }
            .disabled(!canAct)
        // A running Claude Code session the Claude app reaches through its Remote Control: what
        // you type there goes to it where it runs, as the Mac's Open in Claude app does.
        if let url = row?.remoteControl.flatMap({ URL(string: $0) }) {
            Link(destination: url) {
                Label("Open in the Claude app", systemImage: "arrow.up.forward.app")
            }
        }
        if let origin = row?.origin, let title = origin.title {
            Button(origin.fork ? "Forked from “\(title)”" : "Started by “\(title)”", systemImage: "arrow.turn.left.up") { go(origin.key) }
                .disabled(!store.sessions.contains { $0.key == origin.key })
        }
        Button(finishing ? "Wrapping up…" : "Mark as done", systemImage: "checkmark.circle") { Task { await markDone() } }
            .disabled(!online || finishing)
        Menu("Snooze", systemImage: "moon.zzz") {
            ForEach(Snooze.choices()) { c in
                Button(c.label) { Task { await snooze(until: c.until) } }
            }
            Button("Pick a time…", systemImage: "calendar") {
                snoozing = SnoozePick(id: key, title: "Snooze") { until in Task { await snooze(until: until) } }
            }
            if row?.snoozedUntil != nil {
                Button("Wake now", systemImage: "sun.max") { Task { await snooze(until: nil) } }
            }
        }
        .disabled(!online)
        // Checked while it is, as on the Mac: its turns don't wait on you.
        Toggle(isOn: Binding(get: { row?.quiet == true }, set: { on in Task { await setQuiet(on) } })) {
            Label("Quiet", systemImage: "speaker.slash")
        }
        .disabled(!online)
        // A reply that asks you something isn't seen by opening it, and the last one waiting
        // has nothing to swipe on to.
        if row?.seenable == true {
            Button("Mark as seen", systemImage: "eye") { store.markSeen(key) }
                .disabled(!online)
        }
        if row?.unreadable == true {
            Button("Mark as unread", systemImage: "envelope.badge") { Task { await markUnread() } }
                .disabled(!online)
        }
        // Pinned on its Mac, which lists it first there and here.
        Button(row?.pinned == nil ? "Pin" : "Unpin", systemImage: row?.pinned == nil ? "pin" : "pin.slash") { Task { await pin() } }
            .disabled(!online)
        Button("Archive", systemImage: "archivebox") {
            store.archive(key)
            dismiss()
        }
        if let id = row?.id, !id.isEmpty {
            Section {
                Button("Copy session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = id }
            }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 8) {
            if let pending {
                if pending.questions.isEmpty || pending.cannot != nil {
                    ApprovalCard(pending: pending, hosted: row?.hosted == true, canAct: canAct, why: whyNot, answering: answering) { choice in
                        Task { await answer(pending, choice) }
                    }
                } else {
                    QuestionsCard(pending: pending, account: row?.account ?? "It", hosted: row?.hosted == true, canAct: canAct, why: whyNot, answering: answering) { answers in
                        Task { await answer(pending, .allow, questions: answers) }
                    } decline: {
                        Task { await answer(pending, .deny) }
                    }
                }
            }
            if let limit = row?.limit {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label {
                        Text(Clock.text(limit, now: context.date))
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.100percent").foregroundStyle(.orange)
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let lost = row?.connectionLost {
                LostConnection(words: lost)
            }
            if let cut = row?.cutOff {
                SessionNote(words: cut, symbol: "scissors", tint: .orange)
            }
            if row?.flagged == true {
                SessionNote(words: SessionNote.flagged, symbol: "flag.fill", tint: .red)
            }
            if let said {
                Text(said).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            // Not while you write here: the box needs the room, and what's next waits.
            if let onward, draft.isEmpty && attached.isEmpty {
                GoOnBar(next: onward, more: after.count - 1, showDevice: store.devices.count > 1, showProject: project.isEmpty, going: going, picked: swipeOn.label, choices: { SwipeOn.picker($swipeOn) }) { goOn(to: onward) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let suggestions = row?.suggestions {
                SuggestedRepliesView(suggestions: suggestions, blocked: canAct && !waitsElsewhere ? nil : whyNot ?? "It waits on you where it runs: answer that there first") { reply in
                    Task { await send(text: reply) }
                } edit: { reply in
                    draft = reply
                    typing = true
                } dismiss: {
                    Task {
                        do { try await store.dismissSuggestions(key) } catch { said = words(error) }
                    }
                }
            }
            ReplyBox(open: replyOpen, size: sendSize, attach: canAttach ? { picking = true } : nil, attachDisabled: sending) {
                // The images going with the reply sit in the box, over what's written.
                if canAttach && !attached.isEmpty {
                    AttachedRow(images: attached) { id in
                        store.detach(id, from: key)
                    }
                }
            } field: {
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text(placeholder(full: replyOpen))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    // A copied image pasted here goes with the reply, as a photo picked with + does.
                    WritingField(text: Binding(get: { draft }, set: { draft = $0 }), focused: $typing, label: placeholder(full: true), editable: canAct && !sending, pasted: canAttach ? { data in
                        if let data { attach(data) } else { said = "The image you copied couldn't be read." }
                    } : nil, reading: $loadingPhotos) {
                        // ⌘⏎ on a keyboard sends and goes on, as on the Mac.
                        guard canSend else { return }
                        Task { await send(thenNext: true) }
                    }
                }
            } tools: {
                // Where one that isn't running goes on is said here too, under its model.
                if canAct && (resuming || showsModel) {
                    ModelMenu(rules: rules, resumePlace: $resumePlace, resumeModel: $resumeModel, resumeEffort: $resumeEffort, switching: switching, height: sendSize, modePicked: modePicked) { model in
                        Task { await switchModel(model) }
                    } switchEffort: { effort in
                        Task { await switchEffort(effort) }
                    } switchMode: { mode in
                        Task { await switchMode(mode) }
                    }
                }
                if canSendNow {
                    // Into the turn it's taking, at once: Claude Code's send now, Codex's steer.
                    Button {
                        Task { await send(now: true) }
                    } label: {
                        SendNowMark(size: sendSize)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send now")
                    .accessibilityHint("Into the turn it's taking, rather than once the step it's on ends")
                }
            } action: {
                if stopsHere {
                    Button {
                        Task { await stop() }
                    } label: {
                        StopMark(stopping: stopping, size: sendSize)
                            .contentShape(.circle.inset(by: -replyInset))
                    }
                    .buttonStyle(.plain)
                    .disabled(stopping)
                    .accessibilityLabel(stopping ? "Stopping" : "Stop this turn")
                } else {
                    sendButton
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: 6, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            loadingPhotos += items.count
            for item in items {
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    loadingPhotos -= 1
                    if let data { attach(data) } else { said = "That photo couldn't be read from your library." }
                }
            }
        }
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            SendMark(ready: canSend || sending, sending: sending, size: sendSize)
                // The margin around it takes a tap too.
                .contentShape(.circle.inset(by: -replyInset))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send")
        // Held, as Messages offers its send options: send and go straight on.
        .contextMenu {
            if canSendNow {
                Button {
                    Task { await send(now: true) }
                } label: {
                    Label("Send now", systemImage: "bolt")
                    Text("Into the turn it's taking")
                }
                .disabled(!canSend)
            }
            if let onward {
                Button {
                    Task { await send(thenNext: true) }
                } label: {
                    if let next = onward.waiting {
                        Label("Send and go to next", systemImage: "arrow.forward")
                        Text(next.title)
                    } else {
                        Label("Send and finish", systemImage: "checkmark.circle")
                        Text("Nothing else waits on you")
                    }
                }
                .disabled(!canSend)
            }
        }
    }

    /// The reply box is open while you write, and while something's written or attached, so it's
    /// still there to send once the keyboard goes.
    private var replyOpen: Bool { typing || !draft.isEmpty || !attached.isEmpty }

    /// Stop is in send's place while a turn runs and there's nothing to send.
    private var stopsHere: Bool {
        canStop && !sending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty
    }

    /// The images attached to the reply, kept with its draft.
    private var attached: [AttachedImage] { store.attached[key] ?? [] }

    /// Images can go with what's written: not with a deny, which only takes words.
    private var canAttach: Bool { canAct && !denying && !waitsElsewhere }

    private func attach(_ data: Data) {
        guard let mac = row?.device else { return }
        store.attach(data, to: key, mac: mac) { why in said = why }
    }

    /// Only a Mac with remote control on takes a reply or an answer from here.
    private var canAct: Bool { whyNot == nil }

    /// Its Mac is connected: naming it changes only how it's listed, so it needs no remote control.
    private var online: Bool {
        guard let row else { return false }
        return store.devices.contains { $0.key == row.device && $0.online }
    }

    private var canSend: Bool {
        let words = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Images alone are a reply too, once each is kept on its Mac; a deny takes only words.
        let images = !attached.isEmpty && !denying
        return canAct && !sending && !waitsElsewhere && (words || images) && loadingPhotos == 0 && !attached.contains { $0.state == .keeping }
    }

    /// What's written can go into the turn it's taking at once.
    private var canSendNow: Bool { canAct && row?.steerable == true && pending == nil }

    /// Its turn is running and its Mac can stop it.
    private var canStop: Bool { canAct && row?.stoppable == true }

    /// It waits on a call that can be answered here: what you send denies it and says that instead.
    private var denying: Bool { pending != nil && pending?.cannot == nil }

    /// It waits on something that can only be answered where it runs: a message waits until it's
    /// answered there.
    private var waitsElsewhere: Bool { pending?.cannot != nil }

    /// How it takes a reply: where it goes on while it isn't running, its model while it is.
    private var rules: ReplyRules {
        ReplyRules(row: row, way: way, choices: row.flatMap { store.choices[$0.device] }, resumePlace: resumePlace)
    }
    private var account: StartAccount? { rules.account }
    private var resuming: Bool { rules.resuming }
    private var resumeAt: StartPlace? { rules.resumeAt }
    private var resumeTakesModel: Bool { rules.resumeTakesModel }
    private var switchesModel: Bool { rules.switchesModel }
    private var showsModel: Bool { rules.showsModel }

    /// The box's words before you write: in `full`, how a message gets there; folded, who it goes to.
    private func placeholder(full: Bool) -> String {
        replyWords(why: whyNot, pending: pending, account: row?.account) {
            let words = store.replyPlaceholder(key, way: way, resumePlace: resuming ? resumeAt?.id : nil, behind: resuming && resumeAt?.behind == true)
            return full ? words.full : words.short
        }
    }

    private var whyNot: String? { store.cannotReach(row) }

    private func open() async {
        store.showing = key
        if store.slidIn?.key == key { store.slidIn = nil }
        sayProblem()
        guard conversation == nil, let conv = store.conversation(key) else { return }
        conversation = conv
        // Read before (opened, or prefetched as the next that waits on you): it shows at once,
        // and its Mac is asked only for what came since.
        let kept = conv.kept()
        if !kept.isEmpty {
            show(kept)
            loading = false
        }
        // Moved on to from another: say how that one went.
        if let outcome = store.outcome {
            said = outcome
            store.outcome = nil
        }
        takeLateOutcome()
        await refresh()
        // Opened from the feeds saved before its Mac answered (the app was just opened, or a link
        // opened it): what was kept shows meanwhile, and it's read again the moment the Mac is
        // connected (every two seconds where it says it is but didn't answer), for half a minute.
        var readOnline = false
        for tick in 1...150 where problem != nil && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            guard problem != nil else { break }
            if (online && !readOnline) || tick % 10 == 0 {
                readOnline = readOnline || online
                await refresh()
            }
        }
        loading = false
        if row?.status == .unread { store.markSeen(key) }
        // A turn longer than the first page: the prompt behind it, to pin from the start.
        await lookBack()
        // The next that waits on you is read now, so it shows at once when you go on to it.
        opened = true
        // A session Codealong runs sends its reply as it's written, while it's shown here.
        if row?.hosted == true {
            watching = await Task.detached { conv.watch() }.value
            live = conv.live()
        }
    }

    /// Messages from here its Mac took that the conversation doesn't show yet.
    /// The messages its harness holds, but those sent into the turn from here, which show as sent
    /// in their place.
    private var heldShown: [HeldMessage] {
        let steered = Set((store.outgoing[key] ?? []).compactMap { o -> String? in
            if case .steer(let id) = o.how { id } else { nil }
        })
        return (row?.queued ?? []).filter { !steered.contains($0.id) }
    }

    /// Messages on their way from here, but those its harness lists among what it holds, which
    /// show there once.
    private var outgoingShown: [Outgoing] {
        let held = Set(heldShown.map(\.id))
        return (store.outgoing[key] ?? []).filter { o in
            guard case .sent(_, _, let id?) = o.state else { return true }
            return !held.contains(id)
        }
    }

    /// Sends a queued message into the turn now.
    private func steer(_ message: HeldMessage) async {
        unsteered = nil
        if let why = await store.steer(key, message: message) {
            unsteered = (message.id, why)
        }
    }

    private var awaitingRecord: Int {
        (store.outgoing[key] ?? []).count { if case .sent = $0.state { true } else { false } }
    }

    /// Reads what came since a few times over the seconds after its Mac takes a message, rather
    /// than waiting for the Mac's feed to say the session moved: the message shows taken as soon
    /// as the session's record has it. One a busy session holds until its turn ends shows when
    /// the feed says so.
    private func followSent() async {
        for wait in [200, 300, 500, 500, 750, 1000, 1500, 2000, 3000] {
            guard awaitingRecord > 0 else { return }
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled else { return }
            await refresh()
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
    private func scrolled(from was: ScrollSpot.Place, to place: ScrollSpot.Place, proxy: ScrollViewProxy) {
        scroll.top = place.top
        // The bars' inset arriving as the screen comes in (after a first layout without it, when
        // the conversation was kept from before) moves the scroll view to its top, though its
        // position still says the end: until you scroll it, it goes back. Left there, it read the
        // page before as if you'd scrolled up, and held your place at the top of that.
        if scroll.settling && place.inset != was.inset && !place.atEnd && scroll.hold == .none {
            scroll.backToEnd = true
            position.scrollTo(edge: .bottom)
        }
        if scroll.backToEnd {
            guard place.atEnd else { return }
            scroll.backToEnd = false
        }
        // After the bars' inset is dealt with, so the top it flashes to as the screen comes in
        // doesn't show the button.
        if place.scrolledUp != scrolledUp { scrolledUp = place.scrolledUp }
        // What's over the box grew while the newest was in view (how the last one went, said once
        // its Mac answered; a card; the keyboard): the newest stays in view rather than going under
        // it. However little it grew: at the end is within a few lines of it, and a line said
        // would hide the conversation's last. By the mark at its end, as new items keep it there:
        // the position already says the end, so asking it for the end again changed nothing.
        if was.atEnd && place.bottom > was.bottom + 0.5 && scroll.hold == .none {
            withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
        }
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
        // Messages sent from here that the conversation shows now are in it: their bubbles go.
        store.shown(key, items: all)
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
        scroll.trip += 1
        let trip = scroll.trip
        while !items.contains(where: { $0.id == id }) || scroll.hold != .none {
            // A page already on its way, waiting for the scroll to stop or being held comes first.
            if loadingOlder || scroll.waiting != nil || scroll.hold != .none {
                try? await Task.sleep(for: .milliseconds(50))
            } else {
                let had = items.count
                await older()
                if items.count == had && scroll.waiting == nil { return }
            }
            // Gone down to the newest meanwhile, or to another prompt: that's where it stays.
            guard scroll.trip == trip else { return }
        }
        scroll.settling = false
        scroll.backToEnd = false
        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
    }

    /// Back down to the newest from reading up the conversation. By the mark at its end, as new
    /// items keep it there.
    private func toNewest(proxy: ScrollViewProxy) {
        // A prompt still being read back to isn't gone to once it's read.
        scroll.trip += 1
        // A page going in above would hold what was in view and take it back up there; at the
        // end, there's nothing to hold.
        if scroll.hold != .none {
            scroll.hold = .none
            repin()
        }
        scroll.settling = false
        scroll.backToEnd = false
        withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
    }

    /// Why a message to it didn't go, once: it's back in the box.
    private func sayProblem() {
        guard let why = store.sendProblems[key] else { return }
        said = "Your message didn't go: \(why) It's back in the box."
        store.sendProblems[key] = nil
    }

    /// Its Mac connected while it's shown: what couldn't be read is read, and a session Codealong
    /// runs is followed again, since a new connection follows nothing.
    private func reconnected() async {
        guard let conv = conversation else { return }
        let empty = items.isEmpty
        await refresh()
        if empty { await lookBack() }
        if row?.hosted == true {
            watching = await Task.detached { conv.watch() }.value
            live = conv.live()
        }
    }

    /// How a message gets there, as its Mac says it, asked again as it starts or stops running;
    /// and what its Mac can start, for its account's models and where it can go on.
    private func readWay() async {
        guard let conv = conversation ?? store.conversation(key), online, let device = row?.device else { return }
        way = await Task.detached { conv.way() }.value
        _ = try? await store.startChoices(device)
    }

    /// Sends the box; with `thenNext`, goes on to what waits on you once it's gone; with `now`,
    /// into the turn it's taking at once. While it waits on a call that can be answered here, it
    /// denies the call and tells it what you wrote instead; while it isn't running, it goes on
    /// where you picked. `/fork [prompt]` forks it instead. One that fails stays, saying why.
    private func send(text reply: String? = nil, thenNext: Bool = false, now: Bool = false) async {
        guard let conv = conversation else { return }
        // A suggested reply goes as it is, and what's being written stays in the box.
        let text = reply ?? draft
        let clear = { if reply == nil { draft = "" } }
        // The images attached go first, each on a line of its own, as the Mac's box writes them.
        let images = reply == nil ? attached.compactMap(\.reference) : []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply == nil && (trimmed == "/fork" || trimmed.hasPrefix("/fork ")) {
            // A fork starts on words alone: the images would be left for the next reply here.
            if !attached.isEmpty {
                said = "A fork starts with words only: take the images off to fork, or send them in a reply."
                return
            }
            draft = ""
            await fork(String(trimmed.dropFirst("/fork".count)).trimmingCharacters(in: .whitespaces))
            return
        }
        // A message, or one that goes on with a session that isn't running, goes without waiting:
        // it shows at once, and the store says if it doesn't go.
        if !denying {
            let how: Outgoing.How
            if resuming, let place = resumeAt {
                let (model, effort) = resumeTakesModel ? (resumeModel, resumeEffort) : (nil, nil)
                how = .resume(place: place.id, model: model, effort: effort)
            } else {
                how = .send(now: now)
            }
            clear()
            if !images.isEmpty { store.attached[key] = nil }
            said = nil
            store.post(key, title: title, text: ImagePrep.prompt(images: images, text: text), how: how)
            store.dealtWith(key)
            if thenNext, let onward {
                moveOn(to: onward, outcome: "Sending to “\(title)”…")
                return
            }
            if after.isEmpty { said = "Nothing else waits on you." }
            withAnimation(.snappy) { acted = true }
            withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
            return
        }
        // A deny with your words answers the call the card shows, so it waits for the Mac.
        guard let p = pending else { return }
        sending = true
        defer { sending = false }
        do {
            let result = try await Task.detached { try conv.denySaying(id: p.id, message: text) }.value
            answered = p.id
            pending = nil
            clear()
            typing = false
            done(result, outcome: "\(p.questions.isEmpty ? "Denied" : "Declined") “\(title)”, saying what to do instead.", thenNext: thenNext)
        } catch {
            said = words(error)
        }
    }

    /// A swipe let go: far or fast enough toward what's that way, it slides there; otherwise the
    /// screen settles back.
    private func swiped(_ distance: CGFloat, _ speed: CGFloat) {
        let ahead = distance < 0
        guard swipe.letGo(distance, speed, toward: ahead ? onward != nil : distance > 0 && before != nil) else { return }
        if ahead, let onward {
            goOn(to: onward, speed: speed)
        } else if let target = before {
            // Back is a step by hand: this one isn't passed over for it. The trail is cut back once
            // it's there, so what's beside it stays put while it slides.
            store.outcome = acted ? said : nil
            slide(to: target.key, back: true, speed: speed) { store.back(to: target.key) }
        }
    }

    /// Slides this screen away and `target`'s in after it, from what the phone keeps of it, then
    /// does `then` and shows `target` in its place, starting as it was drawn sliding in.
    private func slide(to target: String, back: Bool, speed: CGFloat = 0, seen: Bool = true, then: @escaping () -> Void = {}) {
        // Gone on from, it's been seen, as the Mac's ⌘E marks it: a finished turn, or a reply
        // that asks you something, which then leaves Needs you. Opening marks a finished turn
        // too, but only once its Mac has answered, which a quick swipe goes on before; one that
        // asks you something stays as it is while it's open, so going back to the list leaves it.
        if seen && row?.seenable == true && !markedUnread { store.markSeen(key) }
        // A PR's page opens with what was last read of it.
        if !target.hasPrefix(PrView.prefix) {
            store.slidIn = (target, Opening(kept: swipe.kept[target] ?? Kept(), said: store.outcome))
        }
        swipe.slide(to: target, back: back, speed: speed, reduceMotion: reduceMotion, go: go, then: then)
        typing = false
    }

    /// Answers what it waits on; with `questions`, the picks for the questions it asks.
    private func answer(_ p: Pending, _ choice: Choice, questions: [QuestionAnswer]? = nil) async {
        guard let conv = conversation, answering == nil else { return }
        answering = choice
        defer { answering = nil }
        do {
            let result = try await Task.detached {
                if let questions { return try conv.answerQuestions(id: p.id, answers: questions) }
                return try conv.answer(id: p.id, choice: choice)
            }.value
            answered = p.id
            pending = nil
            let outcome = questions != nil ? "Answered “\(title)”." : choice == .deny ? "Denied “\(title)”." : "Allowed “\(title)” to go on."
            done(result, outcome: outcome)
        } catch {
            said = words(error)
        }
    }

    /// Forks it from just before one of your prompts, your edit in its place (Edit from here):
    /// the copy shows once it's listed, as the Mac's window follows it, and this one stays as it
    /// was.
    private func editFrom(_ prompt: Item, _ text: String) async {
        guard let conv = conversation else { return }
        said = "Forking “\(title)”…"
        do {
            let started = try await Task.detached { try conv.edit(item: prompt.id, prompt: text) }.value
            said = started.message ?? "Forked: the copy goes on from before that message, with your edit, on its Mac."
            if let copy = started.key { store.openWhenListed = copy }
        } catch {
            said = words(error)
        }
    }

    /// Forks it into a copy that goes on in the background on its Mac, on `prompt` when there's
    /// one; you stay here, as on the Mac.
    private func fork(_ prompt: String) async {
        do {
            let started = try await store.fork(key, prompt: prompt)
            said = started.message ?? (prompt.isEmpty ? "Forked: the copy waits for a prompt in the background on its Mac." : "Forked: the copy goes on in the background on its Mac.")
        } catch {
            said = words(error)
        }
    }

    /// Done with it, as the Mac's Mark as done: it closes where its Mac can close it, and is marked
    /// seen and archived; then what waits on you next, or back to the list. Work under way holds
    /// it, and done again soon after ends that too.
    private func markDone() async {
        let stop = heldAt.map { Date.now.timeIntervalSince($0) < 15 } ?? false
        if !stop && row?.status == .working {
            heldAt = .now
            said = "“\(title)” is still working. Mark it done again to end that too."
            return
        }
        finishing = true
        defer { finishing = false }
        do {
            let outcome = try await store.done(key, stop: stop)
            guard outcome.done else {
                heldAt = .now
                said = "\(outcome.message) Mark it done again to end that too."
                return
            }
            heldAt = nil
            store.dealtWith(key)
            if let onward {
                moveOn(to: onward, outcome: outcome.message)
            } else {
                if outcome.noted { store.notice = outcome.message }
                dismiss()
            }
        } catch {
            said = words(error)
        }
    }

    /// Snoozes it until `until`, as the Mac's Snooze does: off Needs you and Your turn everywhere
    /// until then, so the screen goes on to what's next, or back to the list. Without a time, it
    /// wakes and stays.
    private func snooze(until: Date?) async {
        do {
            try await store.snooze(key, until: until)
        } catch {
            said = words(error)
            return
        }
        guard let until else {
            said = "Awake: it waits on you again as it would."
            return
        }
        let outcome = "Snoozed “\(title)” until \(Snooze.words(until))."
        store.dealtWith(key)
        if let onward {
            // Left as it was: it comes back as Your turn when the snooze ends.
            moveOn(to: onward, outcome: outcome, seen: false)
        } else {
            store.notice = outcome
            dismiss()
        }
    }

    /// Quiets it, or makes it heard again, as the Mac's Quiet does.
    private func setQuiet(_ on: Bool) async {
        do {
            try await store.quiet(key, on)
            said = on ? "Quiet: its turns won’t wait on you, only what needs you will." : "Heard again: its turns wait on you as before."
        } catch {
            said = words(error)
        }
    }

    /// Your turn again, as the Mac's Mark as unread: until it's seen or prompted. Shown here it
    /// would be seen at once, so the screen goes back to the list.
    private func markUnread() async {
        markedUnread = true
        do {
            try await store.markUnread(key)
            dismiss()
        } catch {
            markedUnread = false
            said = words(error)
        }
    }

    private func pin() async {
        let on = row?.pinned == nil
        do {
            try await store.pin(key, on)
        } catch {
            said = words(error)
        }
    }

    private func rename() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != row?.title else { return }
        do {
            try await store.rename(key, to: name)
        } catch {
            said = words(error)
        }
    }

    private func switchModel(_ model: String) async {
        guard let conv = conversation else { return }
        switching = true
        defer { switching = false }
        do {
            said = try await Task.detached { try conv.switchModel(model: model) }.value
        } catch {
            said = words(error)
        }
    }

    private func switchEffort(_ effort: String) async {
        guard let conv = conversation else { return }
        switching = true
        defer { switching = false }
        do {
            said = try await Task.detached { try conv.switchEffort(effort: effort) }.value
        } catch {
            said = words(error)
        }
    }

    /// Switches one Codealong runs to another mode: the one picked shows at once, then the one its
    /// agent says it's in, which may be another (Accept edits for Auto, on a model that doesn't
    /// take it), until its Mac's feed has it.
    private func switchMode(_ mode: String) async {
        guard let conv = conversation else { return }
        switching = true
        modePicked = mode
        defer { switching = false }
        do {
            let switched = try await Task.detached { try conv.switchMode(id: mode) }.value
            modePicked = switched.mode
            said = switched.message
        } catch {
            modePicked = nil
            said = words(error)
        }
    }

    /// A reply or an answer went: this one is dealt with until it waits on you anew, and what's
    /// next is offered, or gone on to.
    private func done(_ result: String, outcome: String, thenNext: Bool = false) {
        store.dealtWith(key)
        if thenNext, let onward {
            moveOn(to: onward, outcome: outcome)
            return
        }
        said = after.isEmpty ? "\(result) Nothing else waits on you." : result
        withAnimation(.snappy) { acted = true }
    }

    /// What going on to the next does to this one, as the bar over the box says it.
    private var going: Going { Going.of(swipeOn, row: row, pending: pending, acted: acted || !(store.outgoing[key] ?? []).isEmpty) }

    /// Goes on to `next` as a swipe does, doing to this one what the bar says. Marked seen as it
    /// slides, as it always was (`slide`), it's passed over until its Mac's feed has it seen, so
    /// one whose Mac didn't take that comes round again. Marking it done or archiving it waits on
    /// its Mac, which the swipe doesn't: it's out of what's next meanwhile, how it went is said on
    /// the screen shown once its Mac answers, and one that didn't go comes round again
    /// (`Store.doneLater`, `Store.archiveLater`). Done marks it seen on its Mac, so the slide
    /// doesn't: one that work under way held stays as it was, rather than leaving Your turn
    /// though it wasn't done.
    private func goOn(to next: Onward, speed: CGFloat = 0) {
        guard swipe.to == nil else { return }
        switch going {
        case .done:
            store.dealtWith(key)
            store.doneLater(key, title: title)
            moveOn(to: next, outcome: "Marking “\(title)” as done…", speed: speed, seen: false)
        case .archive:
            store.dealtWith(key)
            store.archiveLater(key, title: title)
            moveOn(to: next, outcome: "Archived “\(title)”.", speed: speed)
        case .snooze:
            guard case .snooze(let time) = swipeOn else { return moveOn(to: next, speed: speed) }
            let until = time.picked().until
            store.snoozeLater(key, title: title, until: until)
            // Left as it was: it comes back as Your turn when the snooze ends.
            moveOn(to: next, outcome: "Snoozed “\(title)” until \(Snooze.words(until)).", speed: speed, seen: false)
        case .seen, .on, .working, .later:
            moveOn(to: next, speed: speed)
        }
    }

    /// Says how what a swipe did to the sessions gone on from went, once their Macs have answered,
    /// unless this screen is sliding away: the one sliding in says it.
    private func takeLateOutcome() {
        guard !store.lateOutcomes.isEmpty, store.showing == key, swipe.to == nil else { return }
        said = store.lateOutcomes.joined(separator: "\n")
        store.lateOutcomes = []
    }

    /// Shows `next` in this one's place, saying there how this one went once you've acted here.
    /// Left without a reply while it needs you, this one comes round again after the rest.
    private func moveOn(to next: Onward, outcome: String? = nil, speed: CGFloat = 0, seen: Bool = true) {
        guard swipe.to == nil else { return }
        if !acted && outcome == nil { store.passedOver(key) }
        if next.key != key { store.trail.append(key) }
        if next == .end { store.goingToEnd(from: key) }
        store.outcome = outcome ?? (acted ? said : nil)
        slide(to: next.key, back: false, speed: speed, seen: seen)
    }

    private var title: String { row?.title ?? "Session" }

    private func stop() async {
        guard let conv = conversation else { return }
        stopping = true
        defer { stopping = false }
        do {
            said = try await Task.detached { try conv.stop() }.value
        } catch {
            said = words(error)
        }
    }
}

/// A tool call the session waits on you to allow, or a plan to approve. A call its agent offers no
/// way to allow just this once has no Allow, only Always where it can be allowed from now on.
private struct ApprovalCard: View {
    let pending: Pending
    /// Codealong runs it on its Mac.
    let hosted: Bool
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
                // A plan is prose to read; anything else is a command or a change, shown as is. As
                // tall as it is, up to a point, and it scrolls past that.
                UpTo(most: pending.plan ? 320 : 120) {
                    ScrollView {
                        if pending.plan {
                            MarkdownText(text: input).font(.subheadline)
                        } else {
                            Text(input).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            if let cannot = pending.cannot {
                Text(cannot).font(.footnote).foregroundStyle(.secondary)
            } else if canAct {
                HStack {
                    Button(answering == .deny ? "Denying…" : "Deny", role: .destructive) { answer(.deny) }
                        .buttonStyle(.bordered)
                    Spacer()
                    // With no Allow, Always is the answer that lets it go on.
                    if pending.always && pending.noOnce {
                        Button(answering == .always ? "Allowing…" : "Always allow") { answer(.always) }
                            .buttonStyle(.borderedProminent)
                    } else if pending.always {
                        Button(answering == .always ? "Allowing…" : "Always allow") { answer(.always) }
                            .buttonStyle(.bordered)
                    }
                    if !pending.noOnce {
                        Button(allowLabel) { answer(.allow) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(answering != nil)
                Text(says).font(.footnote).foregroundStyle(.secondary)
            } else if let why {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .modifier(WaitingCard())
    }

    /// What its answers do, as the Mac's card says it.
    private var says: String {
        if pending.plan { return "Approve lets it go on with the plan. Deny keeps it planning, or write below what to change." }
        if pending.noOnce {
            let how = pending.always ? "allows calls like this only from now on, not just this once" : "offers no way to allow this"
            return "Its agent \(how). Deny tells it no, and it carries on."
        }
        return hosted ? "Allow lets this call run once. Deny tells it no, and it carries on." : "Allow lets this call run once. Deny stops the turn, or write below what to do instead."
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

/// Questions a session asks you (Claude Code's `AskUserQuestion`), one at a time as the Mac's
/// panel and Claude Code's own prompt show them, with a strip of their headers to go between them,
/// ticked once answered: all at once, a few long ones filled the screen. Pick a choice, several
/// where a question takes more, or write your own answer. A choice for a question that takes one
/// goes on to the next without an answer, and the button says Next until none is left; your picks
/// go back as its answer, as the Mac's panel sends them. Decline stops the turn. It starts folded
/// to a line of what it asks, so the conversation it came with can be read above it: open, a long
/// question and its choices covered most of the screen. A tap opens it, and folds it again.
private struct QuestionsCard: View {
    let pending: Pending
    let account: String
    let hosted: Bool
    let canAct: Bool
    let why: String?
    let answering: Choice?
    let answer: ([QuestionAnswer]) -> Void
    let decline: () -> Void
    @State private var picks: [String: [String]] = [:]
    @State private var own: [String: String] = [:]
    /// The question showing.
    @State private var at = 0
    @State private var open = false

    var body: some View {
        let questions = pending.questions
        let shown = min(at, questions.count - 1)
        let q = questions[shown]
        let next = nextQuestion(after: shown)
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Asks you").font(.subheadline.weight(.medium))
                        if !open {
                            Text(gist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(open ? "Asks you" : "Asks you: \(String(gist.characters))")
            .accessibilityHint(open ? "Folds it away, to read the conversation" : "Opens it, to answer")
            if open {
                card(q, shown: shown, next: next)
            }
        }
        .modifier(WaitingCard())
        // Another set of questions starts folded, at its first, with nothing picked.
        .onChange(of: pending.id) { _, _ in
            open = false
            at = 0
            picks = [:]
            own = [:]
        }
    }

    /// What it asks, on the line it folds to: the question, or with several, how many and their
    /// headers when they all have one (as its line in the conversation names them).
    private var gist: AttributedString {
        let questions = pending.questions
        guard questions.count > 1 else { return Clock.text(questions[0].question, now: .now) }
        let headers = questions.compactMap(\.header)
        if headers.count == questions.count {
            return AttributedString("\(questions.count) questions: " + headers.joined(separator: ", "))
        }
        return AttributedString("\(questions.count) questions, the first: ") + Clock.text(questions[0].question, now: .now)
    }

    /// The card opened: the question showing, its choices, and the answers to give.
    @ViewBuilder
    private func card(_ q: Question, shown: Int, next: Int?) -> some View {
        let questions = pending.questions
        if pending.unwritten {
            // What it wrote with them isn't in the conversation above yet.
            Text("What \(account) wrote with this question shows in the conversation once it’s answered\(hosted ? "" : "; where it runs on its Mac has it now").")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if questions.count > 1 {
            steps(showing: shown)
        }
        // As tall as the question is, up to a point, and it scrolls past that.
        UpTo(most: 320) {
            ScrollView {
                question(q, alone: questions.count == 1)
                    .id(q.question)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        if canAct {
            HStack {
                Button(answering == .deny ? "Declining…" : "Decline", role: .destructive, action: decline)
                    .buttonStyle(.bordered)
                Spacer()
                if let next {
                    Button("Next") { go(next) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(answering == .allow ? "Answering…" : "Answer") { answer(answers) }
                        .buttonStyle(.borderedProminent)
                        .disabled(answers.isEmpty)
                }
            }
            .disabled(answering != nil)
            Text("\(q.multiSelect ? "Pick one or more." : "Pick one, or write your own.") Decline stops the turn, or write below to say something else.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let why {
            Text(why).font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The questions by their headers, the one showing filled, a tick on each answered.
    private func steps(showing shown: Int) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(pending.questions.enumerated()), id: \.offset) { i, q in
                    let on = i == shown
                    Button { go(i) } label: {
                        HStack(spacing: 4) {
                            if answered(q) {
                                Image(systemName: "checkmark").font(.caption2.weight(.bold))
                            }
                            Text(q.header ?? "Question \(i + 1)").font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background), in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(q.header ?? "Question \(i + 1)")
                    .accessibilityValue(answered(q) ? "Answered" : "")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func question(_ q: Question, alone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // With several, the strip above names each by its header.
                if alone, let header = q.header {
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.background, in: .capsule)
                }
                Text(Clock.text(q.question, now: .now)).font(.subheadline)
            }
            ForEach(q.options, id: \.label) { o in
                let on = (picks[q.question] ?? []).contains(o.label)
                Button {
                    pick(q, o.label)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.label).foregroundStyle(.primary)
                            if let d = o.description {
                                Text(d).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canAct || answering != nil)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            TextField(q.options.isEmpty ? "Your answer" : "Or write your own answer", text: Binding(get: { own[q.question] ?? "" }, set: { type(q, $0) }), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!canAct || answering != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func go(_ i: Int) {
        withAnimation(.snappy) { at = i }
    }

    /// One answer to a question that takes one: a choice clears what was written, as on the Mac,
    /// and is all it takes, so the next without an answer shows.
    private func pick(_ q: Question, _ label: String) {
        let chosen = picks[q.question] ?? []
        picks[q.question] = q.multiSelect ? (chosen.contains(label) ? chosen.filter { $0 != label } : chosen + [label]) : [label]
        if !q.multiSelect {
            own[q.question] = ""
            if let next = nextQuestion(after: min(at, pending.questions.count - 1)) { go(next) }
        }
    }

    private func type(_ q: Question, _ text: String) {
        own[q.question] = text
        if !q.multiSelect && !text.trimmingCharacters(in: .whitespaces).isEmpty { picks[q.question] = [] }
    }

    private func answered(_ q: Question) -> Bool {
        answers.contains { $0.question == q.question }
    }

    /// The next question after `at` without an answer, coming round from the first (the Mac's
    /// `nextQuestion`); none once every other one has one.
    private func nextQuestion(after at: Int) -> Int? {
        let questions = pending.questions
        let n = questions.count
        guard n > 1 else { return nil }
        for k in 1..<n {
            let i = (at + k) % n
            if !answered(questions[i]) { return i }
        }
        return nil
    }

    /// Each question's picks: several, with your words after them, where it takes more; else your
    /// words or the choice.
    private var answers: [QuestionAnswer] {
        pending.questions.compactMap { q in
            let words = (own[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = picks[q.question] ?? []
            let all = q.multiSelect ? chosen + (words.isEmpty ? [] : [words]) : (words.isEmpty ? Array(chosen.prefix(1)) : [words])
            return all.isEmpty ? nil : QuestionAnswer(question: q.question, multiSelect: q.multiSelect, picks: all)
        }
    }
}

/// What a session waits on you for, over the foot of its conversation: solid, so what scrolls under
/// it doesn't show through (it did, and a long question was hard to read over the reply it came
/// with), in the orange of a session that needs you, lifted a little off the page. Suggested
/// replies sit in one too, untinted: they only offer.
private struct WaitingCard: ViewModifier {
    var tint: Color? = .orange
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                let shape = RoundedRectangle(cornerRadius: 20)
                // Untinted, a hairline edge keeps it apart from the page in dark mode, where both
                // are black.
                shape.fill(.background)
                    .overlay(shape.fill((tint ?? .clear).opacity(0.1)))
                    .overlay(shape.strokeBorder(Color.primary.opacity(tint == nil ? 0.1 : 0)))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            }
    }
}

/// Why its last turn ended, when its harness couldn't reach its API, as the Mac's header says it.
/// Something about the session's last turn, above the box, as the Mac's header says it.
private struct SessionNote: View {
    let words: String
    let symbol: String
    let tint: Color

    /// A session its provider flagged, as the Mac's Flagged chip says it.
    static let flagged = "Its provider flagged a message in this conversation, so by default its Mac sends it nothing by itself (Settings › Automation there). You can still reply yourself."

    var body: some View {
        Label {
            Text(words)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LostConnection: View {
    let words: String

    var body: some View {
        Label {
            Text(words)
        } icon: {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Replies another session suggested for this one (a supervisor going over what waits on you),
/// above the box as on the Mac, in a solid card: a tap sends one as it is, as your own message (denying the call it
/// waits on, or declining its questions, and saying this instead, as the box would); held, one goes
/// in the box to change first. Dismiss takes them away on its Mac. They go by themselves once
/// something is sent to it or a turn of its starts.
private struct SuggestedRepliesView: View {
    let suggestions: SuggestedReplies
    /// Why they can't be sent now, when they can't; they can still go in the box.
    let blocked: String?
    let send: (String) -> Void
    let edit: (String) -> Void
    let dismiss: () -> Void
    /// Shown whole. Folded, they're a line over the box, so they don't take the conversation's
    /// room until you look.
    @State private var open = false

    var body: some View {
        if open {
            whole
        } else {
            folded
        }
    }

    private var folded: some View {
        let count = suggestions.replies.count
        return Button {
            withAnimation(.snappy) { open = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(.secondary)
                Text(count == 1 ? "A suggested reply" : "\(count) suggested replies")
                    .font(.footnote.weight(.medium))
                    .layoutPriority(1)
                if let by = suggestions.by {
                    Text("· \(by)").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(WaitingCard(tint: nil, padding: 0))
        .contextMenu {
            Button("Dismiss", systemImage: "xmark") { dismiss() }
        }
        .accessibilityLabel(suggestions.by.map { "\(count == 1 ? "A suggested reply" : "\(count) suggested replies") by \($0)" } ?? (count == 1 ? "A suggested reply" : "\(count) suggested replies"))
        .accessibilityHint("Shows them")
    }

    private var whole: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.caption)
                Text(suggestions.by.map { "Suggested by \($0)" } ?? "Suggested replies")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Dismiss", action: dismiss)
                    .font(.caption)
                    .accessibilityHint("Takes these suggestions away")
                Button {
                    withAnimation(.snappy) { open = false }
                } label: {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        .frame(width: 28, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fold them away")
            }
            .foregroundStyle(.secondary)
            if let note = suggestions.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(suggestions.replies.enumerated()), id: \.offset) { _, reply in
                Button {
                    if blocked == nil { send(reply) } else { edit(reply) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(reply)
                            .font(.subheadline)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: blocked == nil ? "arrow.up.circle.fill" : "square.and.pencil")
                            .foregroundStyle(blocked == nil ? Color.accentColor : .secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
                .contextMenu {
                    if blocked == nil {
                        Button("Send", systemImage: "arrow.up") { send(reply) }
                    }
                    Button("Change before sending", systemImage: "square.and.pencil") { edit(reply) }
                    Button("Dismiss all", systemImage: "xmark") { dismiss() }
                }
                .accessibilityHint(blocked ?? "Sends this as your reply")
            }
            if let blocked {
                Text(blocked).font(.caption2).foregroundStyle(.secondary)
            }
        }
        // Solid, as what waits on you is: over the conversation they were hard to read.
        .modifier(WaitingCard(tint: nil))
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
    /// Opened at the newest and not scrolled by you since.
    var settling = true
    /// The bars came in and moved it off the newest: it's going back, and no page is read above
    /// until it's there.
    var backToEnd = false
    /// Counts the places it's been sent to, a prompt or the newest: a prompt being read back to
    /// goes there only if it's still the last one asked for.
    var trip = 0

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
        /// What's over the foot: the box and what's above it, and the keyboard.
        var bottom: CGFloat = 0
        var height: CGFloat
        var atEnd = false
        var scrolledUp = false
        var top: CGFloat { offset + inset }
    }
}

private extension ScrollGeometry {
    /// Scrolled to the newest: the foot of what's in view, above the reply box, is at the end. Not
    /// by the container's height, which leaves out the bars' insets: with them it said a
    /// conversation at its end was scrolled up, and new messages didn't keep it there.
    var atEnd: Bool { visibleRect.maxY - contentInsets.bottom >= contentSize.height - 60 }
    /// Scrolled far enough up that the newest is out of sight: more than half a screen, so reading
    /// the last reply a little way up doesn't bring the button over it.
    var scrolledUp: Bool { contentSize.height - (visibleRect.maxY - contentInsets.bottom) > containerSize.height / 2 }
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

/// Down to the newest, over the foot of the conversation while you've scrolled up from it.
private struct ToNewest: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Go to the newest")
    }
}

/// Your prompt behind what's in view, two lines of it over the top of the conversation; a tap
/// brings the whole of it up.
private struct PinnedPrompt: View {
    let text: String
    let action: () -> Void

    var body: some View {
        let (line, images) = Self.line(text)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(images > 0 ? "\(Text(Image(systemName: "photo")).foregroundStyle(.secondary)) \(line)" : "\(line)")
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
        .accessibilityLabel(images == 0 || !Self.hasWords(text) ? "Your prompt: \(line)" : "Your prompt, with \(images == 1 ? "an image" : "\(images) images"): \(line)")
        .accessibilityHint("Shows it in the conversation")
    }

    /// The prompt as a line: its words, on one line, without the images it refers to, which a
    /// photo sign stands for; one of images alone says how many.
    static func line(_ text: String) -> (String, images: Int) {
        let parts = promptParts(text: text)
        let images = parts.count { $0.kind == .image }
        let words = parts.filter { $0.kind != .image }.map(\.text).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !words.isEmpty || images == 0 { return (words, images) }
        return (images == 1 ? "An image" : "\(images) images", images)
    }

    /// It has words besides its images: the line is them, and doesn't say the images.
    static func hasWords(_ text: String) -> Bool {
        promptParts(text: text).contains { $0.kind != .image && !$0.text.allSatisfy(\.isWhitespace) }
    }
}

/// A piece of the conversation: something said, or a run of tool calls.
private enum Entry: Identifiable {
    case said(Item)
    case tools([Item])

    /// The conversation as it reads: what was said, and each run of tool calls between as one. A
    /// call that made a page is one to open: the calls around it fold, and it stays in view.
    static func of(_ items: [Item]) -> [Entry] {
        var out: [Entry] = []
        var run: [Item] = []
        for item in items {
            // A call that made a page, or handed you files, stays in view.
            if item.kind == .tool && item.link == nil && item.files.isEmpty {
                run.append(item)
                continue
            }
            if item.kind == .tool {
                if !run.isEmpty { out.append(.tools(run)) }
                run = []
                out.append(.tools([item]))
                continue
            }
            if !run.isEmpty { out.append(.tools(run)) }
            run = []
            out.append(.said(item))
        }
        if !run.isEmpty { out.append(.tools(run)) }
        return out
    }

    var id: String {
        switch self {
        case .said(let item): item.id
        case .tools(let calls): "run:" + (calls.first?.id ?? "")
        }
    }
}

/// One thing said: your prompts on the right, the agent's replies as text, notes small between. A
/// prompt the session took back before its agent answered says so, and can go back in the box.
private struct ItemView: View {
    let item: Item
    var putBack: ((String) -> Void)?
    /// Goes on from just before this prompt of yours with an edit of it, where it can.
    var editFrom: (() -> Void)?

    var body: some View {
        switch item.kind {
        case .you where item.input != nil:
            // A command you ran in the session's shell, as typed there, led by its `!`, and what
            // it printed.
            VStack(alignment: .leading, spacing: 6) {
                Block(text: "! \(item.input ?? "")")
                if let output = item.output, !output.isEmpty { Block(text: output, failed: item.failed) }
            }
            .padding(.leading, 40)
        case .you:
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer(minLength: 40)
                    PromptText(text: item.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(item.withdrawn ? 0.06 : 0.15), in: .rect(cornerRadius: 16))
                        .foregroundStyle(item.withdrawn ? .secondary : .primary)
                        .textSelection(.enabled)
                        .modifier(EditFromMenu(text: item.text, edit: editFrom))
                }
                if item.withdrawn {
                    Text("Taken back: the turn was stopped before a reply, so the agent never saw this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    if let putBack {
                        Button("Put back in the box", systemImage: "arrow.uturn.backward") { putBack(item.text) }
                            .font(.caption)
                    }
                }
            }
        case .agent:
            MarkdownText(text: item.text)
        case .tool:
            ToolLine(item: item)
        case .note:
            Text(verbatim: item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .peer:
            PeerMessage(item: item)
        case .codealong:
            // What Codealong sent by itself, under its name, quieter than the agent's words.
            VStack(alignment: .leading, spacing: 4) {
                Text("Codealong")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                MarkdownText(text: item.text)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Another session's message, whole, under who sent it: a long one cut to its first lines until
/// it's opened, as the Mac's thread shows one (SessionThread.tsx `PeerText`).
private struct PeerMessage: View {
    let item: Item
    @State private var opened = false
    @State private var long = false
    @ScaledMetric(relativeTo: .body) private var cut: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.from.map { "From “\($0)”" } ?? "From another session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            MarkdownText(text: item.text)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Bool.self) { $0.size.height > cut + 1 } action: { long = $0 }
                .frame(maxHeight: opened ? nil : cut, alignment: .top)
                .clipped()
                // The cut fades out, so it reads as more to come.
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: long && !opened ? 0.8 : 1), .init(color: .black.opacity(long && !opened ? 0 : 1), location: 1)], startPoint: .top, endPoint: .bottom)
                }
            if long {
                Button(opened ? "Show less" : "Show all") { opened.toggle() }
                    .font(.caption)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Capsule().fill(.quaternary).frame(width: 3)
        }
    }
}

/// A message on its way from here, at the end of the conversation until the session's record has
/// it: sending, then sent with what its Mac said, as the Mac's thread shows one (SessionThread.tsx
/// `Unsaid`). One the session shows no sign of a while after it went says it may not have reached
/// it, and can be put away.
private struct OutgoingView: View {
    let outgoing: Outgoing
    /// Its session's harness holds it until the turn it's taking ends: it says so for as long.
    var held = false
    let dismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let unconfirmed = isUnconfirmed(at: context.date)
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 40)
                    PromptText(text: outgoing.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(sent ? 0.15 : 0.08), in: .rect(cornerRadius: 16))
                        .foregroundStyle(sent ? .primary : .secondary)
                }
                Text(unconfirmed ? "Not in the session yet" : state)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if unconfirmed {
                    Text("It went, but the session hasn’t shown it. It may not have reached it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Button("Stop showing this", systemImage: "xmark", action: dismiss)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var sent: Bool {
        if case .sent = outgoing.state { true } else { false }
    }

    private var state: String {
        if held { return HeldView.words }
        return switch outgoing.state {
        case .queued, .sending: "Sending…"
        case .sent(let message, _, _): message.isEmpty ? "Sent" : message
        }
    }

    private func isUnconfirmed(at now: Date) -> Bool {
        guard !held, case .sent(_, let at, _) = outgoing.state else { return false }
        return now.timeIntervalSince(at) > Outgoing.confirm
    }
}

/// A message the session's harness holds until the turn it's taking ends, whoever sent it, at the
/// end of the conversation after that turn, as the Mac's thread shows one (SessionThread.tsx
/// `NotYetSaid`): faint, saying so, with Send now while the turn would take it sooner, as Steer
/// beside one in the Codex app does.
private struct HeldView: View {
    let message: HeldMessage
    /// Sends it into the turn now; none where the turn can't take it or nothing can be sent here.
    let sendNow: (() -> Void)?
    /// Why Send now didn't, when it didn't.
    let why: String?

    static let words = "Queued until this turn ends"

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 40)
                PromptText(text: message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 16))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(Self.words)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let sendNow {
                    Button("Send now", systemImage: "bolt", action: sendNow)
                        .font(.caption)
                        .accessibilityHint("Into the turn it's taking, rather than once the turn ends")
                }
            }
            if let why {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A prompt of yours as you wrote it, as the Mac shows one: not read as Markdown, its web links
/// opening, the images Codealong kept for it shown above its words (read from its Mac), and the
/// files named.
private struct PromptText: View {
    let text: String
    @Environment(\.imageMac) private var mac

    var body: some View {
        let parts = promptParts(text: text)
        let images = mac == nil ? [] : parts.compactMap { $0.kind == .image ? $0.url : nil }
        let words = images.isEmpty ? parts : Self.trimmed(parts.filter { $0.kind != .image })
        VStack(alignment: .trailing, spacing: 8) {
            // One big; more three to a row, small enough for the narrowest phone's bubble.
            if let mac, !images.isEmpty {
                let side: CGFloat = images.count == 1 ? 180 : 72
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 6), count: min(images.count, 3)), alignment: .trailing, spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, path in
                        KeptImage(mac: mac, path: path, side: side)
                    }
                }
            }
            if !words.isEmpty {
                prompt(words)
            }
        }
    }

    /// The words left once the images are taken out, without the lines they stood on.
    private static func trimmed(_ parts: [PromptPart]) -> [PromptPart] {
        var parts = parts
        if let first = parts.first, first.kind == .text {
            parts[0] = PromptPart(kind: .text, text: String(first.text.drop { $0.isWhitespace }), url: nil)
        }
        if let last = parts.last, last.kind == .text {
            parts[parts.count - 1] = PromptPart(kind: .text, text: String(last.text.reversed().drop { $0.isWhitespace }.reversed()), url: nil)
        }
        return parts.filter { $0.kind != .text || !$0.text.isEmpty }
    }

    private func prompt(_ parts: [PromptPart]) -> Text {
        var out = Text(verbatim: "")
        for part in parts {
            let piece: Text
            switch part.kind {
            case .text:
                piece = Text(verbatim: part.text)
            case .link:
                var link = AttributedString(part.text)
                link.link = part.url.flatMap(URL.init(string:))
                piece = Text(link)
            case .image:
                piece = Text("\(Image(systemName: "photo")) \(part.text)").foregroundStyle(.secondary)
            case .file:
                piece = Text("\(Image(systemName: "doc")) \(part.text)").foregroundStyle(.secondary)
            }
            out = Text("\(out)\(piece)")
        }
        return out
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
        var parts = ["\(earlier.count) tool calls", names.prefix(4).joined(separator: ", ")]
        let failed = earlier.filter(\.failed).count
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

/// A tool call as one quiet line, red when it failed, that opens to what went in and came out. A
/// call that asked you questions says so and opens to them, with what you picked; a page on the
/// web it made or opened (an artifact Claude Code published) is a link under it.
private struct ToolLine: View {
    let item: Item
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                Text(inline(label))
                    .font(.caption)
                    .foregroundStyle(item.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(open ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.failed ? "Failed: \(label)" : label)
            if let link = item.link, let url = URL(string: link.url) {
                HStack(spacing: 6) {
                    Link(destination: url) {
                        Label(link.title, systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                    if let note = link.note {
                        Text(note).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            // The files it handed you, on its Mac, each by its name and folder, with what the
            // agent said with them, as the Mac's line lists them.
            if !item.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let caption = item.caption, !caption.isEmpty {
                        Text(caption).font(.caption)
                    }
                    ForEach(Array(item.files.enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(file.name).font(.caption.weight(.medium))
                            Text(file.folder).font(.caption).foregroundStyle(.tertiary).truncationMode(.head)
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if open {
                if !item.questions.isEmpty {
                    AskedList(questions: item.questions)
                    // Declined, or refused: why, from its result. Answered, the picks say it all.
                    if item.failed, let output = item.output, !output.isEmpty { Block(text: output, failed: true) }
                } else {
                    if let input = item.input, !input.isEmpty { Block(text: input) }
                    if let output = item.output, !output.isEmpty { Block(text: output, failed: item.failed) }
                }
            }
        }
    }

    /// A question call's line: what it asks about, by the questions' headers when they all have one.
    private var label: String {
        guard let first = item.questions.first else { return item.text }
        let headers = item.questions.compactMap(\.header)
        return "Asks you · " + (headers.count == item.questions.count ? headers.joined(separator: ", ") : first.question)
    }
}

/// Questions a session asked, with each choice and, once answered, what you picked, as the Mac's
/// QuestionList.tsx lays them out.
private struct AskedList: View {
    let questions: [Question]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions, id: \.question) { q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(inline((q.header.map { "**\($0)** · " } ?? "") + q.question)).font(.caption)
                    ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                        let picked = q.picked.contains(o.label)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "\(i + 1).").monospacedDigit()
                            Text(o.label).fontWeight(picked ? .semibold : .regular)
                            if picked { Image(systemName: "checkmark").accessibilityLabel("Your pick") }
                        }
                        .font(.caption)
                        .foregroundStyle(picked ? .primary : .secondary)
                    }
                    if !q.own.isEmpty {
                        Text("Your answer: \(q.own.joined(separator: ", "))").font(.caption).foregroundStyle(.primary)
                    }
                    if !q.answered && questions.contains(where: \.answered) {
                        Text("Not answered").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}

/// Inline Markdown, code spans and emphasis, keeping the text's own line breaks, with its links
/// settled as the Mac settles them (the core's `inline_markdown`): web links open, bare ones too.
private func inline(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    let settled = inlineMarkdown(text: s)
    return (try? AttributedString(markdown: settled, options: options)) ?? AttributedString(s)
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

/// A tool's input or output as it was written, every character of it, its web links opening (the
/// core's `linked_output`), scrolling both ways past a few lines, with a button that copies it.
private struct Block: View {
    let text: String
    var failed = false
    /// How tall the text is: the box is as tall, up to a point, and scrolls past it.
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(linked)
                .font(.caption2.monospaced())
                .foregroundStyle(failed ? .red : .primary)
                .textSelection(.enabled)
                .padding(8)
                .padding(.trailing, 28)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(max(height, 32), 220))
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollBounceBehavior(.basedOnSize)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { CopyButton(text: text) }
    }

    private var linked: AttributedString {
        var out = AttributedString()
        for span in linkedOutput(text: text) {
            var piece = AttributedString(span.text)
            if let url = span.url.flatMap(URL.init(string:)) { piece.link = url }
            out += piece
        }
        return out
    }
}

/// What the phone keeps of a session's conversation: what a swipe slides in beside the session
/// shown.
struct Kept: Sendable {
    var items: [Item] = []
    var hasOlder = false
    /// What it waits on you for, read with it.
    var pending: Pending?
    /// How a message gets there, as its Mac said then.
    var way: Way?
}

/// What a session's reply box says before you write: why it can't take a reply, what one does to
/// the call it waits on, else how a message gets there (`otherwise`).
private func replyWords(why: String?, pending: Pending?, account: String?, otherwise: () -> String) -> String {
    if let why { return why }
    if pending?.cannot != nil { return "It waits on you where it runs: send once that's answered" }
    // Questions are declined, as the Mac's box says it; a call is denied.
    if let pending, let account {
        return pending.questions.isEmpty ? "Deny it and tell \(account) what to do instead" : "Decline it and write to \(account) instead"
    }
    return otherwise()
}

/// What a session's screen opens with when a swipe slid it in: what the swipe drew of it.
struct Opening {
    let kept: Kept
    /// How the session gone on from went.
    let said: String?
}

/// A session beside the one shown, as a swipe brings it in: what the phone keeps of its
/// conversation, at its newest, and its reply box as its own screen first draws it. Drawn as that
/// screen draws them, so the screen takes its place without a change.
struct SessionGlance: View {
    let key: String
    let kept: Kept
    /// How the session gone on from went, as this one's screen will say it.
    let said: String?
    /// The page a swipe goes on from to this one, and whether going on takes it out of what waits
    /// on you (marked done or archived) or sends it round after the rest (marked seen, it stays
    /// there until its Mac's feed has it seen): nil going back to one.
    var from: (key: String, leaves: Bool)?
    @Environment(Store.self) private var store
    @AppStorage("project") private var project = ""
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32
    /// More than a screen of the conversation's end: what's above it is off the top.
    private let shown = 40

    private var row: SessionRow? { store.sessions.first { $0.key == key } }
    private var why: String? { store.cannotReach(row) }
    private var rules: ReplyRules {
        ReplyRules(row: row, way: kept.way, choices: row.flatMap { store.choices[$0.device] }, resumePlace: nil)
    }
    /// What waits on you after it, as its screen will have it once the swipe has gone on.
    private var after: [Waiting] { waitingAfter(key, from: from, store: store, project: project) }
    /// Where going on from it goes, as its screen will have it: gone on to, it's part of what
    /// you're going through.
    private var onward: Onward? { Onward.of(after, goingThrough: from != nil || store.goingThrough(key, project: project)) }

    var body: some View {
        glance.environment(\.imageMac, row?.device)
    }

    @ViewBuilder
    private var glance: some View {
        let entries = Entry.of(kept.items)
        // Its newest at the foot, what doesn't fit going off the top: laid over a screen's worth of
        // nothing, so it's a screen high however long the conversation is (a frame that fills the
        // screen grows to fit what's in it, and pushed the screen beside it down).
        Color.clear.overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                if !kept.items.isEmpty && !kept.hasOlder && entries.count <= shown {
                    Text("The start of the session")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                    if let origin = row?.origin {
                        let listed = store.sessions.contains { $0.key == origin.key }
                        Text("\(origin.fork ? "Forked from" : "Started by") \(origin.title.map { "“\($0)”" } ?? "another session")")
                            .font(.caption)
                            .foregroundStyle(listed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(entries.suffix(shown)) { entry in
                    switch entry {
                    case .said(let item): ItemView(item: item, putBack: why == nil && item.kind == .you ? { _ in } : nil)
                    case .tools(let calls): ToolRun(calls: calls)
                    }
                }
                ForEach(store.outgoing[key] ?? []) { o in
                    OutgoingView(outgoing: o) {}
                }
                if kept.items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                // The session's screen ends its conversation with a mark to scroll to.
                Color.clear.frame(height: 1)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .clipped()
        // Its top fades out, as the conversation does going up under the bar.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                Color.black
            }
        }
        .safeAreaInset(edge: .bottom) { reply }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The reply box and what's over it, as the session's screen first draws them, from what was
    /// read with its conversation.
    private var reply: some View {
        let canAct = why == nil
        let pending = kept.pending
        let draft = store.drafts[key] ?? ""
        let attached = store.attached[key] ?? []
        let words = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // As the screen's `canSend`: images alone are a reply once each is kept on its Mac.
        let ready = canAct && pending?.cannot == nil && (words || (!attached.isEmpty && pending == nil)) && !attached.contains { $0.state == .keeping }
        let open = !draft.isEmpty || !attached.isEmpty
        return VStack(spacing: 8) {
            if let pending {
                if pending.questions.isEmpty || pending.cannot != nil {
                    ApprovalCard(pending: pending, hosted: row?.hosted == true, canAct: canAct, why: why, answering: nil) { _ in }
                } else {
                    QuestionsCard(pending: pending, account: row?.account ?? "It", hosted: row?.hosted == true, canAct: canAct, why: why, answering: nil) { _ in } decline: {}
                }
            }
            if let limit = row?.limit {
                Label {
                    Text(Clock.text(limit, now: .now))
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.100percent").foregroundStyle(.orange)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let lost = row?.connectionLost {
                LostConnection(words: lost)
            }
            if let cut = row?.cutOff {
                SessionNote(words: cut, symbol: "scissors", tint: .orange)
            }
            if row?.flagged == true {
                SessionNote(words: SessionNote.flagged, symbol: "flag.fill", tint: .red)
            }
            if let said {
                Text(said).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let next = onward, !open {
                GoOnBar(next: next, more: after.count - 1, showDevice: store.devices.count > 1, showProject: project.isEmpty, going: Going.of(.seen, row: row, pending: pending, acted: !(store.outgoing[key] ?? []).isEmpty), picked: SwipeOn.seen.label, choices: { EmptyView() }) {}
            }
            if let suggestions = row?.suggestions {
                SuggestedRepliesView(suggestions: suggestions, blocked: canAct && pending?.cannot == nil ? nil : why ?? "It waits on you where it runs: answer that there first") { _ in } edit: { _ in } dismiss: {}
            }
            // Folded unless something's written or attached, and buttons as the screen's are,
            // dimmed as theirs are while there's nothing to send.
            ReplyBox(open: open, size: sendSize, attach: canAct && pending == nil ? {} : nil) {
                if canAct && pending == nil && !attached.isEmpty {
                    AttachedRow(images: attached) { _ in }
                }
            } field: {
                let placeholder = replyWords(why: why, pending: pending, account: row?.account) {
                    let words = store.replyPlaceholder(key, way: kept.way, resumePlace: rules.resuming ? rules.resumeAt?.id : nil, behind: rules.resuming && rules.resumeAt?.behind == true)
                    return open ? words.full : words.short
                }
                Text(draft.isEmpty ? placeholder : draft)
                    .foregroundStyle(draft.isEmpty ? .tertiary : .primary)
                    .lineLimit(draft.isEmpty ? 2 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } tools: {
                if canAct && (rules.resuming || rules.showsModel) {
                    ModelMenu(rules: rules, resumePlace: .constant(nil), resumeModel: .constant(nil), resumeEffort: .constant(nil), switching: false, height: sendSize) { _ in }
                }
                if canAct && row?.steerable == true && pending == nil {
                    Button {} label: { SendNowMark(size: sendSize) }
                        .buttonStyle(.plain)
                        .disabled(!ready)
                }
            } action: {
                if canAct && row?.stoppable == true && !words && attached.isEmpty {
                    Button {} label: { StopMark(stopping: false, size: sendSize) }
                        .buttonStyle(.plain)
                } else {
                    Button {} label: { SendMark(ready: ready, size: sendSize) }
                        .buttonStyle(.plain)
                        .disabled(!ready)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

/// Between the reply box's buttons and its edge.
private let replyInset: CGFloat = 6

/// The reply box, a control in glass as Codex's phone app draws its own, at the foot of the
/// conversation, which goes under it at a hard edge rather than reading through it. While you
/// aren't writing it's folded to a line: photos, who a message goes to, and send, or stop while a
/// turn runs. Open, its field has the box's width to itself, over a row of its buttons: photos on
/// the left; the model, send now and send or stop on the right. The session's screen and a glance
/// of it both draw it, so a session slid in looks as its screen will.
private struct ReplyBox<Above: View, Field: View, Tools: View, Action: View>: View {
    let open: Bool
    /// The send button's, which a line of the box matches.
    let size: CGFloat
    /// Picks photos to go with the reply; nil where none can go.
    let attach: (() -> Void)?
    let attachDisabled: Bool
    let above: Above
    let field: Field
    /// Beside the action while it's open.
    let tools: Tools
    /// Send, or stop.
    let action: Action
    /// The box's words are this much further in than its buttons, clear of its round corners.
    private let textInset: CGFloat = 10

    init(open: Bool, size: CGFloat, attach: (() -> Void)?, attachDisabled: Bool = false, @ViewBuilder above: () -> Above, @ViewBuilder field: () -> Field, @ViewBuilder tools: () -> Tools, @ViewBuilder action: () -> Action) {
        self.open = open
        self.size = size
        self.attach = attach
        self.attachDisabled = attachDisabled
        self.above = above()
        self.field = field()
        self.tools = tools()
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            above
            // The field keeps its place whichever way the box is, so it keeps the keyboard as the
            // box opens around it.
            HStack(alignment: .bottom, spacing: 8) {
                if !open { photos }
                field
                    .frame(maxWidth: .infinity, minHeight: size, alignment: .leading)
                    .padding(.leading, open || attach == nil ? textInset : 0)
                    .padding(.trailing, open ? textInset : 0)
                if !open { action }
            }
            if open {
                HStack(alignment: .bottom, spacing: 8) {
                    photos
                    Spacer(minLength: 0)
                    tools
                    action
                }
            }
        }
        .padding(replyInset)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: size / 2 + replyInset))
        .animation(.snappy(duration: 0.25), value: open)
    }

    @ViewBuilder
    private var photos: some View {
        // Photos go with the reply, kept on its Mac as they're picked.
        if let attach {
            Button(action: attach) {
                Image(systemName: "plus")
                    .font(.system(size: size / 2, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(attachDisabled)
            .accessibilityLabel("Attach photos")
        }
    }
}

/// Send's face: the accent while there's something to send, a quiet grey while there isn't.
private struct SendMark: View {
    let ready: Bool
    var sending = false
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(ready ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            if sending {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: size / 2, weight: .bold))
                    .foregroundStyle(ready ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Stop's face, in send's place while a turn runs: a square on the text's color, as Codex's is.
private struct StopMark: View {
    let stopping: Bool
    let size: CGFloat
    /// Black, or white in dark mode, as a color of its own: the glass draws the text's own color
    /// (`.primary`) faded into it, a grey that read as a button you can't press.
    private let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : .black })

    var body: some View {
        ZStack {
            Circle().fill(ink)
            if stopping {
                ProgressView().controlSize(.small).tint(Color(.systemBackground))
            } else {
                Image(systemName: "stop.fill")
                    .font(.system(size: size / 2.6, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Send now's face: into the turn it's taking, at once.
private struct SendNowMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: size / 2.4, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .contentShape(.circle)
    }
}

/// How a session takes a reply, from what its Mac says: where one that isn't running goes on, and
/// on what; a running one's model, and whether it can be switched.
private struct ReplyRules {
    let row: SessionRow?
    let way: Way?
    /// What its Mac can start, for its account's models and the places it can go on in.
    let choices: StartChoices?
    /// Where it goes on, picked: nil for what its Mac offers first.
    let resumePlace: String?

    /// Its account, as its Mac offers it for starts.
    var account: StartAccount? { choices?.accounts.first { $0.name == row?.account } }

    /// It isn't running, and its Mac lets you pick where it goes on.
    var resuming: Bool {
        guard case .resume = way, row?.live != true else { return false }
        return account?.resumes.isEmpty == false
    }

    /// Where it goes on: the place picked, else the one its Mac's offers suit a phone best.
    var resumeAt: StartPlace? {
        let places = account?.resumes ?? []
        return places.first { $0.id == resumePlace } ?? places.first { $0.id == account?.resume } ?? places.first
    }

    /// That place takes a model and effort: the command line and Codealong do, the apps choose.
    var resumeTakesModel: Bool {
        ["terminal", "background", "codealong"].contains(resumeAt?.id ?? "")
    }

    /// What its Mac sends it goes to an app that runs it on its own model and effort (the Codex
    /// app, Cursor, OpenCode), running or not.
    var goesOnWithIt: Bool {
        switch way {
        case .cursor, .codexApp, .opencode: true
        default: false
        }
    }

    /// Its app takes a switch of model or effort whenever, for its next turn (the Codex app's).
    var inApp: Bool { goesOnWithIt && account?.switchesInApp == true }

    /// It's running where Codealong can switch it: one Codealong runs, or one its Mac types into.
    private var switchable: Bool {
        guard let row, row.live else { return false }
        if row.hosted { return true }
        if case .typed = way { return true }
        return false
    }

    /// It can be switched to another of its account's models, as the Mac's reply box has it: one
    /// Codealong runs, one its Mac types into where its harness's command does it, or one whose
    /// app takes a switch.
    var switchesModel: Bool {
        guard let row, let account, !account.models.isEmpty else { return false }
        return inApp || (switchable && (row.hosted || account.switchesModel))
    }

    /// It can be switched to another of its account's effort levels, as its model can.
    var switchesEffort: Bool {
        guard let row, let account, !account.efforts.isEmpty else { return false }
        return inApp || (switchable && (row.hosted || account.switchesEffort))
    }

    /// One Codealong runs switches to another of the modes its agent offers, any time.
    var switchesMode: Bool {
        guard let row, row.live, row.hosted else { return false }
        return row.modes.filter { !$0.id.isEmpty }.count > 1
    }

    /// A switch of model or effort waits while its turn runs or it waits on you, where the command
    /// would go in as a prompt or answer it; an app takes one whenever, for the next turn.
    var switchWaits: Bool {
        guard !inApp, let row else { return false }
        return row.status == .working || row.status == .needs || row.stalled
    }

    /// It says what it's on beside the box: a running one, or one an app goes on with.
    var showsModel: Bool {
        guard let row, !resuming, row.live || goesOnWithIt else { return false }
        return switchesModel || switchesEffort || switchesMode || row.model != nil || row.effort != nil
    }
}

/// The model a reply goes on with, in the reply box beside send: a running session's, which
/// switches where its Mac can; for one that isn't running, where it goes on, and on what.
private struct ModelMenu: View {
    let rules: ReplyRules
    @Binding var resumePlace: String?
    @Binding var resumeModel: String?
    @Binding var resumeEffort: String?
    let switching: Bool
    /// The send button's, so it lines up with it.
    let height: CGFloat
    /// The mode it's in, as switched here until its Mac says: by its id.
    var modePicked: String? = nil
    let switchModel: (String) -> Void
    var switchEffort: (String) -> Void = { _ in }
    var switchMode: (String) -> Void = { _ in }

    var body: some View {
        // Quiet, as the box's words are: not a link's accent.
        menu.tint(.secondary)
    }

    @ViewBuilder
    private var menu: some View {
        if rules.resuming, let account = rules.account {
            let takesModel = rules.resumeTakesModel && !account.models.isEmpty
            let model = (resumeModel ?? account.defaultModel).map { modelName(model: $0, models: account.models) } ?? "Default model"
            let effort = account.efforts.first { $0.id == resumeEffort }?.label
            let place = rules.resumeAt?.label ?? "a terminal"
            Menu {
                Section("Goes on in") {
                    Picker("Goes on in", selection: Binding(get: { rules.resumeAt?.id }, set: { resumePlace = $0 })) {
                        ForEach(account.resumes, id: \.id) { p in
                            Text(p.behind ? "\(p.label) (behind its windows)" : p.label).tag(Optional(p.id))
                        }
                    }
                }
                if takesModel {
                    Section("Model") {
                        Picker("Model", selection: $resumeModel) {
                            Text(account.defaultModel.map { "Default (\(modelName(model: $0, models: account.models)))" } ?? "Default").tag(String?.none)
                            ForEach(account.models, id: \.id) { m in Text(m.label).tag(Optional(m.id)) }
                        }
                    }
                    if !account.efforts.isEmpty {
                        Section("Effort") {
                            Picker("Effort", selection: $resumeEffort) {
                                Text("Default effort").tag(String?.none)
                                ForEach(account.efforts, id: \.id) { e in Text(e.label).tag(Optional(e.id)) }
                            }
                        }
                    }
                }
            } label: {
                // On what, and under it where.
                if takesModel {
                    label([model, effort].compactMap { $0 }.joined(separator: " · "), under: "in \(place)")
                } else {
                    label("in \(place)")
                }
            }
            .accessibilityLabel(takesModel ? "Goes on in \(place) on \(model)\(effort.map { ", \($0) effort" } ?? "")" : "Goes on in \(place)")
        } else if rules.showsModel {
            let model = rules.row?.model.map { modelName(model: $0, models: rules.account?.models ?? []) }
            let effort = rules.row?.effort
            let shown = [model, effort].compactMap { $0 }.joined(separator: " · ")
            let modes = (rules.row?.modes ?? []).filter { !$0.id.isEmpty }
            let mode = modes.first { $0.id == modePicked } ?? rules.row?.mode
            let words = shown.isEmpty ? (mode?.label ?? "Model") : shown
            let under = shown.isEmpty ? nil : mode?.label
            let spoken = "\(model.map { "Model: \($0)" } ?? "Model")\(effort.map { ", \($0) effort" } ?? "")\(mode.map { ", \($0.label) mode" } ?? "")"
            if let account = rules.account, rules.switchesModel || rules.switchesEffort || rules.switchesMode {
                // A switch of model or effort waits for the turn, where the command would go in as
                // a prompt or answer it; an app takes one for its next turn, and a mode any time.
                let waits = switching || rules.switchWaits
                Menu {
                    if rules.switchesModel {
                        Section(waits && !switching ? "Model, once its turn ends" : "Model") {
                            // Which of the names it's on isn't known for sure (a reply names the
                            // model without its context size), so none is checked; the label says it.
                            ForEach(account.models, id: \.id) { m in
                                Button(m.label) { switchModel(m.id) }
                            }
                        }
                        .disabled(waits)
                    }
                    if rules.switchesEffort {
                        // The levels as the Mac's chip says them (`xhigh`), the one it's on checked.
                        Section(waits && !switching ? "Effort, once its turn ends" : "Effort") {
                            ForEach(account.efforts, id: \.id) { e in
                                Button {
                                    if e.id != effort { switchEffort(e.id) }
                                } label: {
                                    if e.id == effort { Label(e.id, systemImage: "checkmark") } else { Text(e.id) }
                                }
                            }
                        }
                        .disabled(waits)
                    }
                    if rules.switchesMode {
                        Section("Mode") {
                            ForEach(modes, id: \.id) { m in
                                Button {
                                    if m.id != mode?.id { switchMode(m.id) }
                                } label: {
                                    if m.id == mode?.id {
                                        Label(m.label, systemImage: "checkmark")
                                    } else {
                                        Text(m.label)
                                    }
                                    Text(m.detail)
                                }
                            }
                        }
                        .disabled(switching)
                    }
                } label: {
                    label(switching ? "Switching…" : words, under: switching ? nil : under)
                }
                .accessibilityLabel(spoken)
                .accessibilityHint(rules.inApp ? "Switches this session's model or effort, for it alone, from its next turn" : "Switches this session's model, effort or mode, for it alone")
            } else {
                label(words, under: under, menu: false)
                    .accessibilityLabel(spoken)
            }
        }
    }

    private func label(_ text: String, under: String? = nil, menu: Bool = true) -> some View {
        UpToWide(most: 130) {
            HStack(spacing: 3) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(text)
                    if let under {
                        Text(under).font(.caption2.weight(.regular)).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                if menu {
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
            }
        }
        // A size under the box's words, so it reads as a setting of the box, not something said.
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(height: height)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
    }
}

/// As tall as the scroll view in it needs, up to `most`, past which it scrolls. Worked out in the
/// layout it's drawn in, so it's never drawn at another height first, as a height measured once
/// drawn was for a frame when a swipe slid its session in.
private struct UpTo: Layout {
    let most: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let needs = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? needs.width, height: min(needs.height, most))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// As wide as what's in it needs, up to `most`, past which its words are cut. A frame with a
/// greatest width takes all of it whenever it's offered: beside send, a short model's name took
/// the whole 130 points and squeezed the reply box's field to the left.
private struct UpToWide: Layout {
    let most: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? .infinity, most)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A prompt of yours opens Edit from here's sheet by its id.
extension Item: Identifiable {}
