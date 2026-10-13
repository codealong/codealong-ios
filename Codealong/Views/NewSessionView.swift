import SwiftUI

/// Starting a session, as Codex's phone app starts a chat. What the Mac suggests for what's typed
/// is at the top; over the keyboard are the Mac, the worktree and the box, with the account and
/// the model in it. It zooms out of the list's capsule, or opens from a worktree's ✎ in the list
/// by project, which picks that worktree. A suggestion that opens or sends to a session, and a
/// start once its Mac lists the session, put that session in this screen's place.
struct NewSessionView: View {
    @Binding var composer: Composer
    /// The project the list is narrowed to: where new work goes unless a worktree is picked.
    let project: String
    /// Opens a session in this screen's place.
    let go: (String) -> Void

    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var typing: Bool
    /// A Mac's suggestions for what's typed, and the text they're for.
    @State private var route: RouteAnswer?
    @State private var routedFor = ""
    @State private var routing = false
    @State private var routeProblem: String?
    @State private var problem: String?
    @State private var acting = false
    /// Starts that went, for the haptic.
    @State private var started = 0
    @State private var pickingWorktree = false
    @AppStorage("start.account") private var lastAccount = ""
    @AppStorage("start.place") private var lastPlace = ""
    @AppStorage("start.device") private var lastDevice = ""

