import SwiftUI

/// The bottom of the quick search: a glass capsule over the list that starts a new session with
/// what's typed, or with nothing typed puts the cursor in the box for it. Under its title is where
/// the session starts, and its menu changes that (the Mac, the worktree, the account, model and
/// place), as the chips under the Mac's panel do; small, so the list keeps the screen. Over it are
/// the Mac's suggestions for what's typed (send it to a session, open one, or start it elsewhere),
/// which the Mac's panel lists first: here they ride above the keyboard with the capsule, where
/// the keyboard can't cover them, and scroll among themselves when the list leaves too little room
/// for them all. The list reads the Mac's choices into the composer.
struct StartBar: View {
    @Binding var composer: Composer
    let project: String
    let prompt: String
    /// Where what's typed goes, as the Mac suggests it.
    let suggestions: [Suggestion]
    /// The suggestions are for what was typed before: shown dimmed, doing nothing, until the
    /// Mac answers for what's typed now.
    let stale: Bool
    /// A session that may already be doing what's typed.
    let duplicate: SessionRow?
    let problem: String?
    let acting: Bool
    /// How tall the list under it is: the bar leaves a little of it showing.
    let room: CGFloat
    /// Starts with what's typed; with nothing typed, asks for it.
    let start: () -> Void
    /// Does what a suggestion says.
    let suggest: (Suggestion) -> Void

    @Environment(Store.self) private var store
    @State private var pickingWorktree = false
    /// How tall the suggestions are, all of them, and the line over the capsule.
    @State private var suggestionsHeight: CGFloat = 0
    @State private var noteHeight: CGFloat = 0
    /// The last account, place and Mac you started with, to start with again.
    @AppStorage("start.account") private var lastAccount = ""
    @AppStorage("start.place") private var lastPlace = ""
    @AppStorage("start.device") private var lastDevice = ""

