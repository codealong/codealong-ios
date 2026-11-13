import SwiftUI

/// Where a new session starts, as the start capsule's menu sets it: the Mac, the repo and the
/// worktree in it or a new one its harness makes, the account, model and effort, and where it
/// runs. The list keeps it, reading the Mac's choices on the navigation stack, so they're there
/// when you're back from a session.
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

    /// A repo picked: where new work starts in it (the core's `start_worktree_in`). New worktree,
    /// while it's on, is made from the repo's checkout for it as the session starts
    /// (`startWorktree`).
    @MainActor mutating func pick(_ r: StartRepo, store: Store) {
        guard let device else { return }
        worktreeID = (store.startWorktreeIn(device, project: r.project, repo: r.repo, newWorktree: false) ?? r.startsIn).id
    }

    /// A worktree picked, in its repo's menu or by its name: a session starts just there.
    mutating func pick(_ w: Worktree) {
        newWorktree = false
        worktreeID = w.id
    }

    /// Where the capsule's start goes: a new worktree is made from its repo's checkout for it,
    /// whichever of the repo's worktrees is picked, which is where it starts once New worktree is
    /// off or the account makes none (as the Mac's panel starts, its `startLane`).
    @MainActor func startWorktree(store: Store, project: String) -> Worktree? {
        guard let w = worktree(store: store, project: project) else { return nil }
        guard takesNewWorktree, newWorktree, !w.chat, let device else { return w }
        return store.startWorktreeIn(device, project: w.project, repo: w.repo, newWorktree: true) ?? w
    }

    /// Starting from the capsule does what `s` does: it starts in the same worktree, in a new one
    /// of its own or not as the capsule would, with the same account. The capsule is that start,
    /// so it isn't listed over it too.
    @MainActor func startsAs(_ s: Suggestion, store: Store, project: String) -> Bool {
        guard s.kind == .start, let w = s.worktree, let here = startWorktree(store: store, project: project), w.id == here.id, w.device == here.device else { return false }
        // As a start makes it: only an account that makes worktrees does, and never for a chat.
        let tree = takesNewWorktree && !w.chat
        return (tree && s.newWorktree) == (tree && newWorktree)
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
