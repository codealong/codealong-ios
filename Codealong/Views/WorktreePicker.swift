import SwiftUI

/// A Mac's worktrees to start in, grouped by project, most recently active first, the project
/// the inbox is narrowed to before the others, and a chat in no project last. A reusable worktree
/// says what it holds.
struct WorktreePicker: View {
    let worktrees: [Worktree]
    @Binding var chosen: Worktree?
    let first: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [(String, [Worktree])] {
        let words = search.lowercased().split(separator: " ")
        let hits = worktrees.filter { w in
            let text = w.chat ? "no project chat" : "\(w.project) \(w.repo) \(w.name) \(w.branch ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var order: [String] = []
        var groups: [String: [Worktree]] = [:]
        for w in hits {
            let group = w.chat ? Self.chats : w.project
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(w)
        }
        if let first, let i = order.firstIndex(of: first) {
            order.insert(order.remove(at: i), at: 0)
        }
        if let i = order.firstIndex(of: Self.chats) {
            order.append(order.remove(at: i))
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
                                    if w.chat {
                                        Text("A chat of its own").foregroundStyle(.primary)
                                        Text("In a folder of its own, for a question that belongs to none of your projects")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(w.main ? "\(w.name) (main)" : w.name).foregroundStyle(.primary)
                                        Text(([w.repo, w.branch] + [reuseWord(w.reuse)]).compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
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

    /// The group a chat goes in.
    private static let chats = "No project"

    /// What a reusable worktree holds, as its mark on the Mac says it.
    private func reuseWord(_ reuse: WorktreeReuse?) -> String? {
        switch reuse {
        case .free: "Free"
        case .open: "Work under way"
        case .review: "In review"
        case .landed: "Landed"
        case nil: nil
        }
    }
}
