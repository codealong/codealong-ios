import SwiftUI

/// The bottom of the quick search: the row that starts a new session with what's typed, and the
/// chips that say where. It rides above the keyboard, as the Mac's panel keeps it under the list.
/// The list reads the Mac's choices into the composer; the chips change them.
struct StartBar: View {
    @Binding var composer: Composer
    let project: String
    let prompt: String
    /// A session that may already be doing what's typed.
    let duplicate: SessionRow?
    let problem: String?
    let acting: Bool
    let start: () -> Void

    @Environment(Store.self) private var store
    @State private var pickingWorktree = false
    /// The last account, place and Mac you started with, to start with again.
    @AppStorage("start.account") private var lastAccount = ""
    @AppStorage("start.place") private var lastPlace = ""
    @AppStorage("start.device") private var lastDevice = ""

    private var mac: DeviceRow? { store.devices.first { $0.key == composer.device } }
    private var worktree: Worktree? { composer.worktree(store: store, project: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button(action: start) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.orange, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.isEmpty ? "Start a new session" : "Start a new session with this prompt")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(happens)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if acting { ProgressView() }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .opacity(ready ? 1 : 0.5)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if store.devices.count > 1 { macChip }
                    worktreeChip
                    newWorktreeChip
                    agentChip
                    placeChip
                }
                .padding(.horizontal, 16)
                .tint(.primary)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 10)
        }
        .background(.bar)
        .sheet(isPresented: $pickingWorktree) {
            NavigationStack {
                WorktreePicker(worktrees: composer.device.map { store.worktrees($0) } ?? [], chosen: Binding(get: { worktree }, set: { composer.worktreeID = $0?.id }), first: project.isEmpty ? nil : project)
            }
        }
    }

    // MARK: Chips

    private var macChip: some View {
        Menu {
            Picker("Mac", selection: Binding(get: { composer.device }, set: { composer.device = $0; lastDevice = $0 ?? "" })) {
                ForEach(store.devices, id: \.key) { d in
                    Text(d.online ? d.name : "\(d.name) (not connected)").tag(Optional(d.key))
                }
            }
        } label: {
            Chip(symbol: "laptopcomputer", text: mac.map { Names.short($0.name) } ?? "Mac")
        }
    }

    private var worktreeChip: some View {
        Button { pickingWorktree = true } label: {
            Chip(symbol: worktree?.chat == true ? "bubble.left" : "folder", text: worktree.map { $0.chat ? "No project" : $0.main ? "\($0.name) (main)" : $0.name } ?? "No worktree")
        }
        .buttonStyle(.plain)
        .disabled(composer.device == nil)
    }

    /// A chat has no repo to make a worktree of.
    private var takesNewWorktree: Bool { composer.takesNewWorktree && worktree?.chat != true }

    private var newWorktreeChip: some View {
        Button { composer.newWorktree.toggle() } label: {
            Chip(symbol: composer.newWorktree && takesNewWorktree ? "checkmark.square.fill" : "square", text: "New worktree", chevron: false)
        }
        .buttonStyle(.plain)
        .disabled(!takesNewWorktree)
        .opacity(takesNewWorktree ? 1 : 0.5)
    }

    private var agentChip: some View {
        Menu {
            if let choices = composer.choices {
                Picker("Account", selection: Binding(get: { composer.account }, set: { pickAccount($0) })) {
                    ForEach(choices.accounts.filter { $0.unavailable == nil }, id: \.name) { a in
                        Text("\(a.name) · \(a.harness)").tag(Optional(a.name))
                    }
                }
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
            }
        } label: {
            Chip(symbol: "person", text: composer.account ?? (composer.choicesProblem == nil ? "Account" : "No accounts"), detail: [composer.modelLabel ?? (composer.takesModel ? composer.defaultModelLabel : nil), composer.effortLabel].compactMap { $0 }.joined(separator: " · "))
        }
        .disabled(composer.choices == nil)
    }

    @ViewBuilder
    private var placeChip: some View {
        if let a = composer.chosenAccount, !a.places.isEmpty {
            Menu {
                Picker("Runs in", selection: Binding(get: { composer.place }, set: { composer.place = $0; lastPlace = $0 ?? "" })) {
                    ForEach(a.places, id: \.id) { p in
                        // Background with no service of its own is a terminal behind the Mac's windows.
                        Label(p.behind ? "\(p.label) (behind its windows)" : p.label, systemImage: placeSymbol(p.id)).tag(Optional(p.id))
                    }
                }
            } label: {
                Chip(symbol: placeSymbol(composer.place ?? ""), text: a.places.first { $0.id == composer.place }?.label ?? "Runs in")
            }
        }
    }

    private func placeSymbol(_ id: String) -> String {
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
