import Foundation
import Observation
import UIKit

/// What the app shows, from the Rust core: the linked Macs and their sessions. The core calls
/// back when its snapshot changes; the store takes the new one on the main actor.
@MainActor @Observable
final class Store {
    private(set) var devices: [DeviceRow] = []
    private(set) var sessions: [SessionRow] = []
    private(set) var projects: [String] = []
    private(set) var problem: String?
    /// Goes up with every change the core reports, rows or not: a reply being written comes this way.
    private(set) var tick = 0
    private(set) var linking = false
    var linkError: String?
    /// A link code the app was opened with (a QR code the camera read), waiting for you to say yes.
    var offeredLink: String?
    /// A session just started here, to open as soon as its Mac lists it.
    var openWhenListed: String?
    /// Something to tell you once: what's next after a start that needs you at the Mac, say.
    var notice: String?
    /// How the session you just moved on from went ("Sent to …"), for the next one to say.
    var outcome: String?
    /// Sessions you replied to or answered here, with the time of the status each had then: one is
    /// left out of what's next until it waits on you anew, since the Mac's feed takes a moment to
    /// show an answer.
    private var handled: [String: Int64] = [:]
    /// Sessions you went on from without replying, in the order you left them.
    private var passed: [String] = []
    /// The sessions you went on from to the one shown, the latest last: swiping back goes to them
    /// in turn. Back at the list it starts again.
    var trail: [String] = []
    /// What you've written to each session and not sent, by key: kept as you go from one to
    /// another, and where a message that didn't go comes back.
    var drafts: [String: String] = [:]
    /// Messages on their way to each session, by key, oldest first: shown in its conversation at
    /// once, as the Mac's windows show theirs (ahead.ts), until its record has them.
    private(set) var outgoing: [String: [Outgoing]] = [:]
    /// Why a session's last message didn't go, for its screen to say once.
    var sendProblems: [String: String] = [:]
    /// The session shown now, if one is: a message that fails elsewhere is said in an alert.
    var showing: String?
    /// Sessions whose messages are going now: one at a time each, so they arrive in order.
    @ObservationIgnored private var pumping: Set<String> = []

    @ObservationIgnored private var core: Core?

    init() {
        let dir = URL.applicationSupportDirectory.appending(path: "Codealong", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            core = try Core(dir: dir.path(percentEncoded: false), key: DeviceKey.loadOrCreate(fallback: dir), name: UIDevice.current.name, tablet: UIDevice.current.userInterfaceIdiom == .pad, listener: Relay { [weak self] in
                Task { @MainActor in self?.refresh() }
            })
        } catch {
            problem = words(error)
        }
        refresh()
    }

    func refresh() {
        guard let core else { return }
        let snap = core.snapshot()
        tick &+= 1
        if snap.devices != devices { devices = snap.devices }
        if snap.sessions != sessions { sessions = snap.sessions }
        if snap.projects != projects { projects = snap.projects }
    }

    func start() {
        guard let core else { return }
        Task.detached {
            do {
                try core.start()
            } catch {
                await MainActor.run { self.problem = words(error) }
            }
            // A link code handed to the app when it's launched for a test links it at once, and a
            // session's key opens it once its Mac lists it.
            if let code = ProcessInfo.processInfo.environment["CODEALONG_LINK_CODE"], !code.isEmpty {
                await self.link(code)
            }
            if let key = ProcessInfo.processInfo.environment["CODEALONG_OPEN"], !key.isEmpty {
                await MainActor.run { self.openWhenListed = key }
            }
        }
    }

    func stop() {
        guard let core else { return }
        Task.detached { core.stop() }
    }

    func link(_ code: String) async {
        guard let core else { return }
        linking = true
        linkError = nil
        do {
            _ = try await Task.detached { try core.link(code: code) }.value
        } catch {
            linkError = words(error)
        }
        linking = false
        refresh()
    }

    func unlink(_ device: DeviceRow) {
        guard let core else { return }
        try? core.unlink(device: device.key)
        refresh()
    }

    /// A link from outside the app: a Mac's link code (`codealong://link/<code>`), which waits for
    /// you to say yes, since any page could open one; or a session to show
    /// (`codealong://session/<key>`), for a notification or a widget to open.
    func open(_ url: URL) {
        guard url.scheme == "codealong" else { return }
        switch url.host() {
        case "link": offeredLink = url.absoluteString
        case "session": openWhenListed = String(url.path(percentEncoded: false).dropFirst())
        default: break
        }
    }

