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

    @ObservationIgnored private var core: Core?

    init() {
        let dir = URL.applicationSupportDirectory.appending(path: "Codealong", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            core = try Core(dir: dir.path(percentEncoded: false), key: DeviceKey.loadOrCreate(), name: UIDevice.current.name, listener: Relay { [weak self] in
                Task { @MainActor in self?.refresh() }
            })
        } catch {
            problem = "\(error)"
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
                await MainActor.run { self.problem = "\(error)" }
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
            linkError = "\(error)"
        }
        linking = false
        refresh()
    }

    func unlink(_ device: DeviceRow) {
        guard let core else { return }
        try? core.unlink(device: device.key)
        refresh()
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