    private var mac: DeviceRow? { store.devices.first { $0.key == composer.device } }
    private var worktree: Worktree? { composer.worktree(store: store, project: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !suggestions.isEmpty && !prompt.isEmpty {
                suggested
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let note {
                Label(note.text, systemImage: note.symbol)
                    .font(.footnote)
                    .foregroundStyle(note.color)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteHeight = $0 }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 4) {
                Button(action: start) {
                    HStack(spacing: 12) {
                        ZStack {
                            if acting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus").font(.body.weight(.bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.orange, in: .circle)
                        .opacity(prompt.isEmpty || ready ? 1 : 0.4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(prompt.isEmpty ? "Start a session…" : "Start with this prompt")
                                .font(.body.weight(prompt.isEmpty ? .regular : .semibold))
                                .foregroundStyle(prompt.isEmpty ? .secondary : .primary)
                            Text(whereWords)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 10)
                    .frame(height: 56)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // With nothing typed it asks for the prompt, which it can do whatever the Mac says.
                .disabled(!prompt.isEmpty && !ready)
                .accessibilityLabel(prompt.isEmpty ? "Start a session" : "Start a session with this prompt")
                .accessibilityValue(happens)
                choices
            }
            .padding(.trailing, 6)
            // Tinted with the page, so the rows scrolling under it don't read through its words.
            .glassEffect(.regular.tint(Color(.systemBackground).opacity(0.7)).interactive(), in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .animation(.snappy, value: note?.text)
        .animation(.snappy, value: prompt.isEmpty)
        .animation(.smooth, value: suggestions.map(\.key))
        .sheet(isPresented: $pickingWorktree) {
            NavigationStack {
                WorktreePicker(worktrees: composer.device.map { store.worktrees($0) } ?? [], chosen: Binding(get: { worktree }, set: { composer.worktreeID = $0?.id }), first: project.isEmpty ? nil : project)
            }
        }
    }

    // MARK: Suggestions

    /// The suggestions, in a glass card of their own over the capsule, each a tap from doing what
    /// it says. They take what room the list leaves, less the capsule (its 56 points, under 4 and
    /// 6 between), the line over it and a little of the list, and scroll within it past that.
    /// Never less than a row's start, though: with a long prompt on a small phone the bar then
    /// reaches over the box's last lines rather than leave no suggestion to tap, as when the list
    /// had them.
    private var suggested: some View {
        let others = 56 + 4 + 6 + (note == nil ? 0 : noteHeight + 6)
        let most = room > 0 ? max(64, room - others - 24) : .infinity
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.key) { i, s in
                    if i > 0 {
                        Divider().padding(.leading, 52)
                    }
                    Button { suggest(s) } label: {
                        SuggestionRow(suggestion: s, composer: composer, showDevice: store.devices.count > 1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // One at a time: a second tap while photos go to the Mac would send twice.
                    .disabled(stale || (acting && s.kind != .open))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { suggestionsHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.never)
        .frame(height: min(suggestionsHeight, most))
        .opacity(stale ? 0.5 : 1)
        .glassEffect(.regular.tint(Color(.systemBackground).opacity(0.7)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested")
    }

    // MARK: Where it starts

    /// The Mac, the worktree, the account, model and effort, and where it runs, under what starting
    /// does in a sentence.
    private var choices: some View {
        Menu {
            Section(happens) {
                if store.devices.count > 1 {
                    Picker(selection: Binding(get: { composer.device }, set: { composer.device = $0; lastDevice = $0 ?? "" })) {
                        ForEach(store.devices, id: \.key) { d in
                            Text(d.online ? d.name : "\(d.name) (not connected)").tag(Optional(d.key))
                        }
                    } label: {
                        Label("Mac", systemImage: "laptopcomputer")
                    }
                    .pickerStyle(.menu)
                }
                Button { pickingWorktree = true } label: {
                    Label {
                        Text("Worktree")
                        Text(worktreeName)
                    } icon: {
                        Image(systemName: worktree?.chat == true ? "bubble.left" : "folder")
                    }
                }
                .disabled(composer.device == nil)
                if takesNewWorktree {
                    Toggle(isOn: $composer.newWorktree) {
                        Label("New worktree", systemImage: "plus.square.on.square")
                    }
                }
            }
            if let choices = composer.choices {
                Section {
                    Picker(selection: Binding(get: { composer.account }, set: { pickAccount($0) })) {
                        ForEach(choices.accounts.filter { $0.unavailable == nil }, id: \.name) { a in
                            Text("\(a.name) · \(a.harness)").tag(Optional(a.name))
                        }
                    } label: {
                        Label("Account", systemImage: "person")
                    }
                    .pickerStyle(.menu)
                    if let a = composer.chosenAccount, composer.takesModel, !a.models.isEmpty {
                        Picker(selection: $composer.model) {
                            Text(composer.defaultModelLabel.map { "Default (\($0))" } ?? "Default").tag(String?.none)
                            ForEach(a.models, id: \.id) { m in
                                Text(m.label).tag(Optional(m.id))
                            }
                        } label: {
                            Label("Model", systemImage: "cpu")
                        }
                        .pickerStyle(.menu)
                    }
                    if let a = composer.chosenAccount, composer.takesModel, !a.efforts.isEmpty {
                        Picker(selection: $composer.effort) {
                            Text("Default effort").tag(String?.none)
                            ForEach(a.efforts, id: \.id) { e in
                                Text(e.label).tag(Optional(e.id))
                            }
                        } label: {
                            Label("Effort", systemImage: "gauge.with.dots.needle.50percent")
                        }
                        .pickerStyle(.menu)
                    }
                    if let a = composer.chosenAccount, !a.places.isEmpty {
                        Picker(selection: Binding(get: { composer.place }, set: { composer.place = $0; lastPlace = $0 ?? "" })) {
                            ForEach(a.places, id: \.id) { p in
                                // Background with no service of its own is a terminal behind the Mac's windows.
                                Label(p.behind ? "\(p.label) (behind its windows)" : p.label, systemImage: placeSymbol(p.id)).tag(Optional(p.id))
                            }
                        } label: {
                            Label("Runs in", systemImage: placeSymbol(composer.place ?? ""))
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .tint(.primary)
        .accessibilityLabel("Where it starts")
        .accessibilityValue(whereWords)
    }

    private var worktreeName: String {
        guard let w = worktree else { return composer.device == nil ? "No Mac" : "No worktree" }
        return w.chat ? "No project" : w.main ? "\(w.name) (main)" : w.name
    }

    /// A chat has no repo to make a worktree of.
    private var takesNewWorktree: Bool { composer.takesNewWorktree && worktree?.chat != true }

    private func placeSymbol(_ id: String) -> String {
        switch id {
        case "terminal": "terminal"
        case "background": "square.stack.3d.up"
        case "codealong": "sparkles"
        default: "macwindow"
        }
    }

    // MARK: Starting

    /// Why nothing can start on the Mac chosen, when nothing can: in a few words under the
    /// capsule's title, and in full over it once there's a prompt to start.
    private var whyNot: (short: String, full: String)? {
        guard let mac else { return ("Choose a Mac to start on", "Choose a Mac to start on.") }
        let name = Names.short(mac.name)
        if !mac.online { return ("\(name) isn't connected", "\(name) isn't connected.") }
        if !mac.remoteControl { return ("Remote control is off on \(name)", "Remote control is off on \(name): turn it on there in Settings › Devices to start sessions from here.") }
        return nil
    }

    private var ready: Bool {
        whyNot == nil && worktree != nil && composer.account != nil && composer.place != nil && !acting
    }

    /// What starting does, in a sentence, as the Mac's panel says it: over the capsule's menu.
    private var happens: String {
        if let whyNot { return whyNot.full }
        guard let w = worktree else { return project.isEmpty ? "No worktrees on this Mac." : "No worktrees in \(project) on this Mac." }
        if let why = composer.choicesProblem { return "\(Names.short(mac?.name ?? "The Mac")) didn’t say where its accounts can start: \(why)" }
        if composer.account == nil || composer.place == nil { return "Asking \(Names.short(mac?.name ?? "the Mac")) where it can start…" }
        var out = composer.happens(in: w, newWorktree: takesNewWorktree && composer.newWorktree)
        if store.devices.count > 1, let mac { out = "On \(Names.short(mac.name)): " + out }
        return out
    }

    /// Where it starts, on one line under the capsule's title: the Mac where there are several, the
    /// worktree, the account, the model, and where it runs when that isn't where the account
    /// usually starts (the line is short; the menu has it all).
    private var whereWords: String {
        if let whyNot { return whyNot.short }
        guard let w = worktree else { return project.isEmpty ? "No worktrees on this Mac" : "No worktrees in \(project) on this Mac" }
        if composer.choicesProblem != nil { return "\(Names.short(mac?.name ?? "The Mac")) didn’t say where it can start" }
        guard let account = composer.account else { return "Asking \(Names.short(mac?.name ?? "the Mac")) where it can start…" }
        var parts: [String] = []
        if store.devices.count > 1, let mac { parts.append(Names.short(mac.name)) }
        parts.append(takesNewWorktree && composer.newWorktree ? "a new worktree of \(w.repo)" : worktreeName)
        parts.append(account)
        if composer.takesModel, let model = composer.modelLabel ?? composer.defaultModelLabel { parts.append(model) }
        if let a = composer.chosenAccount, composer.place != a.place, let place = a.places.first(where: { $0.id == composer.place })?.label { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    /// A line over the capsule: a start that didn't go, why one can't, or a session that may
    /// already be doing what's typed.
    private var note: (text: String, symbol: String, color: Color)? {
        if let problem { return (problem, "exclamationmark.triangle.fill", .red) }
        guard !prompt.isEmpty else { return nil }
        if let whyNot { return (whyNot.full, "exclamationmark.triangle.fill", .orange) }
        if let duplicate { return ("“\(duplicate.title)” (\(duplicate.account) · \(duplicate.worktree)) may already be doing this.", "square.on.square", .secondary) }
        return nil
    }

    private func pickAccount(_ name: String?) {
        composer.account = name
        lastAccount = name ?? ""
        let a = composer.chosenAccount
        composer.place = a?.places.first { $0.id == lastPlace }?.id ?? a?.place
        composer.model = nil
        composer.effort = nil
    }
}

/// Improve Codealong's picture of the screen under the quick search's input, as the Mac's panel
/// shows its pictures under its input: a thumbnail with a button to take it off, and where it
/// stands.
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
