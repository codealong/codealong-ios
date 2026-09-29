import SwiftUI

/// A Mac's worktrees to start in, grouped by project, most recently active first, the project
/// the inbox is narrowed to before the others.
struct WorktreePicker: View {
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
