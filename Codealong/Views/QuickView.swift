import PhotosUI
import SwiftUI

/// The app's first screen, as the Mac's quick panel is: an input at the top, and below it what
/// you can do next. With nothing typed it lists the sessions that need you, then the ones whose
/// turn ended (the ones working when nothing waits), then the rest started in the last day; the
/// page menu over the input orders them by project or the last active first instead, or lists
/// PRs, and the pills narrow the list to one project. Typed words find sessions (by what was said
/// in them too) and PRs, a Mac suggests where what's typed goes, over the row at the bottom that
/// starts a new session with it as the prompt, on the Mac, in the worktree, on the account and
/// where the chips under it say, with the photos attached under the input. The core has the rules.
struct QuickView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var showingMacs = false
    @State private var path: [String] = []
    @AppStorage("page") private var page = Page.sessions
    @AppStorage("order") private var order = Order.needs
    /// The project the list is narrowed to, as the Macs line projects up; empty for all of them.
    @AppStorage("project") private var project = ""
    /// Worktrees folded away in the list by project, by their ids, a line each.
    @AppStorage("folded") private var foldedLines = ""
    /// Merged and closed PRs shown, which start folded.
    @State private var showingDone = false
    /// How tall the list is, which the start bar over it mustn't outgrow.
    @State private var listHeight: CGFloat = 0

    @State private var text = ""
    @State private var typing = false
    /// What the Macs' text search found for what's typed, and whether one is still reading.
    @State private var said: [SaidHit] = []
    @State private var saidBuilding = false
    /// A Mac's suggestions for what's typed, and the text they're for.
    @State private var route: RouteAnswer?
    @State private var routedFor = ""
    /// The project and Mac the suggestions are for: they're let go when either changes.
    @State private var routedWhere = ""
    @State private var routing = false
    @State private var routeProblem: String?

    @State private var composer = Composer()
    /// Photos for the prompt, held here until it starts: then they're kept on its Mac, and go
    /// before what's written, as a reply's do.
    @State private var photos: [AttachedImage] = []
    /// The photo picker is open, and what was picked in it.
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    /// Photos picked or pasted and still being read: a start waits for them.
    @State private var loadingPhotos = 0
    @State private var problem: String?
    @State private var acting = false
    /// Starts that went, for the haptic.
    @State private var started = 0
    /// The session a row's Rename… names, and the name as it's typed.
    @State private var renaming: SessionRow?
    @State private var newName = ""
    /// When a row's Mark as done was held by work under way, by session: done again soon after
    /// ends that too.
    @State private var doneHeld: [String: Date] = [:]
    /// What a row's menu asked of a Mac and waits on its answer for, as `<what>:<key>`: asked again
    /// meanwhile, it would go twice (two approvals, two forks).
    @State private var asking: Set<String> = []
    /// The last account, place and Mac you started on, to start with again.
    @AppStorage("start.account") private var lastAccount = ""
    @AppStorage("start.place") private var lastPlace = ""
    @AppStorage("start.device") private var lastDevice = ""

    @Namespace private var pills

    enum Page: String { case sessions, prs }
    enum Order: String { case needs, project, recent }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Where new work goes: the list's project, or Codealong's own while it's being improved.
    private var startProject: String { store.improving?.target.project ?? project }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // The input takes the lines it needs before the list gets any: with the keyboard
                // up, an even split leaves it too short, and it scrolls its first lines away.
                header.layoutPriority(1)
                Divider()
                list
                    .safeAreaBar(edge: .bottom) {
                        if !store.devices.isEmpty {
                            // The suggestions for what's typed go over the capsule, above the
                            // keyboard with it, rather than in the list it covers. While the next
                            // answer is worked out, the last one's stay (its suggestions dimmed),
                            // so the bar doesn't jump with each key.
                            StartBar(composer: $composer, project: startProject, prompt: query, suggestions: suggestions(route), stale: routedFor != query, duplicate: route?.duplicate, problem: problem, acting: acting, room: listHeight) {
                                // Nothing typed yet: the box is where the prompt goes.
                                if query.isEmpty {
                                    typing = true
                                } else {
                                    Task { await start() }
                                }
                            } suggest: { s in
                                Task { await act(s) }
                            }
                        }
                    }
                    // How tall the list is with the bar over it, above the keyboard: what the
                    // bar can take. Measured inside, the list is less what the bar covers.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in destination(key) }
            .sheet(isPresented: $showingMacs) {
                DevicesView()
            }
            // A session started here, or a link to one, opens once its Mac lists it.
            .onChange(of: store.sessions) { _, _ in openListed() }
            .onChange(of: store.prs) { _, _ in openListed() }
            .onChange(of: store.openWhenListed) { _, _ in openListed() }
            // The first that wait on you are the likeliest to be opened: read them ahead, so they
            // show at once. Again as they change, and once a Mac connects.
            .task(id: "\(firstWaiting)\(store.devices.filter(\.online).count)") {
                for key in firstWaiting { store.prefetch(key) }
            }
            // Back at the list, swiping back starts again from the next session opened.
            .onChange(of: path) { _, now in
                if now.isEmpty { store.trail.removeAll() }
            }
            // Improve Codealong pressed on this or any other screen: the list takes it up.
            .onChange(of: store.improving?.id) { _, id in
                if id != nil, let target = store.improving?.target { takeUpImprove(target) }
            }
            .task(id: query) { await searchSaid() }
            .task(id: "\(query)\u{1}\(startProject)\u{1}\(routeDevice ?? "")") { await suggest() }
            .onAppear {
                // Text typed for a test at launch (`QUERY=<text> scripts/run.sh`), the cursor in
                // the box as it would be, so the keyboard is up as it is while you write.
                if let q = ProcessInfo.processInfo.environment["CODEALONG_QUERY"], !q.isEmpty, text.isEmpty {
                    text = q
                    typing = true
                }
            }
            // A worktree picked in one project isn't where the next project's work goes.
            .onChange(of: project) { _, _ in composer.worktreeID = nil }
            .sensoryFeedback(.selection, trigger: project)
            .sensoryFeedback(.selection, trigger: page)
            .sensoryFeedback(.selection, trigger: order)
            .sensoryFeedback(.impact(weight: .light), trigger: foldedLines)
            .sensoryFeedback(.success, trigger: started)
            .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("OK", role: .cancel) { store.notice = nil }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let r = renaming { rename(r) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Its harness keeps the name, so it shows there too.")
            }
            .alert("Link with this Mac?", isPresented: Binding(get: { store.offeredLink != nil }, set: { if !$0 { store.offeredLink = nil } })) {
                Button("Link") {
                    if let code = store.offeredLink {
                        Task { await store.link(code) }
                    }
                    store.offeredLink = nil
                }
                Button("Cancel", role: .cancel) { store.offeredLink = nil }
            } message: {
                Text("This phone will see the sessions on the Mac that showed this code, and the Mac will list it as a phone.")
            }
        }
        // The Mac to start on and what it can start, read on the stack rather than the list,
        // whose tasks stop while a session covers it: back at the list, the chips are as they were.
        .onAppear { chooseDevice() }
        .onChange(of: store.devices.map(\.key)) { _, _ in chooseDevice() }
        // Again once the Mac connects: at launch it's chosen before it is.
        .task(id: "\(composer.device ?? "")\(mac?.online == true)") { await loadChoices() }
    }

    @ViewBuilder
    private func destination(_ key: String) -> some View {
        // A view of its own per session: going from one to another by a link keeps nothing. Next
        // puts what's next, a session or a PR, in this one's place, so Back is still this list.
        // A session a swipe slid in starts as the swipe drew it, and a PR's page with what was
        // last read of it. A PR's is `pr:` and its key.
        if key.hasPrefix(PrView.prefix) {
            let pr = String(key.dropFirst(PrView.prefix.count))
            PrView(key: pr, kept: store.prDetails[pr], go: { next in path = [next] }).id(key)
        } else {
            SessionView(key: key, opening: store.slidIn.flatMap { $0.key == key ? $0.opening : nil }, go: { next in path = [next] }).id(key)
        }
    }

    /// Asks a Mac for something from a row's menu, saying what went wrong if it didn't go.
    private func act(_ ask: @escaping () async throws -> Void) {
        Task {
            do { try await ask() } catch { store.notice = words(error) }
        }
    }

    /// Asks as `act` does, but not again while the same ask (`what`) waits on its Mac's answer.
    private func actOnce(_ what: String, _ ask: @escaping () async throws -> Void) {
        guard asking.insert(what).inserted else { return }
        act {
            defer { asking.remove(what) }
            try await ask()
        }
    }

    // MARK: The input

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                pageMenu
                Spacer(minLength: 0)
                ImproveButton(glass: true)
                Button { showingMacs = true } label: {
                    Image(systemName: "laptopcomputer")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.glass)
                .tint(macsNeedAttention ? .orange : nil)
                .accessibilityLabel("Macs")
            }
            // Its top is the field's: a field of several lines reports its baseline below its words.
            HStack(alignment: .top, spacing: 8) {
                // Photos go with what starts from here, as the reply box's + adds them to a reply.
                if !store.devices.isEmpty {
                    Button { picking = true } label: {
                        // A line of the field's font, so it sits on the field's first line.
                        Text(Image(systemName: "plus"))
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                            .contentShape(.rect.inset(by: -8))
                    }
                    .buttonStyle(.plain)
                    .disabled(acting)
                    .accessibilityLabel("Attach photos")
                    .accessibilityHint("They go with the session you start")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let placeholder = store.improving == nil ? "Find a session, or describe new work…" : "Describe how to improve Codealong…"
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        // A copied image pasted here goes with the session, as a photo picked with + does.
                        WritingField(text: $text, focused: $typing, label: placeholder, style: .title3, pasted: store.devices.isEmpty || acting ? nil : { data in
                            if let data { hold(data) } else { problem = "The image you copied couldn't be read." }
                        }, reading: $loadingPhotos)
                    }
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
            }
            if !photos.isEmpty {
                AttachedRow(images: photos) { id in
                    withAnimation(.snappy) { photos.removeAll { $0.id == id } }
                }
                .disabled(acting)
            }
            if let improving = store.improving {
                ImproveStrip(improving: improving)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: 6, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            loadingPhotos += items.count
            // One after another, so they're in the prompt as they were picked.
            Task {
                for item in items {
                    let data = try? await item.loadTransferable(type: Data.self)
                    loadingPhotos -= 1
                    if let data { hold(data) } else { problem = "That photo couldn't be read from your library." }
                }
            }
        }
    }

    /// Holds a photo for the prompt, picked or pasted.
    private func hold(_ data: Data) {
        if let image = AttachedImage.held(data) {
            withAnimation(.snappy) { photos.append(image) }
        } else {
            problem = "That isn't an image."
        }
    }

    /// Sessions or PRs, and how Sessions are ordered.
    private var pageMenu: some View {
        Menu {
            Picker("Page", selection: animated($page)) {
                Label("Sessions", systemImage: "bubble.left.and.text.bubble.right").tag(Page.sessions)
                Label {
                    Text("PRs")
                    if reviewCount > 0 { Text("\(reviewCount) waiting on your review") }
                } icon: {
                    Image(systemName: "arrow.triangle.pull")
                }
                .tag(Page.prs)
            }
            .pickerStyle(.inline)
            if page == .sessions {
                Section("Order") {
                    Picker("Order", selection: animated($order)) {
                        Label("Needs you first", systemImage: "bell").tag(Order.needs)
                        Label("By project", systemImage: "folder").tag(Order.project)
                        Label("Recent", systemImage: "clock").tag(Order.recent)
                    }
                    .pickerStyle(.inline)
                }
            } else if store.github.count > 1 {
                // Macs signed in as other accounts, a bot's say: which ones are you.
                Section("Your GitHub accounts") {
                    ForEach(store.github, id: \.login) { a in
                        Toggle(isOn: Binding(get: { a.yours }, set: { on in withAnimation(.smooth) { store.setYours(a.login, on) } })) {
                            Text(a.login)
                            Text(a.macs.formatted(.list(type: .and)))
                        }
                        .disabled(a.yours && store.github.filter(\.yours).count == 1)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: page == .sessions ? "bubble.left.and.text.bubble.right" : "arrow.triangle.pull")
                    .font(.subheadline)
                Text(page == .sessions ? "Sessions" : "PRs")
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.interpolate)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
            .foregroundStyle(.primary)
        }
        .tint(.primary)
        .accessibilityLabel(page == .sessions ? "Sessions" : "PRs")
        .accessibilityHint("Switches between sessions and PRs, orders the sessions, and picks which GitHub accounts are yours")
    }

    /// A binding whose changes animate, so a menu's pick moves the list rather than swapping it.
    private func animated<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { v in withAnimation(.smooth) { binding.wrappedValue = v } })
    }

    /// A worktree's ✎ in the list by project: the start bar goes to it, and the input asks for
    /// the work.
    private func startIn(_ worktree: Worktree) {
        composer.device = worktree.device
        composer.worktreeID = worktree.id
        typing = true
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        let content = listed
        let suggested = routedFor == query ? suggestions(route) : []
        List {
            if !store.devices.isEmpty {
                pillsRow
            }
            // A Mac that dropped this phone still shows what it last sent, so say why it's old.
            if !forgotten.isEmpty {
                Button { showingMacs = true } label: {
                    Label("\(forgotten.map { Names.short($0.name) }.formatted()) no longer has this phone linked. Link again", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                .listRowSeparator(.hidden)
            }
            if !store.devices.isEmpty {
                notes(content, suggested: suggested)
            }
            switch content {
            case let .quick(quick):
                quickSections(quick)
            case let .projects(pinned, groups):
                pinnedSection(pinned)
                projectSections(groups)
            case let .recent(pinned, rows):
                pinnedSection(pinned)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.key) { sessionRow($0) }
                    } header: {
                        GroupHeading(title: "Recent", count: rows.count)
                    }
                }
            case let .prs(sections):
                prSections(sections)
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 4, for: .scrollContent)
        // Dragging the list puts the keyboard away, so what it covers can be reached. (Interactively,
        // it went only once the drag reached the keyboard, past the start bar, which a drag on the
        // little of the list left over it rarely did.)
        .scrollDismissesKeyboard(.immediately)
        .overlay { emptyState(content) }
        // Rows that come, go or move as the Macs report animate there, as a pick of yours does.
        .animation(.snappy, value: content.ids)
    }

    /// What the list shows now: the core's lists for the page, the order and what's typed.
    private enum Listed {
        case quick(QuickList)
        /// The pinned sessions, which lead apart, and the rest by project.
        case projects([SessionRow], [ProjectGroup])
        case recent([SessionRow], [SessionRow])
        case prs([PrSection])

        var ids: [String] {
            switch self {
            case let .quick(q): q.sections.flatMap { $0.rows.map(\.id) }
            case let .projects(pinned, p): pinned.map(\.key) + p.flatMap { $0.worktrees.flatMap { [$0.id] + $0.sessions.map(\.key) } }
            case let .recent(pinned, r): pinned.map(\.key) + r.map(\.key)
            case let .prs(s): s.flatMap { $0.rows.map(\.key) }
            }
        }

        var isEmpty: Bool { ids.isEmpty }
    }

    /// Typed words search, whatever the page; with none, the page in its order.
    private var listed: Listed {
        if !query.isEmpty {
            return .quick(store.quick(project: project, query: query, said: said, ranked: routedFor == query ? route?.ranked ?? [] : []))
        }
        if page == .prs { return .prs(store.prList(project: project)) }
        switch order {
        case .needs: return .quick(store.quick(project: project, query: "", said: [], ranked: []))
        case .project: return .projects(store.pinned(project: project), store.byProject(project: project))
        case .recent: return .recent(store.pinned(project: project), store.recent(project: project))
        }
    }

    /// The projects as pills that scroll sideways, the one picked lit, the light sliding over as
    /// you pick another.
    private var pillsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                pill("All", value: "")
                ForEach(projects, id: \.self) { name in
                    pill(name == "Elsewhere" ? "No project" : name, value: name)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func pill(_ title: String, value: String) -> some View {
        let on = project == value
        return Button {
            withAnimation(.snappy) { project = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background {
                    if on {
                        Capsule()
                            .fill(.fill.secondary)
                            .matchedGeometryEffect(id: "pill", in: pills)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private func notes(_ content: Listed, suggested: [Suggestion]) -> some View {
        Group {
            if query.isEmpty, case let .quick(quick) = content, quick.nothingWaits {
                Note(text: "Nothing needs you\(quick.working > 0 ? " · \(quick.working) working" : "").")
            }
            if routing {
                Note(text: "Working out where this goes…", symbol: "sparkles")
            }
            if let routeProblem, !query.isEmpty {
                Note(text: "Couldn’t suggest where this goes: \(routeProblem)")
            }
            if !query.isEmpty && content.isEmpty && suggested.isEmpty && !routing && !saidBuilding {
                Note(text: "No sessions or PRs match. Start a session with this prompt below.")
            }
            if !query.isEmpty && saidBuilding {
                Note(text: "Still reading what recent sessions said, so more may match in a moment.")
            }
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func quickSections(_ quick: QuickList) -> some View {
        ForEach(quick.sections, id: \.group) { section in
            Section {
                ForEach(section.rows, id: \.id) { row in
                    switch row {
                    case let .session(r, hit): sessionRow(r, said: hit)
                    case let .pr(pr): prRow(pr)
                    }
                }
            } header: {
                GroupHeading(title: section.group.title, count: Int(section.count), symbol: section.group == .pinned ? "pin.fill" : nil)
            }
        }
    }

    /// The sessions pinned on their Macs, leading By project and Recent as they lead the rest.
    @ViewBuilder
    private func pinnedSection(_ rows: [SessionRow]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.key) { sessionRow($0) }
            } header: {
                GroupHeading(title: "Pinned", count: rows.count, symbol: "pin.fill")
            }
        }
    }

    // MARK: By project

    private var folded: Set<String> {
        Set(foldedLines.split(separator: "\n").map(String.init))
    }

    private func toggleFold(_ id: String) {
        var now = folded
        if now.contains(id) { now.remove(id) } else { now.insert(id) }
        withAnimation(.snappy) { foldedLines = now.sorted().joined(separator: "\n") }
    }

    @ViewBuilder
    private func projectSections(_ groups: [ProjectGroup]) -> some View {
        let folded = folded
        ForEach(groups, id: \.project) { p in
            Section {
                ForEach(p.worktrees, id: \.id) { w in
                    worktreeRow(w, folded: folded.contains(w.id))
                    if !folded.contains(w.id) {
                        ForEach(w.sessions, id: \.key) { s in
                            sessionRow(s, compact: true)
                                .listRowInsets(EdgeInsets(top: 0, leading: 48, bottom: 0, trailing: 16))
                        }
                    }
                }
            } header: {
                GroupHeading(title: p.project == "Elsewhere" ? "No project" : p.project, count: p.worktrees.reduce(0) { $0 + $1.sessions.count })
            }
        }
    }

    /// A worktree's row: a tap folds its sessions away or brings them back; its ✎ points the start
    /// bar at it.
    private func worktreeRow(_ w: WorktreeGroup, folded: Bool) -> some View {
        HStack(spacing: 6) {
            Button { toggleFold(w.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(w.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let branch = w.branch, branch != w.name {
                        Text(branch)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if store.devices.count > 1 {
                        Text(Names.short(w.deviceName))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if folded {
                        Text("\(w.sessions.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(folded ? -90 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(w.name), \(w.sessions.count) sessions")
            .accessibilityValue(folded ? "Folded" : "Open")
            .accessibilityHint(folded ? "Shows its sessions" : "Folds its sessions away")
            if let worktree = w.worktree {
                Button { startIn(worktree) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start a session in \(w.name)")
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 6))
        .listRowSeparator(.hidden)
    }

    // MARK: PRs

    @ViewBuilder
    private func prSections(_ sections: [PrSection]) -> some View {
        ForEach(sections, id: \.group) { s in
            Section {
                if s.group == .done && !showingDone {
                    Button { withAnimation(.snappy) { showingDone = true } } label: {
                        HStack {
                            Text("Show \(s.rows.count) merged or closed")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(s.rows, id: \.key) { prRow($0) }
                }
            } header: {
                GroupHeading(title: s.group.title, count: s.rows.count, symbol: s.group == .pinned ? "pin.fill" : nil)
            }
        }
    }

    /// How many PRs wait on your review, for the menu.
    private var reviewCount: Int {
        store.prList(project: project).first { $0.group == .reviews }?.rows.count ?? 0
    }

    // MARK: Rows

    /// A session's row: a tap opens it; its menu and swipes are a session's right-click menu on
    /// the Mac.
    private func sessionRow(_ r: SessionRow, said hit: SaidHit? = nil, compact: Bool = false) -> some View {
        Button { path.append(r.key) } label: {
            QuickSessionRow(row: r, said: hit, words: matching, showDevice: store.devices.count > 1, showProject: project.isEmpty, compact: compact)
                .contentShape(.rect)
        }
        .tint(.primary)
        .contextMenu { sessionMenu(r) }
        .swipeActions(edge: .trailing) {
            Button("Archive", systemImage: "archivebox") { store.archive(r.key) }
                .tint(.gray)
        }
        .swipeActions(edge: .leading) {
            if r.status == .unread {
                Button("Seen", systemImage: "checkmark") { store.markSeen(r.key) }
                    .tint(.accentColor)
            }
        }
    }

    /// A PR's row: a tap opens it here, or on GitHub when its Mac can't read it there.
    private func prRow(_ pr: PrRow) -> some View {
        Button {
            if !pr.slug.isEmpty {
                path.append(PrView.prefix + pr.key)
            } else if let url = URL(string: pr.url) {
                openURL(url)
            }
        } label: {
            QuickPrRow(pr: pr, words: matching)
                .contentShape(.rect)
        }
        .tint(.primary)
        .contextMenu { prMenu(pr) }
    }

    /// A session's menu, in the order of its right-click menu on the Mac, less what a phone can't
    /// do: opening its PR and starting from it; what it is to you; copying it.
    @ViewBuilder
    private func sessionMenu(_ r: SessionRow) -> some View {
        // Renaming it and marking it done wait on its Mac, so they need it connected; forking it
        // needs remote control on there too.
        let online = store.devices.contains { $0.key == r.device && $0.online }
        Section {
            if let pr = r.worktreePr {
                Button("Open PR #\(String(pr.number))", systemImage: "arrow.triangle.pull") { openPr(pr) }
            }
            if let worktree = store.worktrees(r.device).first(where: { $0.id == r.worktreeId }) {
                Button("New session here…", systemImage: "square.and.pencil") { startIn(worktree) }
            }
            Button("Fork", systemImage: "arrow.triangle.branch") { fork(r) }
                .disabled(store.cannotReach(r) != nil || asking.contains("fork:" + r.key))
        }
        Section {
            Button("Rename…", systemImage: "pencil") {
                newName = r.name ?? r.title
                renaming = r
            }
            .disabled(!online)
            if r.seenable {
                Button("Mark as seen", systemImage: "eye") { store.markSeen(r.key) }
            }
            if r.unreadable {
                Button("Mark as unread", systemImage: "envelope.badge") { act { try await store.markUnread(r.key) } }
            }
            // Pinned on its Mac, which lists it first there and here.
            Button(r.pinned == nil ? "Pin" : "Unpin", systemImage: r.pinned == nil ? "pin" : "pin.slash") {
                act { try await store.pin(r.key, r.pinned == nil) }
            }
            Menu("Snooze", systemImage: "moon.zzz") {
                ForEach(Snooze.choices()) { c in
                    Button(c.label) { act { try await store.snooze(r.key, until: c.until) } }
                }
                if r.snoozedUntil != nil {
                    Button("Wake now", systemImage: "sun.max") { act { try await store.snooze(r.key, until: nil) } }
                }
            }
            Toggle(isOn: Binding(get: { r.quiet }, set: { on in act { try await store.quiet(r.key, on) } })) {
                Label("Quiet", systemImage: "speaker.slash")
            }
            Button("Mark as done", systemImage: "checkmark.circle") { markDone(r) }
                .disabled(!online || asking.contains("done:" + r.key))
            Button("Archive", systemImage: "archivebox") { store.archive(r.key) }
        }
        Section {
            if !r.id.isEmpty {
                Button("Copy session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = r.id }
            }
        }
    }

    /// A PR's menu, in the order of its menu on the Mac, less what a phone can't do: opening it and
    /// its sessions; approving it and snoozing your review; copying its link and branch.
    @ViewBuilder
    private func prMenu(_ pr: PrRow) -> some View {
        // The sessions that worked on it that the list has: an archived one has no page here.
        let sessions = pr.sessions.compactMap { key in store.sessions.first { $0.key == key } }
        Section {
            if let url = URL(string: pr.url) {
                Button("Open on GitHub", systemImage: "safari") { openURL(url) }
            }
            if sessions.count == 1 {
                Button("Open its session", systemImage: "bubble.left") { path.append(sessions[0].key) }
            } else if sessions.count > 1 {
                Menu("Open its session", systemImage: "bubble.left") {
                    ForEach(sessions, id: \.key) { s in
                        Button(s.title) { path.append(s.key) }
                    }
                }
            }
        }
        Section {
            // Where the review box would take an approval: an open PR its Mac didn't open.
            if !pr.slug.isEmpty && reviewBox(pr: pr, draft: nil, reviews: []).reviewable {
                Button("Approve #\(String(pr.number))", systemImage: "checkmark") { approve(pr) }
                    .disabled(PrView.whyNot(pr, store: store) != nil || asking.contains("approve:" + pr.key))
            }
            if pr.reviewRequested && !pr.slug.isEmpty {
                Menu("Snooze review", systemImage: "moon.zzz") {
                    ForEach(Snooze.choices()) { c in
                        Button(c.label) { act { try await store.prSnooze(pr, until: c.until) } }
                    }
                    if pr.snoozedUntil != nil {
                        Button("Wake now", systemImage: "sun.max") { act { try await store.prSnooze(pr, until: nil) } }
                    }
                }
            }
        }
        Section {
            if !pr.url.isEmpty {
                Button("Copy link", systemImage: "link") { UIPasteboard.general.string = pr.url }
            }
            if let branch = pr.branch, !branch.isEmpty {
                Button("Copy branch name", systemImage: "arrow.triangle.branch") { UIPasteboard.general.string = branch }
            }
        }
    }

    /// A session's PR: its page here where the PRs listed have it and its Mac can read it there,
    /// as a PR's row opens, else on GitHub.
    private func openPr(_ wp: WorktreePr) {
        if let pr = store.pr(wp.key), !pr.slug.isEmpty {
            path.append(PrView.prefix + pr.key)
        } else if let url = URL(string: wp.url) {
            openURL(url)
        }
    }

    /// Forks a session into a copy that goes on in the background on its Mac, as its own Fork
    /// does. The copy waits for a prompt, so it opens once its Mac lists it, as a start here does.
    private func fork(_ r: SessionRow) {
        actOnce("fork:" + r.key) {
            let started = try await store.fork(r.key, prompt: "")
            if let key = started.key {
                store.openWhenListed = key
            } else {
                store.notice = started.message ?? "Forked “\(r.title)”: the copy waits for a prompt in the background on its Mac."
            }
        }
    }

    /// Done with a session, as the Mac's Mark as done and its own: it closes where its Mac can
    /// close it, and is marked seen and archived. Work under way holds it, and done again soon
    /// after ends that too.
    private func markDone(_ r: SessionRow) {
        let stop = doneHeld[r.key].map { Date.now.timeIntervalSince($0) < 15 } ?? false
        if !stop && r.status == .working {
            doneHeld[r.key] = .now
            store.notice = "“\(r.title)” is still working. Mark it done again to end that too."
            return
        }
        actOnce("done:" + r.key) {
            let outcome = try await store.done(r.key, stop: stop)
            guard outcome.done else {
                doneHeld[r.key] = .now
                store.notice = "\(outcome.message) Mark it done again to end that too."
                return
            }
            doneHeld[r.key] = nil
            store.dealtWith(r.key)
            if outcome.noted { store.notice = outcome.message }
        }
    }

    /// Approves a PR as you on GitHub, through its Mac, as its review box's Approve does with
    /// nothing written. A draft review of yours on it holds that back: its Mac says to open it.
    private func approve(_ pr: PrRow) {
        actOnce("approve:" + pr.key) {
            let went = try await store.prReview(pr, verdict: .approve, body: "", draft: nil)
            store.dealtWith(PrView.prefix + pr.key)
            store.notice = reviewedWords(verdict: .approve, number: pr.number, draft: went)
        }
    }

    private func rename(_ r: SessionRow) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != r.title else { return }
        act { try await store.rename(r.key, to: name) }
    }

    @ViewBuilder
    private func emptyState(_ content: Listed) -> some View {
        if store.devices.isEmpty {
            ContentUnavailableView {
                Label("Link a Mac", systemImage: "laptopcomputer.and.iphone")
            } description: {
                Text("Make a link code on your Mac in Codealong's Settings › Devices, then scan it or enter it here.")
            } actions: {
                Button("Link a Mac") { showingMacs = true }
                    .buttonStyle(.glassProminent)
            }
        } else if content.isEmpty, query.isEmpty {
            switch content {
            case .prs:
                ContentUnavailableView("No PRs", systemImage: "arrow.triangle.pull", description: Text(project.isEmpty ? "Your Macs know no open PRs." : "Your Macs know no open PRs in \(project)."))
            case .projects, .recent:
                ContentUnavailableView("No sessions", systemImage: "bubble.left.and.text.bubble.right", description: Text(project.isEmpty ? "No session has been active in the last three days." : "No session in \(project) has been active in the last three days."))
            case .quick:
                EmptyView()
            }
        }
    }

    private var matching: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: Searching and suggesting

    /// Looks for what's typed in what sessions said, a moment after typing pauses. What the last
    /// search found stays while its line still has every word, so a row doesn't blink out with
    /// each key and come back when the answer comes.
    private func searchSaid() async {
        said = stillSaid(hits: said, query: query)
        guard worthSearchingSaid(query: query) else {
            said = []
            saidBuilding = false
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        if Task.isCancelled { return }
        let found = await store.searchSaid(query)
        if Task.isCancelled { return }
        said = found.hits
        saidBuilding = found.building
    }

    /// Asks the Mac chosen below where what's typed goes, once typing pauses on a few words.
    /// Improving Codealong, it suggests among Codealong's own project's worktrees.
    private func suggest() async {
        routeProblem = nil
        guard worthRouting(text: query), let device = routeDevice else {
            routing = false
            route = nil
            return
        }
        // What was suggested for another project or Mac isn't kept while this one answers.
        let place = "\(startProject)\u{1}\(device)"
        if routedWhere != place { route = nil }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        routing = true
        let asked = query
        do {
            let got = try await store.route(device: device, project: startProject, text: asked)
            if Task.isCancelled { return }
            route = got
            routedFor = asked
            routedWhere = place
        } catch {
            if Task.isCancelled { return }
            route = nil
            routeProblem = words(error)
        }
        routing = false
    }

    /// A Mac's suggestions for what's typed, but the start the capsule under them makes already:
    /// listed over it, the same start was there twice.
    private func suggestions(_ route: RouteAnswer?) -> [Suggestion] {
        (route?.suggestions ?? []).filter { !composer.startsAs($0, store: store, project: startProject) }
    }

    /// The first two sessions that wait on you, in the inbox's order and its project.
    private var firstWaiting: [String] {
        store.sessions.filter { ($0.section == .needsYou || $0.section == .yourTurn) && (project.isEmpty || $0.project == project) }.prefix(2).map(\.key)
    }

    /// The Mac that suggests: the one new sessions start on, else any that's connected.
    private var routeDevice: String? {
        if let d = composer.device, store.devices.contains(where: { $0.key == d && $0.online }) { return d }
        return store.devices.first { $0.online }?.key
    }

    // MARK: Acting

    private func act(_ s: Suggestion) async {
        switch s.kind {
        case .open:
            if let key = s.session?.key { path.append(key) }
        case .send:
            // It goes as a reply in the session's screen goes: shown there at once, back in its
            // box if it doesn't go.
            guard let row = s.session, !acting else { return }
            // What's typed as it's tapped: the box stays open while the photos go to the Mac.
            let asked = query
            // The photos attached go with it, kept on its Mac first.
            acting = true
            problem = nil
            let images = await keptPhotos(on: row.device)
            acting = false
            guard let images else { return }
            store.post(row.key, title: row.title, text: ImagePrep.prompt(images: images, text: asked), how: .send(now: false))
            // Words written meanwhile didn't go, so they stay.
            if query == asked { text = "" }
            photos = []
            store.dealtWith(row.key)
            path.append(row.key)
        case .start:
            guard let w = s.worktree else { return }
            await start(in: w, newWorktree: s.newWorktree)
        }
    }

    /// Starts a session with what's typed: in the worktree chosen below, or where a suggestion says.
    private func start(in over: Worktree? = nil, newWorktree over2: Bool? = nil) async {
        let worktree = over ?? composer.worktree(store: store, project: startProject)
        guard !acting, let worktree, let account = composer.account, let place = composer.place else { return }
        let newTree = composer.takesNewWorktree && !worktree.chat && (over2 ?? composer.newWorktree)
        // What starts is what's written and chosen as it's tapped: the box and the menu stay open
        // while the photos go to the Mac.
        let asked = query
        let (model, effort) = composer.takesModel ? (composer.model, composer.effort) : (nil, nil)
        let shots = store.improving.map { $0.shot.map { [$0] } ?? [] }
        // The picture is still on its way to the Mac: the prompt would go without it.
        if store.improving?.keeping == true {
            problem = "The picture of the screen is still on its way to the Mac. Try again in a moment."
            return
        }
        acting = true
        problem = nil
        guard let images = await keptPhotos(on: worktree.device) else {
            acting = false
            return
        }
        let typed = ImagePrep.prompt(images: images, text: asked)
        // Improving Codealong: the picture of the screen goes after what you wrote, as the Mac's
        // panel writes it (the core's rule).
        let prompt = shots.map { improvePrompt(text: typed, shots: $0) } ?? typed
        do {
            let begun = try await store.startSession(device: worktree.device, worktree: worktree.id, account: account, place: place, prompt: prompt, model: model, effort: effort, newWorktree: newTree)
            acting = false
            started += 1
            // Words written meanwhile didn't go, so they stay.
            if query == asked { text = "" }
            photos = []
            typing = false
            store.improving = nil
            // It opens once its Mac lists it; a start whose id the Mac doesn't know yet says what's next.
            if let key = begun.key {
                store.openWhenListed = key
                // One its Mac doesn't list (it went offline, or the terminal's command failed)
                // says so, still opening if it turns up.
                try? await Task.sleep(for: .seconds(30))
                if store.openWhenListed == key {
                    let name = store.devices.first { $0.key == worktree.device }.map { Names.short($0.name) } ?? "the Mac"
                    problem = "It started, but \(name) hasn’t listed it yet. It opens once it does."
                }
            } else if let message = begun.message {
                store.notice = message
            }
        } catch {
            acting = false
            problem = words(error)
        }
    }

    /// The photos attached, kept on `mac` for the prompt, in order; nil, saying why, when they
    /// can't be.
    private func keptPhotos(on mac: String) async -> [String]? {
        if loadingPhotos > 0 {
            problem = "A photo is still being read. Try again in a moment."
            return nil
        }
        do {
            return try await store.keep(photos, on: mac)
        } catch {
            let name = store.devices.first { $0.key == mac }.map { Names.short($0.name) } ?? "the Mac"
            problem = "The photos couldn’t be kept on \(name): \(words(error))"
            return nil
        }
    }

    private var mac: DeviceRow? { store.devices.first { $0.key == composer.device } }

    /// The Mac to start on: the last one, else one that takes remote control.
    private func chooseDevice() {
        guard composer.device == nil, !store.devices.isEmpty else { return }
        let online = store.devices.filter(\.online)
        composer.device = (online.first { $0.key == lastDevice } ?? online.first { $0.remoteControl } ?? store.devices.first)?.key
    }

    /// What the Mac chosen can start, for the chips; the account and place you last chose, where
    /// they can go there.
    private func loadChoices() async {
        composer.choices = nil
        composer.choicesProblem = nil
        guard let device = composer.device, mac?.online == true else { return }
        do {
            let got = try await store.startChoices(device)
            composer.choices = got
            let usable = got.accounts.filter { $0.unavailable == nil }
            let first = usable.first { $0.name == lastAccount } ?? usable.first { $0.preferred } ?? usable.first
            composer.account = first?.name
            // The place you last chose, where this account can go there; else where the core says
            // a start from the phone goes.
            composer.place = first?.places.first { $0.id == lastPlace }?.id ?? first?.place
            composer.model = nil
            composer.effort = nil
        } catch {
            composer.choicesProblem = words(error)
        }
    }

    /// Improve Codealong pressed, on any screen (`Store.improveCodealong`, with the picture of
    /// that screen already taken): the list comes back to the front, the start bar onto
    /// Codealong's own source on the Mac the core picked, and its input asks what to change.
    private func takeUpImprove(_ target: ImproveTarget) {
        path = []
        showingMacs = false
        composer.device = target.device
        composer.worktreeID = target.worktree
        typing = true
    }

    private func openListed() {
        guard let key = store.openWhenListed else { return }
        // The Macs sheet, for a check of it (`OPEN=macs scripts/run.sh`).
        if key == "macs" {
            store.openWhenListed = nil
            showingMacs = true
            return
        }
        let listed = key.hasPrefix(PrView.prefix) ? store.pr(String(key.dropFirst(PrView.prefix.count))) != nil : store.sessions.contains { $0.key == key }
        if listed {
            store.openWhenListed = nil
            // A start that hadn't been listed yet has been now.
            problem = nil
            path = [key]
        }
    }

    // MARK: Macs and projects

    /// The Macs button: a Mac that isn't connected, or dropped this phone, turns it orange.
    private var macsNeedAttention: Bool {
        store.devices.contains { !$0.online || !$0.linkedBack }
    }

    /// Connected Macs that don't have this phone on their list.
    private var forgotten: [DeviceRow] {
        store.devices.filter { $0.online && !$0.linkedBack }
    }

    /// The projects the page can narrow to, as the core lists them: the PRs page's are its PRs'.
    /// One narrowed to stays while it has nothing to show, so its pill is still there to go back
    /// from.
    private var projects: [String] {
        let all = page == .prs && query.isEmpty ? store.prProjects : store.projects
        return project.isEmpty || all.contains(project) ? all : [project] + all
    }
}

extension QuickGroup {
    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .needsYou: "Needs you"
        case .yourTurn: "Your turn"
        case .reviews: "Review requested"
        case .working: "Working"
        case .sessions: "Sessions"
        case .prs: "PRs"
        case .recent: "Last 24 hours"
        }
    }
}

extension PrGroup {
    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .reviews: "Review requested"
        case .yours: "Yours"
        case .others: "Other open"
        case .snoozed: "Snoozed"
        case .done: "Merged and closed"
        }
    }
}

extension QuickRow {
    var id: String {
        switch self {
        case let .session(row, _): row.key
        case let .pr(pr): "pr:\(pr.key)"
        }
    }
}

/// A group's heading, as the Mac's panel has it: small capitals and how many there are, after
/// the group's symbol where it has one (Pinned's pin).
struct GroupHeading: View {
    let title: String
    let count: Int
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            Text(title.uppercased())
            Text("\(count)")
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText(value: Double(count)))
        }
        .font(.caption.weight(.semibold).monospaced())
        .tracking(0.8)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

/// A line of what's going on above the list.
private struct Note: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).symbolEffect(.pulse, options: .repeating)
            }
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// What's typed, with the words that matched in bold.
enum Marked {
    static func text(_ s: String, words: [String]) -> AttributedString {
        var out = AttributedString(s)
        for w in words where !w.isEmpty {
            guard let r = s.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]), let lo = AttributedString.Index(r.lowerBound, within: out), let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
            out[lo..<hi].underlineStyle = .single
        }
        return out
    }
}

/// How a Mac's name reads where space is short: without its owner ("Sam’s MacBook Pro" is
/// "MacBook Pro"), since every Mac here is yours.
enum Names {
    static func short(_ name: String) -> String {
        for mark in ["’s ", "'s "] {
            if let r = name.range(of: mark), r.lowerBound > name.startIndex {
                let rest = name[r.upperBound...]
                if !rest.isEmpty { return String(rest) }
            }
        }
        return name
    }
}
