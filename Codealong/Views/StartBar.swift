import SwiftUI

/// Where a new session starts, as the chips under the quick search set it: the Mac, the worktree,
/// whether its harness makes a worktree of its own, the account, model and effort, and where it
/// runs.
struct Composer {
    var device: String?
    /// The worktree picked by hand, by id on `device`; none goes by `worktree(store:project:)`'s default.
    var worktreeID: String?
    var newWorktree = false
    var choices: StartChoices?
    var choicesProblem: String?
    var account: String?
    var place: String?
    var model: String?
    var effort: String?

    var chosenAccount: StartAccount? { choices?.accounts.first { $0.name == account } }

    /// The account's command line makes a worktree of its own for a session when asked: the apps
    /// have their own choice on their new-session pages.
    var takesNewWorktree: Bool {
        chosenAccount?.worktree == true && (place == "terminal" || place == "background")
    }

    /// The place chosen takes a model and effort: the command line and Codealong do, the apps
    /// choose their own.
    var takesModel: Bool {
        place == "terminal" || place == "background" || place == "codealong"
    }

    /// Background is a terminal opened behind the Mac's windows, for a harness with no background
    /// service of its own.
    var behind: Bool {
        place == "background" && chosenAccount?.places.first { $0.id == "background" }?.behind == true
    }

    var modelLabel: String? {
        guard let model, takesModel else { return nil }
        return modelName(model: model, models: chosenAccount?.models ?? [])
    }

    /// The model it starts on unless you pick one, as people say it.
    var defaultModelLabel: String? {
        chosenAccount?.defaultModel.map { modelName(model: $0, models: chosenAccount?.models ?? []) }
    }

    var effortLabel: String? {
        guard let effort, takesModel else { return nil }
        return chosenAccount?.efforts.first { $0.id == effort }?.label ?? effort
    }

    /// The worktree to start in: the one picked, else where new work goes in the project the list
    /// shows, as the Mac's panel picks one (the core's `start_worktree`).
    @MainActor func worktree(store: Store, project: String) -> Worktree? {
        guard let device else { return nil }
        if let id = worktreeID, let w = store.worktrees(device).first(where: { $0.id == id }) { return w }
        return store.startWorktree(device, project: project)
    }

    /// What starting does, in a sentence, as the Mac's panel says it (start.ts `startDoes`).
    func happens(in w: Worktree, newWorktree tree: Bool) -> String {
        let on = [modelLabel, effortLabel.map { "\($0) effort" }].compactMap { $0 }.joined(separator: ", ")
        let who = (account ?? "a session") + (on.isEmpty ? "" : " on \(on)")
        // A chat goes in a folder of its own, in no project.
        let name = w.chat ? "a folder of its own" : w.main ? "\(w.name) (main)" : w.name
        let tree = tree && !w.chat
        switch place {
        case "codealong": return "Codealong runs \(who) in \(name). Its replies show here as they're written."
        case "claude-app": return "The Claude app opens a new session in \(name) with this prompt filled in, for someone at the Mac to send."
        case "codex-app": return "The Codex app starts a new thread in \(name) on this prompt."
        default:
            let how = place == "background" ? (behind ? " in a terminal behind the Mac's windows" : " in the background") : " in a terminal"
            return tree ? "\(chosenAccount?.harness ?? "Its harness") makes a new worktree of \(w.repo) and starts \(who) there\(how)." : "Starts \(who) in \(name)\(how)."
        }
    }
}

/// The bottom of the quick search: the row that starts a new session with what's typed, and the
/// chips that say where. It rides above the keyboard, as the Mac's panel keeps it under the list.
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
    /// The last account and place you started with, to start with again.
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
        .onAppear {
            // The Mac to start on: the last one, else one that takes remote control.
            if composer.device == nil {
                let online = store.devices.filter(\.online)
                composer.device = (online.first { $0.key == lastDevice } ?? online.first { $0.remoteControl } ?? store.devices.first)?.key
            }
        }
        .onChange(of: project) { _, _ in composer.worktreeID = nil }
        // Again once the Mac connects: at launch it's chosen before it is.
        .task(id: "\(composer.device ?? "")\(mac?.online == true)") { await loadChoices() }
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
        var out = composer.happens(in: w, newWorktree: composer.takesNewWorktree && composer.newWorktree)
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
            // The place you last chose, where this account can go there; else where the core says a start from the phone goes.
            composer.place = first?.places.first { $0.id == lastPlace }?.id ?? first?.place
            composer.model = nil
            composer.effort = nil
        } catch {
            composer.choicesProblem = words(error)
        }
    }
}

/// A choice under the quick search, as the Mac's panel's chips are.
private struct Chip: View {
    let symbol: String
    let text: String
    var detail: String?
    var chevron = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.footnote)
            Text(text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.background, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
    }
}