    /// What waits on you besides the session `key`, the next first: Needs you, then Your turn, in
    /// the inbox's order, the Mac's session panel's, so next is always the most urgent one left.
    /// Ones you went on from without replying come round again after the rest, and ones you've
    /// dealt with stay out until they wait on you anew. `project` narrows it as the inbox is.
    func queue(after key: String, project: String) -> [SessionRow] {
        let waiting = sessions.filter { row in
            guard row.key != key, row.section == .needsYou || row.section == .yourTurn, project.isEmpty || row.project == project else { return false }
            guard let at = handled[row.key] else { return true }
            return (row.statusSince ?? row.lastActivity) > at
        }
        return waiting.filter { !passed.contains($0.key) } + passed.compactMap { key in waiting.first { $0.key == key } }
    }

    /// You replied to or answered `key`.
    func dealtWith(_ key: String) {
        guard let row = sessions.first(where: { $0.key == key }) else { return }
        handled[key] = row.statusSince ?? row.lastActivity
        passed.removeAll { $0 == key }
    }

    /// You went on from `key` without replying: it comes round again after the rest.
    func passedOver(_ key: String) {
        passed.removeAll { $0 == key }
        passed.append(key)
    }

    func conversation(_ key: String) -> Conversation? {
        try? core?.conversation(key: key)
    }

    /// Reads a session's conversation ahead of its being opened, in the background: the next
    /// that waits on you shows at once when you go on to it.
    func prefetch(_ key: String) {
        guard let core else { return }
        Task.detached(priority: .utility) { core.prefetch(key: key) }
    }

    func markSeen(_ key: String) {
        guard let core else { return }
        Task.detached { core.markSeen(keys: [key]) }
    }

    /// The session you went on from to `key`, the latest that's still listed: where swiping back
    /// goes.
    func previous(of key: String) -> SessionRow? {
        for k in trail.reversed() where k != key {
            if let row = sessions.first(where: { $0.key == k }) { return row }
        }
        return nil
    }

    /// Back to the session you went on from: it and what was gone on to from it come off the trail.
    func back(to key: String) {
        if let i = trail.lastIndex(of: key) { trail.removeSubrange(i...) }
    }

    /// Marks a session unread on its Mac: Your turn again, everywhere, until it's seen or prompted.
    func markUnread(_ key: String) async throws {
        let core = try running()
        try await Task.detached { try core.markUnread(keys: [key]) }.value
    }

    func archive(_ key: String) {
        guard let core else { return }
        Task.detached { try? core.archive(key: key, archived: true) }
    }

    /// A Mac's worktrees, from its feed.
    func worktrees(_ device: String) -> [Worktree] {
        core?.worktrees(device: device) ?? []
    }

    func startChoices(_ device: String) async throws -> StartChoices {
        let core = try running()
        return try await Task.detached { try core.startChoices(device: device) }.value
    }

    /// Where new work starts on `device` in `project` unless you pick a worktree (the core's rule).
    func startWorktree(_ device: String, project: String) -> Worktree? {
        _ = tick
        return core?.startWorktree(device: device, project: project)
    }

    func startSession(device: String, worktree: String, account: String, place: String, prompt: String, model: String?, effort: String?, newWorktree: Bool) async throws -> StartedSession {
        let core = try running()
        return try await Task.detached {
            try core.startSession(device: device, worktree: worktree, account: account, place: place, prompt: prompt, model: model, effort: effort, newWorktree: newWorktree)
        }.value
    }

    /// Forks a session into a copy that goes on without a window on its Mac, on `prompt` when
    /// there's one.
    func fork(_ key: String, prompt: String) async throws -> StartedSession {
        let core = try running()
        return try await Task.detached { try core.fork(key: key, prompt: prompt) }.value
    }

    /// Done with a session (Mark as done), with `stop` ending work under way too.
    func done(_ key: String, stop: Bool) async throws -> DoneOutcome {
        let core = try running()
        return try await Task.detached { try core.done(key: key, stop: stop) }.value
    }

    /// Names a session on its Mac, where its harness keeps its name.
    func rename(_ key: String, to name: String) async throws {
        let core = try running()
        try await Task.detached { try core.rename(key: key, name: name) }.value
    }

    /// What a session's reply box says before you write (the core's words).
    func replyPlaceholder(_ key: String, way: Way?, resumePlace: String?, behind: Bool) -> String {
        _ = tick
        return core?.replyPlaceholder(key: key, way: way, resumePlace: resumePlace, behind: behind) ?? "Reply"
    }

    /// What the quick search lists (the core's rules). Reads `tick`, so a view that shows it
    /// updates with every change the Macs send.
    func quick(project: String, query: String, said: [SaidHit], ranked: [String]) -> QuickList {
        _ = tick
        return core?.quick(project: project, query: query, said: said, ranked: ranked) ?? QuickList(sections: [], nothingWaits: false, working: 0)
    }

