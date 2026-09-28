import SwiftUI

/// Starts a session on one of your Macs: which Mac, which of its worktrees, which account and
/// where it runs there, and the prompt. The Mac starts it as its own window would.
struct NewSessionView: View {
    /// The project the inbox is narrowed to: its worktrees come first.
    var project: String?
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var device: String?
    @State private var worktree: Worktree?
    @State private var choices: StartChoices?
    @State private var choicesProblem: String?
    @State private var account: String?
    @State private var place: String?
    @State private var model: String?
    @State private var prompt = ""
    @State private var starting = false
    @State private var problem: String?
    @FocusState private var writing: Bool

    private var mac: DeviceRow? { store.devices.first { $0.key == device } }
    private var chosenAccount: StartAccount? { choices?.accounts.first { $0.name == account } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mac", selection: $device) {
                        Text("Choose").tag(String?.none)
                        ForEach(store.devices, id: \.key) { d in
                            Text(d.name).tag(Optional(d.key))
                        }
                    }
                    if let device {
                        NavigationLink {
                            WorktreePicker(worktrees: store.worktrees(device), chosen: $worktree, first: project)
                        } label: {
                            LabeledContent("Worktree") {
                                Text(worktree.map { "\($0.project) · \($0.name)" } ?? "Choose")
                            }
                        }
                    }
                } footer: {
                    if let why = whyNot { Text(why) }
                }
                if let choices {
                    Section("Agent") {
                        Picker("Account", selection: $account) {
                            ForEach(choices.accounts.filter { $0.unavailable == nil }, id: \.name) { a in
                                Text(a.name).tag(Optional(a.name))
                            }
                        }
                        if let a = chosenAccount {
                            Picker("Runs in", selection: $place) {
                                ForEach(a.places, id: \.id) { p in
                                    Text(p.label).tag(Optional(p.id))
                                }
                            }
                            if a.harness == "Claude Code" && !choices.models.isEmpty {
                                Picker("Model", selection: $model) {
                                    Text(a.defaultModel.map { "Default (\($0))" } ?? "Default").tag(String?.none)
                                    ForEach(choices.models, id: \.id) { m in
                                        Text(m.label).tag(Optional(m.id))
                                    }
                                }
                            }
                        }
                    }
                } else if let choicesProblem {
                    Section { Text(choicesProblem).foregroundStyle(.secondary) }
                }
                Section("Prompt") {
                    TextField("What should it do?", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($writing)
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start") { Task { await start() } }
                            .disabled(!ready)
                    }
                }
            }
            .onAppear {
                // The Mac to start on: the one that takes remote control, when there's one.
                if device == nil {
                    device = (store.devices.first { $0.online && $0.remoteControl } ?? store.devices.first)?.key
                }
            }
            .task(id: device) { await loadChoices() }
        }
    }

    /// Why nothing can start on the Mac chosen, when nothing can.
    private var whyNot: String? {
        guard let mac else { return nil }
        if !mac.online { return "\(mac.name) isn't connected." }
        if !mac.remoteControl { return "Remote control is off on \(mac.name): turn it on there in Settings › Devices to start sessions from here." }
        return nil
    }

    private var ready: Bool {
        whyNot == nil && worktree != nil && account != nil && place != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadChoices() async {
        worktree = nil
        choices = nil
        choicesProblem = nil
        guard let device, mac?.online == true else { return }
        do {
            let got = try await store.startChoices(device)
            choices = got
            let first = got.accounts.first { $0.unavailable == nil && $0.preferred } ?? got.accounts.first { $0.unavailable == nil }
            account = first?.name
            place = first?.place
            model = nil
        } catch {
            choicesProblem = words(error)
        }
    }

    private func start() async {
        guard let device, let worktree, let account, let place else { return }
        starting = true
        problem = nil
        defer { starting = false }
        do {
            let started = try await store.startSession(device: device, worktree: worktree.id, account: account, place: place, prompt: prompt, model: model)
            dismiss()
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
}

/// A Mac's worktrees to start in, grouped by project, most recently active first, the project
/// the inbox is narrowed to before the others.
private struct WorktreePicker: View {
    let worktrees: [Worktree]
    @Binding var chosen: Worktree?
    let first: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [(String, [Worktree])] {
        let words = search.lowercased().split(separator: " ")
        let hits = worktrees.filter { w in
            let text = "\(w.project) \(w.repo) \(w.name) \(w.branch ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var order: [String] = []
        var groups: [String: [Worktree]] = [:]
        for w in hits {
            if groups[w.project] == nil { order.append(w.project) }
            groups[w.project, default: []].append(w)
        }
        if let first, let i = order.firstIndex(of: first) {
            order.insert(order.remove(at: i), at: 0)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(shown, id: \.0) { project, rows in
                Section(project) {
                    ForEach(rows, id: \.id) { w in
                        Button {
                            chosen = w
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(w.name).foregroundStyle(.primary)
                                    Text([w.repo, w.branch].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chosen?.id == w.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(.rect)
                        }
                        // A choice in a list, not a link: plain text, the whole row taps.
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Project, repo or branch")
        .navigationTitle("Worktree")
        .navigationBarTitleDisplayMode(.inline)
    }
}