    private var prompt: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var mac: DeviceRow? { store.devices.first { $0.key == composer.device } }
    private var worktree: Worktree? { composer.worktree(store: store, project: project) }
    private var suggested: [Suggestion] { routedFor == prompt ? route?.suggestions ?? [] : [] }
    private var duplicate: SessionRow? { routedFor == prompt ? route?.duplicate : nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let improving = store.improving {
                        ImproveStrip(improving: improving)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    suggestions
                }
                .padding(.top, 8)
                .animation(.smooth, value: suggested.map(\.key))
                .animation(.smooth, value: routing)
            }
            .scrollDismissesKeyboard(.interactively)
            // The box takes the lines it needs before the suggestions get any: with the keyboard
            // up, an even split would leave it too short, scrolling its first lines away.
            controls
                .layoutPriority(1)
        }
        .navigationTitle("New session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { typing = true }
        .task(id: "\(prompt)\u{1}\(project)\u{1}\(routeDevice ?? "")") { await suggest() }
        .sheet(isPresented: $pickingWorktree) {
            NavigationStack {
                WorktreePicker(worktrees: composer.device.map { store.worktrees($0) } ?? [], chosen: Binding(get: { worktree }, set: { composer.worktreeID = $0?.id }), first: project.isEmpty ? nil : project)
            }
        }
        .sensoryFeedback(.success, trigger: started)
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestions: some View {
        if routing && suggested.isEmpty {
            Label("Working out where this goes…", systemImage: "sparkles")
                .symbolEffect(.pulse, options: .repeating)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .transition(.opacity)
        }
        if let routeProblem, !prompt.isEmpty {
            Text("Couldn’t suggest where this goes: \(routeProblem)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
        if !suggested.isEmpty {
            GroupHeading(title: "Suggested", count: suggested.count)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            ForEach(suggested, id: \.key) { s in
                Button { Task { await act(s) } } label: {
                    SuggestionRow(suggestion: s, composer: composer, showDevice: store.devices.count > 1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    // MARK: Where it starts, and the box

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.devices.count > 1 {
                Menu {
                    Picker("Mac", selection: Binding(get: { composer.device }, set: { composer.device = $0; lastDevice = $0 ?? "" })) {
                        ForEach(store.devices, id: \.key) { d in
                            Text(d.online ? d.name : "\(d.name) (not connected)").tag(Optional(d.key))
                        }
                    }
                } label: {
                    PickLine(symbol: "laptopcomputer", text: mac.map { Names.short($0.name) } ?? "Choose a Mac")
                }
            }
            HStack(spacing: 0) {
                Button { pickingWorktree = true } label: {
                    PickLine(symbol: worktree?.chat == true ? "bubble.left" : "folder", text: worktreeName)
                }
                .buttonStyle(.plain)
                .disabled(composer.device == nil)
                Spacer(minLength: 8)
                if takesNewWorktree {
                    Button {
                        withAnimation(.snappy) { composer.newWorktree.toggle() }
                    } label: {
                        Label("New worktree", systemImage: composer.newWorktree ? "checkmark.square.fill" : "square")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.trailing, 8)
            box
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(happens)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .lineLimit(3)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .contentTransition(.opacity)
            .animation(.smooth, value: happens)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: takesNewWorktree)
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(store.improving == nil ? "Describe the work…" : "Describe how to improve Codealong…", text: $text, axis: .vertical)
                .font(.body)
                .lineLimit(1...8)
                .focused($typing)
            HStack(spacing: 8) {
                accountMenu
                Spacer(minLength: 4)
                modelMenu
                Button { Task { await start() } } label: {
                    ZStack {
                        if acting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.orange, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .opacity(ready ? 1 : 0.4)
                .animation(.snappy, value: ready)
                .accessibilityLabel("Start")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.top, 4)
    }

    private var accountMenu: some View {
        Menu {
            if let choices = composer.choices {
                Picker("Account", selection: Binding(get: { composer.account }, set: { pickAccount($0) })) {
                    ForEach(choices.accounts.filter { $0.unavailable == nil }, id: \.name) { a in
                        Text("\(a.name) · \(a.harness)").tag(Optional(a.name))
                    }
                }
            }
        } label: {
            Chip(symbol: "person", text: composer.account ?? (composer.choicesProblem == nil ? "Account" : "No accounts"))
        }
        .tint(.primary)
        .disabled(composer.choices == nil)
    }

    /// The model, effort and place, as the reply box's model menu has them: the model on top, where
    /// it runs under it.
    private var modelMenu: some View {
        Menu {
            if let a = composer.chosenAccount, composer.takesModel, !a.models.isEmpty {
                Picker("Model", selection: $composer.model) {
                    Text(composer.defaultModelLabel.map { "Default (\($0))" } ?? "Default").tag(String?.none)
                    ForEach(a.models, id: \.id) { m in
                        Text(m.label).tag(Optional(m.id))
                    }
                }
            }
            if let a = composer.chosenAccount, composer.takesModel, !a.efforts.isEmpty {
                Picker("Effort", selection: $composer.effort) {
                    Text("Default effort").tag(String?.none)
                    ForEach(a.efforts, id: \.id) { e in
                        Text(e.label).tag(Optional(e.id))
                    }
                }
            }
            if let a = composer.chosenAccount, !a.places.isEmpty {
                Picker("Runs in", selection: Binding(get: { composer.place }, set: { composer.place = $0; lastPlace = $0 ?? "" })) {
                    ForEach(a.places, id: \.id) { p in
                        // Background with no service of its own is a terminal behind the Mac's windows.
                        Label(p.behind ? "\(p.label) (behind its windows)" : p.label, systemImage: Self.placeSymbol(p.id)).tag(Optional(p.id))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                VStack(alignment: .trailing, spacing: 0) {
                    if let model = modelWords {
                        Text(model)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    if let place = placeWords {
                        Text(place)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentTransition(.opacity)
        }
        .tint(.primary)
        .disabled(composer.chosenAccount == nil)
    }

    private var modelWords: String? {
        guard composer.takesModel else { return nil }
        let model = composer.modelLabel ?? composer.defaultModelLabel ?? "Default model"
        return [model, composer.effortLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private var placeWords: String? {
        guard let a = composer.chosenAccount, let label = a.places.first(where: { $0.id == composer.place })?.label else { return nil }
        return "in \(label)"
    }

    private var worktreeName: String {
        guard let w = worktree else { return composer.device == nil ? "No Mac" : "No worktree" }
        return w.chat ? "No project" : w.main ? "\(w.name) (main)" : w.name
    }

    /// A chat has no repo to make a worktree of.
    private var takesNewWorktree: Bool { composer.takesNewWorktree && worktree?.chat != true }

    static func placeSymbol(_ id: String) -> String {
        switch id {
        case "terminal": "terminal"
        case "background": "square.stack.3d.up"
        case "codealong": "sparkles"
        default: "macwindow"
        }
    }

    // MARK: Starting

    /// Why nothing can start on the Mac chosen, when nothing can.
    private var whyNot: String? {
        guard let mac else { return "Choose a Mac to start on." }
        if !mac.online { return "\(Names.short(mac.name)) isn't connected." }
        if !mac.remoteControl { return "Remote control is off on \(Names.short(mac.name)): turn it on there in Settings › Devices to start sessions from here." }
        return nil
    }

    private var ready: Bool {
        whyNot == nil && worktree != nil && composer.account != nil && composer.place != nil && !acting
    }

    /// What starting does, in a sentence, as the start bar said it.
    private var happens: String {
        if let whyNot { return whyNot }
        guard let w = worktree else { return project.isEmpty ? "No worktrees on this Mac." : "No worktrees in \(project) on this Mac." }
        if let why = composer.choicesProblem { return "\(Names.short(mac?.name ?? "The Mac")) didn’t say where its accounts can start: \(why)" }
        if composer.account == nil || composer.place == nil { return "Asking \(Names.short(mac?.name ?? "the Mac")) where it can start…" }
        var out = composer.happens(in: w, newWorktree: takesNewWorktree && composer.newWorktree)
        if store.devices.count > 1, let mac { out = "On \(Names.short(mac.name)): " + out }
        if let duplicate { out += " “\(duplicate.title)” (\(duplicate.account) · \(duplicate.worktree)) may already be doing this." }
        return out
    }

    private func pickAccount(_ name: String?) {
        composer.account = name
        lastAccount = name ?? ""
        let a = composer.chosenAccount
        composer.place = a?.places.first { $0.id == lastPlace }?.id ?? a?.place
        composer.model = nil
        composer.effort = nil
    }

    /// The Mac that suggests: the one new sessions start on, else any that's connected.
    private var routeDevice: String? {
        if let d = composer.device, store.devices.contains(where: { $0.key == d && $0.online }) { return d }
        return store.devices.first { $0.online }?.key
    }

    /// Asks the Mac chosen where what's typed goes, once typing pauses on a few words.
    private func suggest() async {
        routeProblem = nil
        guard worthRouting(text: prompt), let device = routeDevice else {
            routing = false
            route = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        routing = true
        let asked = prompt
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

    private func act(_ s: Suggestion) async {
        switch s.kind {
        case .open:
            if let key = s.session?.key { go(key) }
        case .send:
            // It goes as a reply in the session's screen goes: shown there at once, back in its
            // box if it doesn't go.
            guard let row = s.session else { return }
            store.post(row.key, title: row.title, text: prompt, how: .send(now: false))
            text = ""
            store.dealtWith(row.key)
            go(row.key)
        case .start:
            guard let w = s.worktree else { return }
            await start(in: w, newWorktree: s.newWorktree)
        }
    }

    /// Starts a session with what's typed: in the worktree chosen, or where a suggestion says.
    private func start(in over: Worktree? = nil, newWorktree over2: Bool? = nil) async {
        let worktree = over ?? self.worktree
        guard let worktree, let account = composer.account, let place = composer.place else { return }
        let newTree = composer.takesNewWorktree && !worktree.chat && (over2 ?? composer.newWorktree)
        // The picture is still on its way to the Mac: the prompt would go without it.
        if store.improving?.keeping == true {
            problem = "The picture of the screen is still on its way to the Mac. Try again in a moment."
            return
        }
        acting = true
        problem = nil
        // Improving Codealong: the picture of the screen goes after what you wrote, as the Mac's
        // panel writes it (the core's rule).
        let prompt = store.improving.map { improvePrompt(text: self.prompt, shots: $0.shot.map { [$0] } ?? []) } ?? self.prompt
        do {
            let begun = try await store.startSession(device: worktree.device, worktree: worktree.id, account: account, place: place, prompt: prompt, model: composer.takesModel ? composer.model : nil, effort: composer.takesModel ? composer.effort : nil, newWorktree: newTree)
            started += 1
            text = ""
            typing = false
            store.improving = nil
            // It opens in this screen's place once its Mac lists it (the list watches for that);
            // a start whose id the Mac doesn't know yet says what's next, and the list comes back.
            if let key = begun.key {
                store.openWhenListed = key
                // One its Mac doesn't list (it went offline, or the terminal's command failed)
                // gives the box back, still opening if it turns up.
                try? await Task.sleep(for: .seconds(30))
                if store.openWhenListed == key {
                    acting = false
                    problem = "It started, but \(Names.short(mac?.name ?? "the Mac")) hasn’t listed it yet. It opens here once it does."
                }
            } else {
                acting = false
                if let message = begun.message { store.notice = message }
                dismiss()
            }
        } catch {
            acting = false
            problem = words(error)
        }
    }
}

/// One of New session's choices over the box: a symbol, what's chosen, and the up-down mark of a
/// menu, as Codex's phone app has its Mac and folder.
private struct PickLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
            Text(text)
                .lineLimit(1)
                .contentTransition(.opacity)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

/// Improve Codealong's picture of the screen over New session's box: a thumbnail with a button to
/// take it off, and where it stands.
struct ImproveStrip: View {
    let improving: Store.Improving
    @Environment(Store.self) private var store

    var body: some View {
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
                        withAnimation(.snappy) {
                            store.improving?.thumb = nil
                            store.improving?.shot = nil
                        }
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
                .transition(.scale.combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Improving Codealong")
                    .font(.subheadline.weight(.semibold))
                Text(improving.problem ?? (improving.thumb == nil ? "Without a picture of the screen." : improving.keeping ? "Keeping a picture of the screen on the Mac…" : "With a picture of the screen as it was."))
                    .font(.footnote)
                    .foregroundStyle(improving.problem == nil ? .secondary : Color.red)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Button("Cancel") { withAnimation(.snappy) { store.improving = nil } }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}
