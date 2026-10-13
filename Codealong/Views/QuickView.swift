import SwiftUI

/// The app's first screen, laid out as Codex's phone app is: a floating glass bar with the page
/// menu and search, the projects as pills, the list, and a capsule at the bottom that starts a
/// session. The page menu switches between Sessions and PRs, orders Sessions (what needs you
/// first, as the Mac's quick panel lists them, by project, or the last active first), and opens
/// the Macs and Improve Codealong. Search finds sessions, by what was said in them too, and PRs.
/// The core has the rules; this lays them out and moves them about with the system's own
/// animations.
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

    @State private var searching = false
    @State private var text = ""
    @FocusState private var searchFocused: Bool
    /// What the Macs' text search found for what's typed, and whether one is still reading.
    @State private var said: [SaidHit] = []
    @State private var saidBuilding = false

    @State private var composer = Composer()
    /// The last account, place and Mac you started on, to start with again.
    @AppStorage("start.account") private var lastAccount = ""
    @AppStorage("start.place") private var lastPlace = ""
    @AppStorage("start.device") private var lastDevice = ""

    @Namespace private var zoom
    @Namespace private var glass
    @Namespace private var pills

    enum Page: String { case sessions, prs }
    enum Order: String { case needs, project, recent }

    /// New session's place on the path; a worktree's ✎ adds the worktree's id, so the screen
    /// zooms out of the button that opened it.
    static let newKey = "new:"

    private var query: String { searching ? text.trimmingCharacters(in: .whitespacesAndNewlines) : "" }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .safeAreaBar(edge: .top) { bar }
                .safeAreaBar(edge: .bottom) {
                    if !store.devices.isEmpty && !searching {
                        capsule
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
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
                // The first that wait on you are the likeliest to be opened: read them ahead, so
                // they show at once. Again as they change, and once a Mac connects.
                .task(id: "\(firstWaiting)\(store.devices.filter(\.online).count)") {
                    for key in firstWaiting { store.prefetch(key) }
                }
                // Back at the list, swiping back starts again from the next session opened.
                .onChange(of: path) { _, now in
                    if now.isEmpty { store.trail.removeAll() }
                }
                // Improve Codealong pressed on this or any other screen: New session takes it up.
                .onChange(of: store.improving?.id) { _, id in
                    if id != nil, let target = store.improving?.target { takeUpImprove(target) }
                }
                .task(id: query) { await searchSaid() }
                .onAppear {
                    // Text searched for a test at launch (`QUERY=<text> scripts/run.sh`).
                    if let q = ProcessInfo.processInfo.environment["CODEALONG_QUERY"], !q.isEmpty, text.isEmpty {
                        searching = true
                        text = q
                    }
                }
                // A worktree picked in one project isn't where the next project's work goes.
                .onChange(of: project) { _, _ in composer.worktreeID = nil }
                .sensoryFeedback(.selection, trigger: project)
                .sensoryFeedback(.selection, trigger: page)
                .sensoryFeedback(.selection, trigger: order)
                .sensoryFeedback(.impact(weight: .light), trigger: foldedLines)
                .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                    Button("OK", role: .cancel) { store.notice = nil }
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
        // which is off screen, its tasks cancelled, while New session is open: a Mac picked there,
        // or one a worktree's ✎ picked as New session opened, has its choices read all the same.
        .onAppear { chooseDevice() }
        .onChange(of: store.devices.map(\.key)) { _, _ in chooseDevice() }
        // Again once the Mac connects: at launch it's chosen before it is.
        .task(id: "\(composer.device ?? "")\(mac?.online == true)") { await loadChoices() }
    }

    @ViewBuilder
    private func destination(_ key: String) -> some View {
        if key.hasPrefix(Self.newKey) {
            // Improving Codealong, the Mac suggests among Codealong's own project's worktrees.
            NewSessionView(composer: $composer, project: store.improving?.target.project ?? project, go: { next in path = [next] })
                .navigationTransition(.zoom(sourceID: key, in: zoom))
        } else if key.hasPrefix(PrView.prefix) {
            // A view of its own per session: going from one to another by a link keeps nothing.
            // Next puts the next session in this one's place, so Back is still this list. One a
            // swipe slid in starts as the swipe drew it. A PR's is `pr:` and its key.
            PrView(key: String(key.dropFirst(PrView.prefix.count))).id(key)
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

    // MARK: The bar

    /// The page menu and search, which turn into the search field and its close button, the
    /// glass flowing from one to the other.
    private var bar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                if searching {
                    searchField
                        .glassEffectID("search", in: glass)
                    Button(action: closeSearch) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("close", in: glass)
                    .accessibilityLabel("Close search")
                } else {
                    pageMenu
                        .glassEffectID("page", in: glass)
                    Spacer(minLength: 0)
                    Button(action: openSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("search", in: glass)
                    .disabled(store.devices.isEmpty)
                    .accessibilityLabel("Search")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions and PRs", text: $text)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy, value: text.isEmpty)
    }

    private func openSearch() {
        withAnimation(.smooth(duration: 0.35)) { searching = true }
        searchFocused = true
    }

    private func closeSearch() {
        searchFocused = false
        withAnimation(.smooth(duration: 0.35)) {
            searching = false
            text = ""
        }
    }

    /// Sessions or PRs, how Sessions are ordered, and the Macs and Improve Codealong.
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
            }
            Section {
                Button { showingMacs = true } label: {
                    Label {
                        Text("Macs")
                        Text(macsWords)
                    } icon: {
                        Image(systemName: "laptopcomputer")
                    }
                }
                Button(action: improveFromMenu) {
                    Label("Improve Codealong", systemImage: "lightbulb")
                }
                .disabled(store.devices.isEmpty)
            }
        } label: {
            HStack(spacing: 6) {
                Text(page == .sessions ? "Sessions" : "PRs")
                    .font(.headline)
                    .contentTransition(.interpolate)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(height: 44)
            .overlay(alignment: .topTrailing) {
                // A Mac that isn't connected, or dropped this phone, or a session being improved.
                if macsNeedAttention || store.improving != nil {
                    Circle()
                        .fill(.orange)
                        .frame(width: 9, height: 9)
                        .offset(x: -3, y: 5)
                        .transition(.scale)
                }
            }
            .contentShape(.capsule)
        }
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(page == .sessions ? "Sessions" : "PRs")
        .accessibilityHint("Switches page, orders the list, and opens your Macs")
    }

    /// A binding whose changes animate, so a menu's pick moves the list rather than swapping it.
    private func animated<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { v in withAnimation(.smooth) { binding.wrappedValue = v } })
    }

    /// Improve Codealong from the menu, once the menu has gone, so the picture is of the list.
    private func improveFromMenu() {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            store.improveCodealong()
        }
    }

    // MARK: The capsule

    private var capsule: some View {
        Button(action: openNew) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.orange, in: .circle)
                Text(store.improving == nil ? "Start a session…" : "Describe how to improve Codealong…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Tinted with the page, so the rows scrolling under it don't read through its words.
        .glassEffect(.regular.tint(Color(.systemBackground).opacity(0.7)).interactive(), in: .capsule)
        .matchedTransitionSource(id: Self.newKey, in: zoom)
        .padding(.horizontal, 32)
        .padding(.bottom, 4)
        .accessibilityLabel("Start a session")
    }

    /// New session from the capsule: in the worktree new work goes to, unless Improve Codealong
    /// picked Codealong's.
    private func openNew() {
        if store.improving == nil { composer.worktreeID = nil }
        path.append(Self.newKey)
    }

    /// New session from a worktree's ✎ in the list by project.
    private func startIn(_ group: WorktreeGroup, _ worktree: Worktree) {
        composer.device = worktree.device
        composer.worktreeID = worktree.id
        path.append(Self.newKey + group.id)
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        let content = listed
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
            switch content {
            case let .quick(quick):
                if !store.devices.isEmpty { notes(quick) }
                quickSections(quick)
            case let .projects(groups):
                projectSections(groups)
            case let .recent(rows):
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
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState(content) }
        // Rows that come, go or move as the Macs report animate there, as a pick of yours does.
        .animation(.snappy, value: content.ids)
    }

    /// What the list shows now: the core's lists for the page, the order and the search.
    private enum Listed {
        case quick(QuickList)
        case projects([ProjectGroup])
        case recent([SessionRow])
        case prs([PrSection])

        var ids: [String] {
            switch self {
            case let .quick(q): q.sections.flatMap { $0.rows.map(\.id) }
            case let .projects(p): p.flatMap { $0.worktrees.flatMap { [$0.id] + $0.sessions.map(\.key) } }
            case let .recent(r): r.map(\.key)
            case let .prs(s): s.flatMap { $0.rows.map(\.key) }
            }
        }

        var isEmpty: Bool { ids.isEmpty }
    }

    private var listed: Listed {
        if !query.isEmpty {
            return .quick(store.quick(project: project, query: query, said: said, ranked: []))
        }
        if page == .prs { return .prs(store.prList(project: project)) }
        switch order {
        case .needs: return .quick(store.quick(project: project, query: "", said: [], ranked: []))
        case .project: return .projects(store.byProject(project: project))
        case .recent: return .recent(store.recent(project: project))
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
    private func notes(_ quick: QuickList) -> some View {
        Group {
            if query.isEmpty && quick.nothingWaits {
                Note(text: "Nothing needs you\(quick.working > 0 ? " · \(quick.working) working" : "").")
            }
            if !query.isEmpty && quick.sections.isEmpty && !saidBuilding {
                Note(text: "No sessions or PRs match.")
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
                GroupHeading(title: section.group.title, count: Int(section.count))
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

    /// A worktree's row: a tap folds its sessions away or brings them back; its ✎ starts a
    /// session in it.
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
                Button { startIn(w, worktree) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: Self.newKey + w.id, in: zoom)
                .accessibilityLabel("New session in \(w.name)")
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
                GroupHeading(title: s.group.title, count: s.rows.count)
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
        .contextMenu {
            if r.seenable {
                Button("Mark as seen", systemImage: "checkmark.circle") { store.markSeen(r.key) }
            }
            if r.unreadable {
                Button("Mark as unread", systemImage: "circle.badge") {
                    Task {
                        do { try await store.markUnread(r.key) } catch { store.notice = words(error) }
                    }
                }
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
        }
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
        .contextMenu {
            if let url = URL(string: pr.url) {
                Button("Open on GitHub", systemImage: "safari") { openURL(url) }
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

    // MARK: Searching

    /// Looks for what's searched for in what sessions said, a moment after typing pauses. What
    /// the last search found stays while its line still has every word, so a row doesn't blink
    /// out with each key and come back when the answer comes.
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

    /// The first two sessions that wait on you, in the inbox's order and its project.
    private var firstWaiting: [String] {
        store.sessions.filter { ($0.section == .needsYou || $0.section == .yourTurn) && (project.isEmpty || $0.project == project) }.prefix(2).map(\.key)
    }

    // MARK: Starting

    private var mac: DeviceRow? { store.devices.first { $0.key == composer.device } }

    /// The Mac to start on: the last one, else one that takes remote control.
    private func chooseDevice() {
        guard composer.device == nil, !store.devices.isEmpty else { return }
        let online = store.devices.filter(\.online)
        composer.device = (online.first { $0.key == lastDevice } ?? online.first { $0.remoteControl } ?? store.devices.first)?.key
    }

    /// What the Mac chosen can start, read before New session opens so it's there at once; the
    /// account and place you last chose, where they can go there.
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
    /// that screen already taken): New session opens on Codealong's own source, on the Mac the
    /// core picked, and asks what to change.
    private func takeUpImprove(_ target: ImproveTarget) {
        showingMacs = false
        composer.device = target.device
        composer.worktreeID = target.worktree
        path = [Self.newKey]
    }

    private func openListed() {
        guard let key = store.openWhenListed else { return }
        // New session isn't listed by a Mac: it opens at once (`OPEN=new: scripts/run.sh`).
        if key.hasPrefix(Self.newKey) {
            store.openWhenListed = nil
            path = [key]
            return
        }
        let listed = key.hasPrefix(PrView.prefix) ? store.pr(String(key.dropFirst(PrView.prefix.count))) != nil : store.sessions.contains { $0.key == key }
        if listed {
            store.openWhenListed = nil
            path = [key]
        }
    }

    // MARK: Macs and projects

    /// A Mac that isn't connected, or dropped this phone, marks the page menu.
    private var macsNeedAttention: Bool {
        store.devices.contains { !$0.online || !$0.linkedBack }
    }

    /// Connected Macs that don't have this phone on their list.
    private var forgotten: [DeviceRow] {
        store.devices.filter { $0.online && !$0.linkedBack }
    }

    /// How the Macs stand, under Macs in the menu.
    private var macsWords: String {
        let online = store.devices.filter(\.online).count
        if store.devices.isEmpty { return "Link a Mac" }
        if !forgotten.isEmpty { return "\(forgotten.count == 1 ? "One" : "\(forgotten.count)") no longer linked" }
        return online == store.devices.count ? "\(online) connected" : "\(online) of \(store.devices.count) connected"
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

/// A group's heading, as the Mac's panel has it: small capitals and how many there are.
struct GroupHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
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

/// How a Mac's name reads where space is short: without its owner ("Gordon’s MacBook Pro" is
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
