import SwiftUI

/// One session: its conversation, what it waits on you to allow, and a box to reply. It follows the
/// session as it goes: a change in the Mac's feed brings in what came since.
///
/// It also works through what waits on you, as the Mac's session panel does with ⌘⏎: once you've
/// replied or answered, the most urgent session still waiting on you is a tap away above the box,
/// and holding Send sends and goes on at once. The chevron at the top skips to it; one skipped
/// comes round again after the rest.
///
/// The box says how a message gets there, as its Mac says (typed into its terminal, its
/// background job, a message from Codealong). While it waits on a call that can be answered here,
/// what you send denies the call and tells it that instead, as Claude Code's own "No, and tell
/// Claude what to do differently" does. One that isn't running goes on where you pick, on the
/// model you pick, where its Mac offers a choice; a running one says its model beside the box, and
/// switches it where its Mac can. Where its turn can take a message at once, the bolt beside Send
/// sends it into the turn. `/fork [prompt]` forks it into a copy that goes on in the background on
/// its Mac, and you stay where you are, as on the Mac.
///
/// A message goes as the Mac's windows send one: the box clears at once and the message shows at
/// the end of the conversation as sending, then sent, until the session's record has it, so you
/// can go on writing the next; messages to one session go in the order you sent them. One that
/// doesn't go is back in the box, with why. Swiping across the conversation goes along what waits
/// on you: to the left the next, as the Mac's ⌘] does, and to the right back to the session you
/// came from. Dragging the conversation, or tapping it, puts the keyboard away.
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
    /// How far a swipe across the conversation has gone, while it goes.
    @State private var swipe: CGFloat = 0
    @State private var sending = false
    @State private var said: String?
    /// The reply it's writing, while it takes a turn Codealong runs on its Mac.
    @State private var live: Live?
    @State private var watching = false
    @State private var stopping = false
    /// Scrolled to the newest: new items keep it there. Scrolled up to read, it stays put.
    @State private var atBottom = true
    /// How a message gets to it, as its Mac last said.
    @State private var way: Way?
    /// What its Mac can start, for its account's models and the places it can go on in.
    @State private var choices: StartChoices?
    /// Where it goes on, and on what, while it isn't running: nil for what its Mac offers first.
    @State private var resumePlace: String?
    @State private var resumeModel: String?
    @State private var resumeEffort: String?
    @State private var switching = false
    /// When Mark as done was last held here by work under way: done again soon after ends that too.
    @State private var heldAt: Date?
    @State private var finishing = false
    /// You marked it unread here: it's left Your turn, and the screen goes back to the list.
    @State private var markedUnread = false
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var typing: Bool
    /// The send button's size, which a line of the reply box matches; it grows with the text size.
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32
    /// Between the send button and the reply box's edge.
    private let replyInset: CGFloat = 6
    /// Reads the page before once you're this close to the top, so it's usually in before you
    /// get there: a page comes from the Mac, which can take a moment.
    private let nearTop: CGFloat = 900

    private var row: SessionRow? { store.sessions.first { $0.key == key } }
    /// What you've written here and not sent: the store keeps it, so it's still here when you come
    /// back, and a message that didn't go comes back to it.
    private var draft: String {
        get { store.drafts[key] ?? "" }
        nonmutating set { store.drafts[key] = newValue.isEmpty ? nil : newValue }
    }
    /// The session you went on from to this one: swiping back goes there.
    private var before: SessionRow? { store.previous(of: key) }
    /// A swipe goes along the queue once it's gone this far, or flicked.
    private let swipeFar: CGFloat = 90
    /// What waits on you after this one; the first is next.
    private var after: [SessionRow] { store.queue(after: key, project: project) }

    /// The conversation as it reads: what was said, and each run of tool calls between as one. A
    /// call that made a page is one to open: the calls around it fold, and it stays in view.
    private var entries: [Entry] {
        var out: [Entry] = []
        var run: [Item] = []
        for item in items {
            if item.kind == .tool && item.link == nil {
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
                    ForEach(entries) { entry in
                        switch entry {
                        case .said(let item) where item.kind == .you:
                            ItemView(item: item, putBack: canAct ? { draft = $0 } : nil)
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
                    ForEach(store.outgoing[key] ?? []) { o in
                        OutgoingView(outgoing: o) { store.dismissOutgoing(key, id: o.id) }
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
            .offset(x: swipeOffset)
            .gesture(QueueSwipe(moved: { swipe = $0 }, ended: swiped))
            .overlay(alignment: swipe < 0 ? .trailing : .leading) { swipeHint }
            .sensoryFeedback(.selection, trigger: abs(swipe) >= swipeFar && swipeTarget != nil)
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
                    Button("Rename…", systemImage: "pencil") {
                        newName = row?.name ?? row?.title ?? ""
                        renaming = true
                    }
                    .disabled(!online)
                    Button("Fork", systemImage: "arrow.triangle.branch") { Task { await fork("") } }
                        .disabled(!canAct)
                    if let origin = row?.origin, let title = origin.title {
                        Button(origin.fork ? "Forked from “\(title)”" : "Started by “\(title)”", systemImage: "arrow.turn.left.up") { go(origin.key) }
                            .disabled(!store.sessions.contains { $0.key == origin.key })
                    }
                    Button(finishing ? "Wrapping up…" : "Mark as done", systemImage: "checkmark.circle") { Task { await markDone() } }
                        .disabled(!online || finishing)
                    if row?.unreadable == true {
                        Button("Mark as unread", systemImage: "circle.badge") { Task { await markUnread() } }
                            .disabled(!online)
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
        // How a message gets there changes as it starts and stops running somewhere.
        .task(id: "\(row?.live == true)\(row?.inApp == true)\(online)") { await readWay() }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its harness keeps the name, so it shows there too.")
        }
        // The Mac's feed says the session moved: bring in what came since.
        .onChange(of: row?.lastActivity) { _, _ in Task { await refresh() } }
        // Opened from the feeds saved before its Mac connected, or back after it went away: read
        // what it couldn't.
        .onChange(of: online) { _, now in
            if now { Task { await reconnected() } }
        }
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
            if canAct && (resuming || showsModel) {
                replyTools
            }
            HStack(alignment: .bottom, spacing: 8) {
                // The words before you write say how a message gets there, which takes more than a
                // line on a phone: up to two lines of them sit under the field while it's empty, and
                // the box is as tall as they are.
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField(text: Binding(get: { draft }, set: { draft = $0 }), prompt: Text(""), axis: .vertical) { Text(placeholder) }
                        .lineLimit(1...6)
                        .focused($typing)
                        .disabled(!canAct || sending)
                        // ⌘⏎ on a keyboard sends and goes on, as on the Mac.
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command), canSend else { return .ignored }
                            Task { await send(thenNext: true) }
                            return .handled
                        }
                }
                .frame(minHeight: sendSize)
                if canSendNow {
                    // Into the turn it's taking, at once: Claude Code's send now, Codex's steer.
                    Button {
                        Task { await send(now: true) }
                    } label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: sendSize / 2.4, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: sendSize, height: sendSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send now")
                    .accessibilityHint("Into the turn it's taking, rather than once the step it's on ends")
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
                    if canSendNow {
                        Button {
                            Task { await send(now: true) }
                        } label: {
                            Label("Send now", systemImage: "bolt")
                            Text("Into the turn it's taking")
                        }
                        .disabled(!canSend)
                    }
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

    /// Its Mac is connected: naming it changes only how it's listed, so it needs no remote control.
    private var online: Bool {
        guard let row else { return false }
        return store.devices.contains { $0.key == row.device && $0.online }
    }

    private var canSend: Bool {
        canAct && !sending && !waitsElsewhere && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Its account, as its Mac offers it for starts: its models and the places it can go on in.
    private var account: StartAccount? { choices?.accounts.first { $0.name == row?.account } }

    /// It isn't running, and its Mac lets you pick where it goes on.
    private var resuming: Bool {
        guard case .resume = way, row?.live != true else { return false }
        return account?.resumes.isEmpty == false
    }

    /// Where it goes on: the place picked, else the one its Mac's offers suit a phone best.
    private var resumeAt: StartPlace? {
        let places = account?.resumes ?? []
        return places.first { $0.id == resumePlace } ?? places.first { $0.id == account?.resume } ?? places.first
    }

    /// That place takes a model and effort: the command line and Codealong do, the apps choose.
    private var resumeTakesModel: Bool {
        ["terminal", "background", "codealong"].contains(resumeAt?.id ?? "")
    }

    /// A running one can be switched to another of its account's models: one Codealong runs, or
    /// one its Mac types into, where its harness's command does it.
    private var switchesModel: Bool {
        guard let row, row.live, let account, !account.models.isEmpty else { return false }
        if row.hosted { return true }
        if case .typed = way { return account.switchesModel }
        return false
    }

    /// A running one says its model beside the box.
    private var showsModel: Bool { row?.live == true && (switchesModel || row?.model != nil) }

    private var placeholder: String {
        if !canAct { return whyNot ?? "Reply" }
        if waitsElsewhere { return "It waits on you where it runs: send once that's answered" }
        if denying, let row { return "Deny it and tell \(row.account) what to do instead" }
        return store.replyPlaceholder(key, way: way, resumePlace: resuming ? resumeAt?.id : nil, behind: resuming && resumeAt?.behind == true)
    }

    /// Where it goes on and on what, while it isn't running; its model, while it is.
    private var replyTools: some View {
        HStack(spacing: 8) {
            if resuming, let account {
                Menu {
                    Picker("Goes on in", selection: Binding(get: { resumeAt?.id }, set: { resumePlace = $0 })) {
                        ForEach(account.resumes, id: \.id) { p in
                            Text(p.behind ? "\(p.label) (behind its windows)" : p.label).tag(Optional(p.id))
                        }
                    }
                } label: {
                    ToolChip(symbol: "play.circle", text: "Goes on in \(resumeAt?.label ?? "a terminal")")
                }
                if resumeTakesModel && !account.models.isEmpty {
                    Menu {
                        Picker("Model", selection: $resumeModel) {
                            Text(account.defaultModel.map { "Default (\(modelName(model: $0, models: account.models)))" } ?? "Default").tag(String?.none)
                            ForEach(account.models, id: \.id) { m in Text(m.label).tag(Optional(m.id)) }
                        }
                        if !account.efforts.isEmpty {
                            Picker("Effort", selection: $resumeEffort) {
                                Text("Default effort").tag(String?.none)
                                ForEach(account.efforts, id: \.id) { e in Text(e.label).tag(Optional(e.id)) }
                            }
                        }
                    } label: {
                        let model = (resumeModel ?? account.defaultModel).map { modelName(model: $0, models: account.models) } ?? "Default model"
                        ToolChip(symbol: "cpu", text: [model, account.efforts.first { $0.id == resumeEffort }?.label].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            } else if showsModel {
                let shown = row?.model.map { modelName(model: $0, models: account?.models ?? []) } ?? "Model"
                if switchesModel, let account {
                    Menu {
                        // Which of the names it's on isn't known for sure (a reply names the model
                        // without its context size), so none is checked; the chip says it.
                        ForEach(account.models, id: \.id) { m in
                            Button(m.label) { Task { await switchModel(m.id) } }
                        }
                    } label: {
                        ToolChip(symbol: "cpu", text: switching ? "Switching…" : shown)
                    }
                    // Not while its turn runs or it waits on you: the command would go in as a
                    // prompt, or answer it.
                    .disabled(switching || row?.status == .working || row?.status == .needs)
                    .accessibilityHint("Switches this session's model, for it alone, once its turn ends")
                } else {
                    ToolChip(symbol: "cpu", text: shown, chevron: false)
                }
            }
            Spacer(minLength: 0)
        }
        .tint(.primary)
    }

    private var whyNot: String? {
        guard let row, let device = store.devices.first(where: { $0.key == row.device }) else { return "That session isn't on a linked Mac any more" }
        if !device.online { return "\(device.name) isn't connected" }
        if !device.remoteControl { return "Remote control is off on \(device.name)" }
        return nil
    }

    private func open() async {
        store.showing = key
        sayProblem()
        guard conversation == nil, let conv = store.conversation(key) else { return }
        conversation = conv
        // Moved on to from another: say how that one went.
        if let outcome = store.outcome {
            said = outcome
            store.outcome = nil
        }
        await refresh()
        // Opened from the feeds saved before its Mac answered (the app was just opened, or a link
        // opened it): the Mac is usually there a moment later.
        for _ in 0..<15 where problem != nil && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
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
        if choices == nil { choices = try? await store.startChoices(device) }
    }

    /// Sends the box; with `thenNext`, goes on to what waits on you once it's gone; with `now`,
    /// into the turn it's taking at once. While it waits on a call that can be answered here, it
    /// denies the call and tells it what you wrote instead; while it isn't running, it goes on
    /// where you picked. `/fork [prompt]` forks it instead. One that fails stays, saying why.
    private func send(thenNext: Bool = false, now: Bool = false) async {
        guard let conv = conversation else { return }
        let text = draft
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/fork" || trimmed.hasPrefix("/fork ") {
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
            draft = ""
            said = nil
            store.post(key, title: title, text: text, how: how)
            store.dealtWith(key)
            if thenNext, let next = after.first {
                moveOn(to: next, outcome: "Sending to “\(title)”…")
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
            draft = ""
            typing = false
            done(result, outcome: "Denied “\(title)”, saying what to do instead.", thenNext: thenNext)
        } catch {
            said = words(error)
        }
    }

    /// The conversation moves with a swipe across it: a little, toward the one it goes to; less,
    /// where there's none that way.
    private var swipeOffset: CGFloat {
        swipe * (swipeTarget == nil ? 0.12 : 0.35)
    }

    /// Where the swipe going on would take you: the next to the left, the one before to the right.
    private var swipeTarget: SessionRow? {
        swipe < 0 ? after.first : swipe > 0 ? before : nil
    }

    /// Says where letting go would go, at the edge the conversation leaves.
    @ViewBuilder
    private var swipeHint: some View {
        if let target = swipeTarget {
            let ready = abs(swipe) >= swipeFar
            HStack(spacing: 6) {
                if swipe > 0 { Image(systemName: "chevron.backward") }
                VStack(alignment: swipe < 0 ? .trailing : .leading, spacing: 1) {
                    Text(swipe < 0 ? "Next" : "Back").font(.caption.weight(.semibold))
                    Text(target.title).font(.caption2).lineLimit(1)
                }
                if swipe < 0 { Image(systemName: "chevron.forward") }
            }
            .foregroundStyle(ready ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(maxWidth: 140)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Solid enough to read over the conversation it lies on.
            .background(.thickMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.horizontal, 8)
            .opacity(min(1, abs(swipe) / swipeFar))
            .allowsHitTesting(false)
        }
    }

    /// A swipe let go: far or fast enough toward a session, it goes there; otherwise the
    /// conversation settles back.
    private func swiped(_ distance: CGFloat, _ speed: CGFloat) {
        let far = abs(distance) >= swipeFar || (abs(distance) > 30 && abs(speed) > 600 && (speed < 0) == (distance < 0))
        let target = distance < 0 ? after.first : distance > 0 ? before : nil
        withAnimation(.snappy) { swipe = 0 }
        guard far, let target else { return }
        if distance < 0 {
            moveOn(to: target)
        } else {
            // Back is a step by hand: this one isn't passed over for it.
            store.back(to: target.key)
            store.outcome = acted ? said : nil
            go(target.key)
        }
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
            if let next = after.first {
                moveOn(to: next, outcome: outcome.message)
            } else {
                if outcome.noted { store.notice = outcome.message }
                dismiss()
            }
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
        if next.key != key { store.trail.append(key) }
        store.outcome = outcome ?? (acted ? said : nil)
        go(next.key)
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
                StatusMark(status: next.status, stalled: next.stalled, waiting: next.waitsInBackground)
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
        .padding(14)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 20))
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

/// Questions a session asks you (Claude Code's `AskUserQuestion`): pick a choice, several where a
/// question takes more, or write your own answer; your picks go back as its answer, as the Mac's
/// panel sends them. Decline stops the turn.
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
    /// How tall the questions are: the card is as tall, up to a point, and scrolls past it.
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Asks you").font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
            }
            if pending.unwritten {
                // What it wrote with them isn't in the conversation above yet.
                Text("What \(account) wrote with this question shows in the conversation once it’s answered\(hosted ? "" : "; where it runs on its Mac has it now").")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(pending.questions, id: \.question) { q in
                        question(q)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(height, 360))
            .scrollBounceBehavior(.basedOnSize)
            if canAct {
                HStack {
                    Button(answering == .deny ? "Declining…" : "Decline", role: .destructive, action: decline)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button(answering == .allow ? "Answering…" : "Answer") { answer(answers) }
                        .buttonStyle(.borderedProminent)
                        .disabled(answers.isEmpty)
                }
                .disabled(answering != nil)
            } else if let why {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 20))
    }

    private func question(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let header = q.header {
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
    }

    /// One answer to a question that takes one: a choice clears what was written, as on the Mac.
    private func pick(_ q: Question, _ label: String) {
        let chosen = picks[q.question] ?? []
        picks[q.question] = q.multiSelect ? (chosen.contains(label) ? chosen.filter { $0 != label } : chosen + [label]) : [label]
        if !q.multiSelect { own[q.question] = "" }
    }

    private func type(_ q: Question, _ text: String) {
        own[q.question] = text
        if !q.multiSelect && !text.trimmingCharacters(in: .whitespaces).isEmpty { picks[q.question] = [] }
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

/// A small chip above the reply box: where a session goes on, or its model.
private struct ToolChip: View {
    let symbol: String
    let text: String
    var chevron = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption)
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
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

/// One thing said: your prompts on the right, the agent's replies as text, notes small between. A
/// prompt the session took back before its agent answered says so, and can go back in the box.
private struct ItemView: View {
    let item: Item
    var putBack: ((String) -> Void)?

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
        }
    }
}

/// A message on its way from here, at the end of the conversation until the session's record has
/// it: sending, then sent with what its Mac said, as the Mac's thread shows one (SessionThread.tsx
/// `Unsaid`). One the session shows no sign of a while after it went says it may not have reached
/// it, and can be put away.
private struct OutgoingView: View {
    let outgoing: Outgoing
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
        switch outgoing.state {
        case .queued, .sending: "Sending…"
        case .sent(let message, _): message.isEmpty ? "Sent" : message
        }
    }

    private func isUnconfirmed(at now: Date) -> Bool {
        guard case .sent(_, let at) = outgoing.state else { return false }
        return now.timeIntervalSince(at) > Outgoing.confirm
    }
}

/// A prompt of yours as you wrote it, as the Mac shows one: not read as Markdown, its web links
/// opening, and the images and files Codealong kept for it named (the phone isn't sent them).
private struct PromptText: View {
    let text: String

    var body: some View {
        prompt(promptParts(text: text))
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
                            Text("\(i + 1).").monospacedDigit()
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
