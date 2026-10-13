import SwiftUI

/// Where a new session starts, as New session's choices set it: the Mac, the worktree, whether its
/// harness makes a worktree of its own, the account, model and effort, and where it runs. The list
/// keeps it, so the screen opens with the Mac's choices already read.
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

/// A choice on New session, as the Mac's panel's chips are.
struct Chip: View {
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