    /// What was said in sessions, searched on every connected Mac.
    func searchSaid(_ query: String) async -> SaidFound {
        guard let core else { return SaidFound(hits: [], building: false) }
        return await Task.detached { core.searchSaid(query: query) }.value
    }

    /// Where typed text goes, as `device` suggests it.
    func route(device: String, project: String, text: String) async throws -> RouteAnswer {
        let core = try running()
        return try await Task.detached { try core.route(device: device, project: project, text: text) }.value
    }

    /// Sends a session a message, or goes on with one that isn't running on it (`how`), without
    /// waiting: it shows in the conversation at once, going after any still on their way to that
    /// session. One that doesn't go is back in the session's box with why, with any after it.
    func post(_ key: String, title: String, text: String, how: Outgoing.How) {
        outgoing[key, default: []].append(Outgoing(id: UUID().uuidString, text: text, at: .now, how: how, state: .queued))
        sendProblems[key] = nil
        pump(key, title: title)
    }

    private func pump(_ key: String, title: String) {
        guard let core, !pumping.contains(key), let i = outgoing[key]?.firstIndex(where: { $0.state == .queued }), let next = outgoing[key]?[i] else { return }
        pumping.insert(key)
        outgoing[key]?[i].state = .sending
        Task {
            do {
                let message = try await Task.detached {
                    let conv = try core.conversation(key: key)
                    switch next.how {
                    case .send(let now): return try conv.send(text: next.text, now: now)
                    case .resume(let place, let model, let effort): return try conv.resume(place: place, model: model, effort: effort, prompt: next.text)
                    }
                }.value
                if let j = outgoing[key]?.firstIndex(where: { $0.id == next.id }) {
                    outgoing[key]?[j].state = .sent(message, at: .now)
                }
            } catch {
                failed(key, title: title, from: next.id, why: words(error))
            }
            pumping.remove(key)
            pump(key, title: title)
        }
    }

    /// A message didn't go: it and those after it, which wait on it, go back in the box in order,
    /// before what's written there now.
    private func failed(_ key: String, title: String, from id: String, why: String) {
        guard let list = outgoing[key], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let back = list[i...].filter { if case .sent = $0.state { false } else { true } }
        outgoing[key] = list.filter { o in !back.contains { $0.id == o.id } }
        let draft = drafts[key] ?? ""
        drafts[key] = (back.map(\.text) + (draft.isEmpty ? [] : [draft])).joined(separator: "\n\n")
        sendProblems[key] = why
        if showing != key {
            notice = "Your message to “\(title)” didn't go: \(why) It's back in its box."
        }
    }

    /// The session's conversation shows these now (`sends_in_record`): they go.
    func shown(_ key: String, items: [Item]) {
        guard let list = outgoing[key], !list.isEmpty else { return }
        let going = list.filter { $0.state != .queued }.map { SentAt(id: $0.id, at: Int64($0.at.timeIntervalSince1970 * 1000)) }
        let found = Set(sendsInRecord(sends: going, items: items))
        // A message goes after a while whatever the record says: its bubble has said what it knows.
        let kept = list.filter { !found.contains($0.id) && Date.now.timeIntervalSince($0.at) < Outgoing.longest }
        if kept != list { outgoing[key] = kept }
    }

    /// Puts a message that went away: the session didn't show it, and you've seen that.
    func dismissOutgoing(_ key: String, id: String) {
        outgoing[key]?.removeAll { $0.id == id }
    }

    private func running() throws -> Core {
        guard let core else { throw CoreError.Failed(message: problem ?? "Codealong's core didn't start.") }
        return core
    }
}

/// A message on its way to a session from here.
struct Outgoing: Identifiable, Equatable {
    let id: String
    let text: String
    let at: Date
    let how: How
    var state: State

    enum How: Equatable {
        /// A message, into the running turn at once with `now`.
        case send(now: Bool)
        /// Going on with a session that isn't running, where and on what you picked.
        case resume(place: String, model: String?, effort: String?)
    }

    enum State: Equatable {
        /// Waiting for one before it to go.
        case queued
        case sending
        /// Its Mac took it, and said this.
        case sent(String, at: Date)
    }

    /// One the session shows no sign of this long after it went says it may not have reached it.
    static let confirm: TimeInterval = 20
    /// One goes after this, whatever the record says.
    static let longest: TimeInterval = 10 * 60
}

/// Hands the core's change notices to the store; the core calls it on a thread of its own.
private final class Relay: Listener {
    private let onChange: @Sendable () -> Void

    init(_ onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func changed() {
        onChange()
    }
}
