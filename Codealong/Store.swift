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

    func markSeen(_ key: String) {
        guard let core else { return }
        Task.detached { core.markSeen(keys: [key]) }
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

    /// Sends a session a prompt where it runs; returns what its Mac said about it.
    func send(_ key: String, text: String) async throws -> String {
        let core = try running()
        return try await Task.detached {
            let conv = try core.conversation(key: key)
            return try conv.send(text: text, now: false)
        }.value
    }

    private func running() throws -> Core {
        guard let core else { throw CoreError.Failed(message: problem ?? "Codealong's core didn't start.") }
        return core
    }
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
