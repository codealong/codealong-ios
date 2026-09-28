import Foundation
import Observation
import UIKit

/// What the app shows, from the Rust core: the linked Macs and their sessions. The core calls
/// back when its snapshot changes; the store takes the new one on the main actor.
@MainActor @Observable
final class Store {
    private(set) var devices: [DeviceRow] = []
    private(set) var sessions: [SessionRow] = []
    private(set) var problem: String?
    private(set) var linking = false
    var linkError: String?
    /// A link code the app was opened with (a QR code the camera read), waiting for you to say yes.
    var offeredLink: String?
    /// A session just started here, to open as soon as its Mac lists it.
    var openWhenListed: String?
    /// Something to tell you once: what's next after a start that needs you at the Mac, say.
    var notice: String?

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
        if snap.devices != devices { devices = snap.devices }
        if snap.sessions != sessions { sessions = snap.sessions }
    }

    func start() {
        guard let core else { return }
        Task.detached {
            do {
                try core.start()
            } catch {
                await MainActor.run { self.problem = words(error) }
            }
            // A link code handed to the app when it's launched for a test links it at once.
            if let code = ProcessInfo.processInfo.environment["CODEALONG_LINK_CODE"], !code.isEmpty {
                await self.link(code)
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

    /// A link from outside the app: only a Mac's link code, which waits for you to say yes, since
    /// any page could open one.
    func open(_ url: URL) {
        guard url.scheme == "codealong", url.host() == "link" else { return }
        offeredLink = url.absoluteString
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

    func startSession(device: String, worktree: String, account: String, place: String, prompt: String, model: String?) async throws -> StartedSession {
        let core = try running()
        return try await Task.detached {
            try core.startSession(device: device, worktree: worktree, account: account, place: place, prompt: prompt, model: model)
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
