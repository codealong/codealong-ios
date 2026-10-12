import SwiftUI

/// The app's one screen, as the Mac's quick panel is: an input at the top, and below it what you
/// can do next. With nothing typed it lists the sessions that need you, then the ones whose turn
/// ended (the ones working when nothing waits), then the rest started in the last day. Typed
/// words find sessions (by what was said in them too) and PRs, a Mac suggests where what's typed
/// goes, and the row at the bottom starts a new session with it as the prompt, on the Mac, in the
/// worktree, on the account and where the chips under it say. The core has the rules.
struct QuickView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var showingMacs = false
    @State private var text = ""
    @State private var path: [String] = []
    @FocusState private var typing: Bool
    /// The project the list is narrowed to, as the Macs line projects up; empty for all of them.
    @AppStorage("project") private var project = ""

    /// What the Macs' text search found for what's typed, and whether one is still reading.
    @State private var said: [SaidHit] = []
    @State private var saidBuilding = false
    /// A Mac's suggestions for what's typed, and the text they're for.
    @State private var route: RouteAnswer?
    @State private var routedFor = ""
    @State private var routing = false
    @State private var routeProblem: String?

    @State private var composer = Composer()
    @State private var problem: String?
    @State private var acting = false
    /// Improve Codealong: a session that improves Codealong itself, as the Mac's button beside
    /// New session starts one. The list goes onto Codealong's own project and worktree on the Mac
    /// the core picks, a picture of this screen as it was is kept on that Mac for the prompt, and
    /// the input asks what to change. Nil while the list is up for anything else.
    @State private var improving: Improving?

    struct Improving {
        let target: ImproveTarget
        /// The picture of the screen, shown under the input until it's taken off.
        var thumb: UIImage?
        /// How the prompt refers to it once its Mac has it; nil while it's on its way or taken off.
        var shot: ImproveShot?
        var keeping = false
        var problem: String?
    }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                Divider()
                list
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !store.devices.isEmpty {
                    StartBar(composer: $composer, project: project, prompt: query, duplicate: route.flatMap { routedFor == query ? $0.duplicate : nil }, problem: problem, acting: acting) {
                        Task { await start() }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                // A view of its own per session: going from one to another by a link keeps nothing.
                // Next puts the next session in this one's place, so Back is still this list.
                // One a swipe slid in starts as the swipe drew it. A PR's is `pr:` and its key.
                if key.hasPrefix(PrView.prefix) {
                    PrView(key: String(key.dropFirst(PrView.prefix.count))).id(key)
                } else {
                    SessionView(key: key, opening: store.slidIn.flatMap { $0.key == key ? $0.opening : nil }, go: { next in path = [next] }).id(key)
                }
            }
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
            .task(id: query) { await searchSaid() }
            .onAppear {
                // Text typed for a test at launch (`QUERY=<text> scripts/run.sh`).
                if let q = ProcessInfo.processInfo.environment["CODEALONG_QUERY"], !q.isEmpty, text.isEmpty { text = q }
                // Improve Codealong pressed for a test at launch (`IMPROVE=1 scripts/run.sh`), once the Macs have answered.
                if ProcessInfo.processInfo.environment["CODEALONG_IMPROVE"] == "1" {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        improveCodealong()
                    }
                }
            }
            .task(id: "\(query)\u{1}\(project)\u{1}\(routeDevice ?? "")") { await suggest() }
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
    }

    /// Asks a Mac for something from a row's menu, saying what went wrong if it didn't go.
    private func act(_ ask: @escaping () async throws -> Void) {
        Task {
            do { try await ask() } catch { store.notice = words(error) }
        }
    }

    // MARK: The input

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                projectMenu
                Spacer(minLength: 0)
                Button { improveCodealong() } label: {
                    Image(systemName: "lightbulb")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.glass)
                .tint(improving == nil ? nil : .orange)
                .disabled(store.devices.isEmpty)
                .accessibilityLabel("Improve Codealong")
                .accessibilityHint("Starts a session that improves Codealong itself, with a picture of this screen")
                Button { showingMacs = true } label: {
                    Image(systemName: "laptopcomputer")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.glass)
                .tint(macsNeedAttention ? .orange : nil)
                .accessibilityLabel("Macs")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField(improving == nil ? "Find a session, or describe new work…" : "Describe how to improve Codealong…", text: $text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...6)
                    .focused($typing)
                    .submitLabel(.return)
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
            if let improving {
                improveStrip(improving)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Improve Codealong's picture of the screen, as the Mac's panel shows its pictures under the
    /// input: a thumbnail with a button to take it off, and where the session goes.
    @ViewBuilder
    private func improveStrip(_ improving: Improving) -> some View {
        HStack(spacing: 10) {
            if let thumb = improving.thumb {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 72)
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        .opacity(improving.keeping ? 0.5 : 1)
                    Button {
                        self.improving?.thumb = nil
                        self.improving?.shot = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .accessibilityLabel("Remove the picture")
                }
                .accessibilityLabel(improving.keeping ? "A picture of this screen, on its way to the Mac" : "A picture of this screen")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Improving Codealong")
                    .font(.subheadline.weight(.semibold))
                Text(improving.problem ?? (improving.thumb == nil ? "Without a picture of this screen." : improving.keeping ? "Keeping a picture of this screen on the Mac…" : "With a picture of this screen as it was."))
                    .font(.footnote)
                    .foregroundStyle(improving.problem == nil ? .secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Cancel") { self.improving = nil }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var projectMenu: some View {
        Menu {
            Picker("Project", selection: $project) {
                Text("All projects").tag("")
                ForEach(projects, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.subheadline)
                Text(project.isEmpty ? "All projects" : project)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
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
        .accessibilityLabel(project.isEmpty ? "Projects" : "Project: \(project)")
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        let quick = store.quick(project: project, query: query, said: said, ranked: routedFor == query ? route?.ranked ?? [] : [])
        let suggested = routedFor == query ? route?.suggestions ?? [] : []
        List {
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
                notes(quick, suggested: suggested)
            }
            if !suggested.isEmpty {
                Section {
                    ForEach(suggested, id: \.key) { s in
                        SuggestionRow(suggestion: s, composer: composer, showDevice: store.devices.count > 1)
                            .contentShape(.rect)
                            .onTapGesture { Task { await act(s) } }
                    }
                } header: {
                    GroupHeading(title: "Suggested", count: suggested.count)
                }
            }
            ForEach(quick.sections, id: \.group) { section in
                Section {
                    ForEach(section.rows, id: \.id) { row in
                        switch row {
                        case let .session(r, hit):
                            QuickSessionRow(row: r, said: hit, words: matching, showDevice: store.devices.count > 1, showProject: project.isEmpty)
                                .contentShape(.rect)
                                .onTapGesture { path.append(r.key) }
                                // As a session's right-click menu on the Mac: seen or unread, snooze,
                                // quiet.
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
                        case let .pr(pr):
                            QuickPrRow(pr: pr, words: matching)
                                .contentShape(.rect)
                                .onTapGesture {
                                    // A PR its Mac can read from GitHub opens here; one whose repo
                                    // has no GitHub name there, on GitHub.
                                    if !pr.slug.isEmpty {
                                        path.append(PrView.prefix + pr.key)
                                    } else if let url = URL(string: pr.url) {
                                        openURL(url)
                                    }
                                }
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
                    }
                } header: {
                    GroupHeading(title: section.group.title, count: Int(section.count))
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState }
    }

    @ViewBuilder
    private func notes(_ quick: QuickList, suggested: [Suggestion]) -> some View {
        Group {
            if query.isEmpty && quick.nothingWaits {
                Note(text: "Nothing needs you\(quick.working > 0 ? " · \(quick.working) working" : "").")
            }
            if routing {
                Note(text: "Working out where this goes…", symbol: "sparkles")
            }
            if let routeProblem, !query.isEmpty {
                Note(text: "Couldn’t suggest where this goes: \(routeProblem)")
            }
            if !query.isEmpty && quick.sections.isEmpty && suggested.isEmpty && !routing {
                Note(text: "No sessions or PRs match. Start a session with this prompt below.")
            }
            if !query.isEmpty && saidBuilding {
                Note(text: "Still reading what recent sessions said, so more may match in a moment.")
            }
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.devices.isEmpty {
            ContentUnavailableView {
                Label("Link a Mac", systemImage: "laptopcomputer.and.iphone")
            } description: {
                Text("Make a link code on your Mac in Codealong's Settings › Devices, then scan it or enter it here.")
            } actions: {
                Button("Link a Mac") { showingMacs = true }
                    .buttonStyle(.glassProminent)
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
    private func suggest() async {
        routeProblem = nil
        guard worthRouting(text: query), let device = routeDevice else {
            routing = false
            route = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        routing = true
        let asked = query
        do {
            let got = try await store.route(device: device, project: project, text: asked)
            if Task.isCancelled { return }
            route = got
            routedFor = asked
        } catch {
            if Task.isCancelled { return }
            route = nil
            routeProblem = words(error)
        }
        routing = false
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
            guard let row = s.session else { return }
            store.post(row.key, title: row.title, text: query, how: .send(now: false))
            text = ""
            store.dealtWith(row.key)
            path.append(row.key)
        case .start:
            guard let w = s.worktree else { return }
            await start(in: w, newWorktree: s.newWorktree)
        }
    }

    /// Starts a session with what's typed: in the worktree chosen below, or where a suggestion says.
    private func start(in over: Worktree? = nil, newWorktree over2: Bool? = nil) async {
        let worktree = over ?? composer.worktree(store: store, project: project)
        guard let worktree, let account = composer.account, let place = composer.place else { return }
        let newTree = composer.takesNewWorktree && !worktree.chat && (over2 ?? composer.newWorktree)
        // The picture is still on its way to the Mac: the prompt would go without it.
        if improving?.keeping == true {
            problem = "The picture of the screen is still on its way to the Mac. Try again in a moment."
            return
        }
        acting = true
        problem = nil
        defer { acting = false }
        // Improving Codealong: the picture of the screen goes after what you wrote, as the Mac's
        // panel writes it (the core's rule).
        let prompt = improving.map { improvePrompt(text: query, shots: $0.shot.map { [$0] } ?? []) } ?? query
        do {
            let started = try await store.startSession(device: worktree.device, worktree: worktree.id, account: account, place: place, prompt: prompt, model: composer.takesModel ? composer.model : nil, effort: composer.takesModel ? composer.effort : nil, newWorktree: newTree)
            text = ""
            typing = false
            improving = nil
            // It opens once its Mac lists it; a start whose id the Mac doesn't know yet says what's next.
            if let key = started.key {
                store.openWhenListed = key
            } else if let message = started.message {
                store.notice = message
            }
        } catch {
            problem = words(error)
        }
    }

    /// Improve Codealong: a picture of this screen as it is, then the list onto Codealong's own
    /// project and worktree on the Mac the core picks, with the picture on its way there for the
    /// prompt. With no Mac marking Codealong's source (none has it, or they run a Codealong from
    /// before the mark), it says so and changes nothing.
    private func improveCodealong() {
        guard let target = store.improveTarget() else {
            store.notice = "No Mac lists Codealong’s source. Clone github.com/codealong/codealong into a folder Codealong searches on a Mac, in a project there, and make sure the Mac runs a Codealong from October 12 or later."
            return
        }
        // The picture first, before anything here changes.
        let picture = screenshot()
        improving = Improving(target: target, thumb: picture?.image, shot: nil, keeping: picture != nil)
        composer.device = target.device
        if project != target.project {
            project = target.project
            // The start bar drops the worktree picked when the project changes, so this one goes in after.
            let worktree = target.worktree
            Task { @MainActor in
                await Task.yield()
                composer.worktreeID = worktree
            }
        } else {
            composer.worktreeID = target.worktree
        }
        typing = true
        guard let picture else { return }
        Task {
            do {
                let reference = try await store.keepScreenshot(picture.data, on: target.device)
                // Taken off meanwhile, or the list opened for something else: the picture stays out.
                guard improving?.target == target, improving?.thumb != nil else { return }
                improving?.shot = ImproveShot(name: "iPhone screen", reference: reference)
                improving?.keeping = false
            } catch {
                improving?.thumb = nil
                improving?.keeping = false
                improving?.problem = "The picture couldn’t be kept on the Mac: \(words(error))"
            }
        }
    }

    /// This screen as it's drawn now, as PNG bytes and an image, or nil with no window to draw.
    private func screenshot() -> (data: Data, image: UIImage)? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData() else { return nil }
        return (data, image)
    }

    private func openListed() {
        guard let key = store.openWhenListed else { return }
        let listed = key.hasPrefix(PrView.prefix) ? store.pr(String(key.dropFirst(PrView.prefix.count))) != nil : store.sessions.contains { $0.key == key }
        if listed {
            store.openWhenListed = nil
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

    /// The projects the list can narrow to, as the core lists them. One narrowed to stays while
    /// it has nothing to show, so the menu still says so.
    private var projects: [String] {
        project.isEmpty || store.projects.contains(project) ? store.projects : [project] + store.projects
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
            Text("\(count)").foregroundStyle(.tertiary)
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
