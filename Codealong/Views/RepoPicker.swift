import SwiftUI

/// Where a new session starts on a Mac, picked as its quick panel picks it: a repo (the core's
/// `start_repos`), which starts where new work goes in it, the list's project first and
/// Codealong's chats last. Words that name no repo list the worktrees they name, by name or
/// branch, a tap on one starting there. The worktree in the repo is the start capsule's menu's
/// (StartBar.swift), as most worktrees are kept for the one piece of work they were made for.
struct RepoPicker: View {
    let repos: [StartRepo]
    let worktrees: [Worktree]
    let chosen: Worktree?
    let first: String?
    /// New worktree is on, for an account that makes one: a repo picked starts in a new worktree
    /// of it, which its row says, as the Mac's does.
    let newWorktree: Bool
    let pickRepo: (StartRepo) -> Void
    let pickWorktree: (Worktree) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var words: [Substring] { search.lowercased().split(separator: " ") }

    private func has(_ text: String) -> Bool {
        let text = text.lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// The repos what's typed names, under their projects, the list's project first.
    private var shownRepos: [(String, [StartRepo])] {
        var order: [String] = []
        var groups: [String: [StartRepo]] = [:]
        for r in repos where has("\(r.project) \(r.repo)") {
            if groups[r.project] == nil { order.append(r.project) }
            groups[r.project, default: []].append(r)
        }
        if let first, let i = order.firstIndex(of: first) {
            order.insert(order.remove(at: i), at: 0)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// The worktrees what's typed names, where it names no repo: by name or branch, with its
    /// repo's and project's names, as the Mac's panel finds them.
    private var named: [Worktree] {
        guard !words.isEmpty, shownRepos.isEmpty else { return [] }
        return worktrees.filter { !$0.chat && has("\($0.name) \($0.branch ?? "") \($0.repo) \($0.project)") }
    }

    private var chats: [Worktree] { worktrees.filter { $0.chat && has("no project chat") } }

    var body: some View {
        List {
            ForEach(shownRepos, id: \.0) { project, rows in
                Section(project) {
                    ForEach(rows, id: \.repo) { r in
                        row(r.repo, newWorktree ? "New worktree" : r.startsIn.startsHere, on: chosen?.chat == false && chosen?.project == r.project && chosen?.repo == r.repo) { pickRepo(r) }
                    }
                }
            }
            if !named.isEmpty {
                Section("Worktrees") {
                    ForEach(named, id: \.id) { w in
                        row(w.main ? "\(w.name) (main)" : w.name, [w.repo, w.branch].compactMap { $0 }.joined(separator: " · "), on: chosen?.id == w.id) { pickWorktree(w) }
                    }
                }
            }
            if !chats.isEmpty {
                Section("No project") {
                    ForEach(chats, id: \.id) { w in
                        row("A chat of its own", "In a folder of its own, for a question that belongs to none of your projects", on: chosen?.id == w.id) { pickWorktree(w) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Repo, or a worktree by name")
        .navigationTitle("Repo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ detail: String, on: Bool, pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if on {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        // A choice in a list, not a link: plain text, the whole row taps.
        .buttonStyle(.plain)
    }
}

extension Worktree {
    /// Its name beside its repo, as the Mac's panel says it: the main checkout is `main`.
    var nameInRepo: String { main ? "main" : name }

    /// Where a session starts in its repo, under the repo's name: this worktree, and what it holds
    /// when it's a reusable one besides the main checkout.
    var startsHere: String {
        guard !main, let reuse else { return nameInRepo }
        return "\(nameInRepo), \(reuse.words.lowercased())"
    }

    /// What it holds and its branch, under its name in the worktree menu.
    var heldWords: String {
        [reuse?.words, branch == name ? nil : branch].compactMap { $0 }.joined(separator: " · ")
    }
}

extension WorktreeReuse {
    /// What a reusable worktree holds, as its mark on the Mac says it.
    var words: String {
        switch self {
        case .free: "Ready for new work"
        case .open: "Work under way"
        case .review: "In review"
        case .landed: "Landed"
        }
    }
}
