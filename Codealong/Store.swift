import Foundation
import Observation
import UIKit

/// What the app shows, from the Rust core: the linked Macs and their sessions. The core calls
/// back when its snapshot changes; the store takes the new one on the main actor.
@MainActor @Observable
final class Store {
    private(set) var devices: [DeviceRow] = []
    private(set) var sessions: [SessionRow] = []
    /// Every PR the Macs list, once each.
    private(set) var prs: [PrRow] = []
    /// The PRs waiting on your review, in every project, in the order what waits on you goes
    /// through them (`reviewsWaiting`): read once as the PRs change, not each time the queue is.
    private var reviews: [PrRow] = []
    /// What was last read of each PR's page, by its key: a page opens with it, and one a swipe
    /// slides in is drawn from it.
    private(set) var prDetails: [String: PrDetail] = [:]
    @ObservationIgnored private var prReadAt: [String: Date] = [:]
    /// How many reads of each PR's page have been asked for: the latest is the one kept.
    @ObservationIgnored private var prReads: [String: Int] = [:]
    private(set) var projects: [String] = []
    /// The projects of the PRs page's PRs, for its pills.
    private(set) var prProjects: [String] = []
    /// The GitHub accounts the Macs are signed in as, and which of them the PRs page counts as yours.
    private(set) var github: [GithubAccount] = []
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
    /// How what a swipe did to the sessions it went on from went, once their Macs answered, oldest
    /// first: the session shown then says them all, in place of `outcome` (`doneLater`,
    /// `archiveLater`). Several can come in during one slide, and none is lost.
    var lateOutcomes: [String] = []
    /// Sessions you replied to or answered here, with the time of the status each had then: one is
    /// left out of what's next until it waits on you anew, since the Mac's feed takes a moment to
    /// show an answer.
    private var handled: [String: Int64] = [:]
    /// Sessions you went on from without replying, in the order you left them.
    private var passed: [String] = []
    /// The sessions and PRs you went on from to the one shown, by their keys in the list's path,
    /// the latest last: swiping back goes to them in turn. Back at the list it starts again.
    var trail: [String] = []
    /// What you've written to each session and not sent, by key: kept as you go from one to
    /// another, and where a message that didn't go comes back. A PR's review is here too, under
    /// its key after `PrView.prefix`.
    var drafts: [String: String] = [:]
    /// The images attached to each session's reply and not sent, by key, kept as its draft is.
    var attached: [String: [AttachedImage]] = [:]
    /// The images Macs keep for prompts, as read from them.
    @ObservationIgnored let images = ImageCache()
    /// Messages on their way to each session, by key, oldest first: shown in its conversation at
    /// once, as the Mac's windows show theirs (ahead.ts), until its record has them.
    private(set) var outgoing: [String: [Outgoing]] = [:]
    /// The session a swipe just slid in, and what the swipe showed of it: its screen opens with
    /// that, so nothing changes as it takes the swipe's place. A PR's page opens with what was
    /// last read of it (`prDetails`).
    @ObservationIgnored var slidIn: (key: String, opening: Opening)?
    /// What each Mac can start, by device, as it last said: a session's screen has its account's
    /// models and places from its first frame.
    private(set) var choices: [String: StartChoices] = [:]
    /// Why a session's last message didn't go, for its screen to say once.
    var sendProblems: [String: String] = [:]
    /// The session shown now, if one is, or a PR's page (its key after `PrView.prefix`): a message
    /// that fails elsewhere is said in an alert.
    var showing: String?
    /// Sessions whose messages are going now: one at a time each, so they arrive in order.
    @ObservationIgnored private var pumping: Set<String> = []

    @ObservationIgnored private var core: Core?
    /// The last start or stop of the core asked for: each runs once the one before it is done.
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    /// The stop waiting for the app to stay in the background (`leave`).
    @ObservationIgnored private var leaving: Task<Void, Never>?
    /// The time iOS gave the app to stay connected in the background, until it's handed back.
    @ObservationIgnored private var backgroundTime = UIBackgroundTaskIdentifier.invalid
    /// How long it stays connected in the background: within the half minute or so iOS gives.
    private static let stayConnected: Duration = .seconds(20)
    /// The app is open in front: sounds play only then, not while it stays connected behind
    /// another app.
    @ObservationIgnored private var inFront = false
    /// Launched for a check that goes through your real sessions (`LOOK_ONLY=1 scripts/run.sh`):
    /// nothing opened here is marked seen on its Mac, so the check leaves them as they were.
    private let lookOnly = ProcessInfo.processInfo.environment["CODEALONG_LOOK_ONLY"] == "1"
    /// The sessions a check goes through, in order, in place of what waits on you
    /// (`QUEUE=<key>,<key> scripts/run.sh`): any sessions, waiting or not.
    private let testQueue = ProcessInfo.processInfo.environment["CODEALONG_QUEUE"].flatMap { $0.isEmpty ? nil : $0.split(separator: ",").map(String.init) }

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
        if snap.prs != prs {
            prs = snap.prs
            reviews = reviewsWaiting()
        }
        if snap.projects != projects { projects = snap.projects }
        if snap.prProjects != prProjects { prProjects = snap.prProjects }
        if snap.github != github { github = snap.github }
        // Asked at every change, so what came meanwhile isn't news later; behind another app with
        // none on, so a sound that wouldn't play doesn't hold back the next one.
        if let sound = core.sound(on: inFront ? Sounds.on : []) { Sounds.play(sound) }
    }

    func start() {
        guard let core else { return }
        inFront = true
        // Back before the stop it was waiting to make: it's still connected.
        leaving?.cancel()
        leaving = nil
        endBackgroundTime()
        let started = inTurn { () -> String? in
            do {
                try core.start()
                return nil
            } catch {
                return words(error)
            }
        }
        Task {
            if let why = await started.value { problem = why }
            // A link code handed to the app when it's launched for a test links it at once, and a
            // session's key opens it once its Mac lists it.
            if let code = ProcessInfo.processInfo.environment["CODEALONG_LINK_CODE"], !code.isEmpty {
                await link(code)
            }
            if let key = ProcessInfo.processInfo.environment["CODEALONG_OPEN"], !key.isEmpty {
                openWhenListed = key
            }
            // Improve Codealong pressed for a test (`IMPROVE=1 scripts/run.sh`), once the Macs have
            // answered and a session OPEN asked for is up, so the picture is of that screen.
            if ProcessInfo.processInfo.environment["CODEALONG_IMPROVE"] == "1" {
                try? await Task.sleep(for: .seconds(8))
                improveCodealong()
            }
        }
    }

    /// The app went to the background: it stays connected for a while, so back from another app
    /// it shows what's new at once, then stops. iOS gives it that time, and when it wants the
    /// time back sooner, it stops then.
    func leave() {
        inFront = false
        guard core != nil, leaving == nil else { return }
        if backgroundTime == .invalid {
            backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Stay connected") { [weak self] in
                self?.stop(timeIsUp: true)
            }
        }
        leaving = Task { [weak self] in
            try? await Task.sleep(for: Store.stayConnected)
            guard !Task.isCancelled else { return }
            self?.stop(timeIsUp: false)
        }
    }

    /// Disconnects and saves the last feeds. With `timeIsUp`, iOS wants its time back at once, so
    /// it's handed back without waiting for the stop, which ends when the app next runs.
    private func stop(timeIsUp: Bool) {
        guard let core else { return }
        leaving?.cancel()
        leaving = nil
        let stopped = inTurn { core.stop() }
        let time = backgroundTime
        backgroundTime = .invalid
        guard time != .invalid else { return }
        if timeIsUp {
            UIApplication.shared.endBackgroundTask(time)
        } else {
            Task {
                await stopped.value
                UIApplication.shared.endBackgroundTask(time)
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    /// Runs a start or a stop of the core off the main actor once the one before it is done: a
    /// stop still closing when the app comes back would close what the start opened.
    private func inTurn<T: Sendable>(_ work: @escaping @Sendable () -> T) -> Task<T, Never> {
        let before = lifecycle
        let task = Task.detached {
            await before?.value
            return work()
        }
        lifecycle = Task { _ = await task.value }
        return task
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

    /// What waits on you besides `key` (a page's key in the list's path: a session's, or a PR's
    /// after `PrView.prefix`), the next first, in the order the Mac's windows go through it
    /// (queue.ts `WAITS`): sessions that need you, then PRs waiting on your review, then Your turn,
    /// so next is always the most urgent one left. Sessions are in the inbox's order and PRs the
    /// longest wait first, as the PRs page lists them. Ones you went on from without dealing with
    /// them come round again after the rest, and ones you've dealt with stay out until they wait
    /// on you anew. `project` narrows it as the inbox is.
    func queue(after key: String, project: String) -> [Waiting] {
        if let fixed = testQueue {
            // Those after it in the list, as a real queue has gone past the ones before.
            let rest = fixed.firstIndex(of: key).map { fixed[($0 + 1)...] } ?? fixed[...]
            return rest.compactMap { waiting($0) }
        }
        let fresh = { (k: String, since: Int64) in self.handled[k].map { since > $0 } ?? true }
        // A helper or a headless run that doesn't need you isn't waiting on you, as it's out of
        // the lists: a pin keeps one listed (in Pinned), and a Mac from before the helpers' rule
        // calls its turns Your turn.
        let rows = sessions.filter { row in
            guard row.key != key, !row.unattended, row.section == .needsYou || row.section == .yourTurn, project.isEmpty || row.project == project else { return false }
            return fresh(row.key, row.statusSince ?? row.lastActivity)
        }
        // A review asked for again (a new `requestedAt`) waits on you anew.
        let asked = reviews.filter { pr in
            let k = PrView.prefix + pr.key
            return k != key && (project.isEmpty || pr.project == project) && fresh(k, pr.requestedAt ?? pr.updatedAt)
        }
        let all = rows.filter { $0.section == .needsYou }.map(Waiting.session) + asked.map(Waiting.pr) + rows.filter { $0.section == .yourTurn }.map(Waiting.session)
        return all.filter { !passed.contains($0.key) } + passed.compactMap { key in all.first { $0.key == key } }
    }

    /// The PRs waiting on your review, pinned or not, the longest wait first, as the Mac's queue
    /// takes them (the core's rules). Only ones its Mac can read can be opened here.
    private func reviewsWaiting() -> [PrRow] {
        (core?.reviewQueue() ?? []).filter { !$0.slug.isEmpty }
    }

    /// What waits on you by its key in the list's path, while it's listed.
    func waiting(_ key: String) -> Waiting? {
        if key.hasPrefix(PrView.prefix) { return pr(String(key.dropFirst(PrView.prefix.count))).map(Waiting.pr) }
        return sessions.first { $0.key == key }.map(Waiting.session)
    }

    /// You replied to or answered `key`, a session; or reviewed it, a PR (its key after
    /// `PrView.prefix`), which GitHub takes as the review asked of you.
    func dealtWith(_ key: String) {
        switch waiting(key) {
        case .session(let row): handled[key] = row.statusSince ?? row.lastActivity
        case .pr(let pr): handled[key] = pr.requestedAt ?? pr.updatedAt
        case nil: return
        }
        passed.removeAll { $0 == key }
    }

    /// You went on from `key` without replying: while it still needs you, it comes round again
    /// after the rest (a finished turn, or a reply that asks you something, was marked seen, and
    /// leaves).
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

    /// What the phone keeps of a session's conversation, for a swipe to slide in; with `read`, read
    /// from its Mac first when it hasn't been lately. With it, what its screen shows over the reply
    /// box: what it waits on you for, and how a message gets there.
    func kept(_ key: String, read: Bool) async -> Kept? {
        guard let core, let conv = conversation(key) else { return nil }
        let waits = sessions.first { $0.key == key }?.status == .needs
        return await Task.detached(priority: .utility) {
            if read { core.prefetch(key: key) }
            let pending = waits ? try? conv.pending() : nil
            return Kept(items: conv.kept(), hasOlder: conv.hasOlder(), pending: pending, way: conv.way())
        }.value
    }

    /// Why a reply or an answer can't go to a session from here, or nil when it can: only a
    /// connected Mac with remote control on takes one.
    func cannotReach(_ row: SessionRow?) -> String? {
        guard let row, let device = devices.first(where: { $0.key == row.device }) else { return "That session isn't on a linked Mac any more" }
        if !device.online { return "\(device.name) isn't connected" }
        if !device.remoteControl { return "Remote control is off on \(device.name)" }
        return nil
    }

    func markSeen(_ key: String) {
        guard let core, !lookOnly else { return }
        Task.detached { core.markSeen(keys: [key]) }
    }

    /// Improve Codealong: a session that improves Codealong itself, as the Mac's button beside
    /// New session starts one, from the lightbulb on any screen (ImproveButton). Pressing it takes
    /// a picture of that screen and sets this; the list (QuickView) takes it up: goes onto
    /// Codealong's own project and worktree on the Mac the core picks, shows the picture under
    /// its input, asks what to change, and clears this when the session starts or you cancel.
    var improving: Improving?

    struct Improving: Identifiable {
        let id = UUID()
        let target: ImproveTarget
        /// The picture of the screen, shown under the input until it's taken off.
        var thumb: UIImage?
        /// How the prompt refers to it once its Mac has it; nil while it's on its way or taken off.
        var shot: ImproveShot?
        var keeping = false
        var problem: String?
    }

    /// Where a session that improves Codealong itself starts: this app's own source on one of the
    /// Macs, else the Mac app's, a connected Mac first (the core's rule). Nil when no Mac has one.
    func improveTarget() -> ImproveTarget? {
        _ = tick
        return core?.improveTarget()
    }

    /// The lightbulb pressed: a picture of the screen as it is, first, before anything changes,
    /// then on its way to the target's Mac for the prompt. With no Mac marking Codealong's source
    /// (none has it, or they run a Codealong from before the mark), it says so and changes nothing.
    func improveCodealong() {
        guard let target = improveTarget() else {
            notice = "No Mac lists the source of Codealong for iPhone. Clone github.com/codealong/codealong-ios into a folder Codealong searches on a Mac, in a project there."
            return
        }
        let picture = Store.screenshot()
        let begun = Improving(target: target, thumb: picture?.image, shot: nil, keeping: picture != nil)
        improving = begun
        guard let picture else { return }
        Task {
            do {
                let reference = try await keepScreenshot(picture.data, on: target.device)
                // Taken off meanwhile, or pressed again, or cancelled: the picture stays out.
                guard improving?.id == begun.id, improving?.thumb != nil else { return }
                improving?.shot = ImproveShot(name: "iPhone screen", reference: reference)
                improving?.keeping = false
            } catch {
                guard improving?.id == begun.id else { return }
                improving?.thumb = nil
                improving?.keeping = false
                improving?.problem = "The picture couldn’t be kept on the Mac: \(words(error))"
            }
        }
    }

    /// Keeps a picture of this phone's screen on `device` for the prompt of a session that
    /// improves Codealong, answering how the prompt refers to it.
    private func keepScreenshot(_ data: Data, on device: String) async throws -> String {
        let core = try running()
        guard let prepared = ImagePrep.jpeg(data) else { throw CoreError.Failed(message: "The screen couldn't be pictured.") }
        let bytes = prepared.data
        return try await Task.detached { try core.keepImage(device: device, name: "iphone-screen.jpg", bytes: bytes) }.value
    }

    /// The screen as it's drawn now, as PNG bytes and an image, or nil with no window to draw.
    private static func screenshot() -> (data: Data, image: UIImage)? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData() else { return nil }
        return (data, image)
    }

    /// The session or PR you went on from to `key`, the latest that's still listed: where swiping
    /// back goes.
    func previous(of key: String) -> Waiting? {
        for k in trail.reversed() where k != key {
            if let w = waiting(k) { return w }
        }
        return nil
    }

    /// Back to the session you went on from: it and what was gone on to from it come off the trail.
    func back(to key: String) {
        if let i = trail.lastIndex(of: key) { trail.removeSubrange(i...) }
    }

    /// A PR by its key (`owner/name#number`).
    func pr(_ key: String) -> PrRow? {
        prs.first { $0.key == key }
    }

    /// A PR's description, reviews, comments, changed files and your draft review of it, as its
    /// Mac's `gh` reads them; kept, so its page opens with it at once next time (`prDetails`).
    /// Reads of one PR can overlap (one ahead, its page's, one after a review): only the latest
    /// asked for is kept, so an older answer coming in last doesn't put back what it said.
    func prDetail(_ pr: PrRow) async throws -> PrDetail {
        let core = try running()
        let asked = (prReads[pr.key] ?? 0) + 1
        prReads[pr.key] = asked
        let read = try await Task.detached { try core.prDetail(device: pr.device, repo: pr.slug, number: pr.number) }.value
        if prReads[pr.key] == asked {
            prDetails[pr.key] = read
            prReadAt[pr.key] = .now
        }
        return read
    }

    /// Reads a PR's page ahead of its being opened, unless it was read lately: the next that waits
    /// on you slides in as it is. Its page reads it again as it opens.
    func readAhead(_ pr: PrRow) async {
        if let at = prReadAt[pr.key], Date.now.timeIntervalSince(at) < 30 { return }
        _ = try? await prDetail(pr)
    }

    /// Snoozes your review of a PR a swipe went on from, without holding up the swipe: one its Mac
    /// didn't snooze comes round again, saying why.
    func snoozeLater(_ pr: PrRow, until: Date) {
        Task {
            do {
                try await prSnooze(pr, until: until)
            } catch {
                comeRound(PrView.prefix + pr.key)
                tellLater("Your review of #\(pr.number) wasn’t snoozed: \(words(error))", asked: false)
            }
        }
    }

    /// What a PR's merge box offers you, as its Mac's `gh` reads it.
    func prMergeBox(_ pr: PrRow) async throws -> MergeBox {
        let core = try running()
        return try await Task.detached { try core.prMergeBox(device: pr.device, repo: pr.slug, number: pr.number) }.value
    }

    /// Reviews a PR as you on GitHub, through its Mac. `draft` is the stamp of the draft review
    /// shown with it: the Mac refuses to submit another, or one changed since.
    func prReview(_ pr: PrRow, verdict: PrVerdict, body: String, draft: String?) async throws -> UInt64? {
        let core = try running()
        return try await Task.detached { try core.prReview(device: pr.device, repo: pr.slug, number: pr.number, verdict: verdict, body: body, draft: draft) }.value
    }

    /// Does one thing a PR's merge box does, as you on GitHub, through its Mac.
    func prMerge(_ pr: PrRow, id: String, act: MergeAct) async throws -> MergeDone {
        let core = try running()
        return try await Task.detached { try core.prMerge(device: pr.device, repo: pr.slug, number: pr.number, id: id, act: act) }.value
    }

    /// Snoozes your review of a PR until `until`, or wakes it with none, on its Mac.
    func prSnooze(_ pr: PrRow, until: Date?) async throws {
        let core = try running()
        let ms = until.map { Int64($0.timeIntervalSince1970 * 1000) }
        try await Task.detached { try core.prSnooze(device: pr.device, repo: pr.slug, number: pr.number, until: ms) }.value
    }

    /// Snoozes a session until `until`, or wakes it with none, on its Mac: off Needs you and Your
    /// turn everywhere until then.
    func snooze(_ key: String, until: Date?) async throws {
        let core = try running()
        let ms = until.map { Int64($0.timeIntervalSince1970 * 1000) }
        try await Task.detached { try core.snooze(keys: [key], until: ms) }.value
    }

    /// Quiets a session, or makes it heard again, on its Mac: a quiet one's turns don't wait on
    /// you, and it comes to you only when it needs you.
    func quiet(_ key: String, _ on: Bool) async throws {
        let core = try running()
        try await Task.detached { try core.quiet(keys: [key], quiet: on) }.value
    }

    /// Pins a session at the top of its Mac's pins, or unpins it.
    func pin(_ key: String, _ on: Bool) async throws {
        let core = try running()
        try await Task.detached { try core.pin(keys: [key], pinned: on) }.value
    }

    /// Takes away the replies suggested for a session, on its Mac.
    func dismissSuggestions(_ key: String) async throws {
        let core = try running()
        try await Task.detached { try core.dismissSuggestions(key: key) }.value
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
        let read = try await Task.detached { try core.startChoices(device: device) }.value
        choices[device] = read
        return read
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

    /// Marks a session done that a swipe went on from, without holding up the swipe. Once its Mac
    /// answers, the session shown then says how it went (`tellLater`). Work under way holds it, as
    /// it holds Mark as done, and one held or not reached comes round again.
    func doneLater(_ key: String, title: String) {
        Task {
            do {
                let outcome = try await done(key, stop: false)
                if !outcome.done { comeRound(key) }
                tellLater(outcome.done ? outcome.message : "\(outcome.message) It wasn’t marked done.", asked: outcome.done && !outcome.noted)
            } catch {
                comeRound(key)
                tellLater("“\(title)” wasn’t marked done: \(words(error))", asked: false)
            }
        }
    }

    /// Archives a session a swipe went on from, without holding up the swipe: one its Mac didn't
    /// archive comes round again, saying why.
    func archiveLater(_ key: String, title: String) {
        guard let core else { return }
        Task {
            do {
                try await Task.detached { try core.archive(key: key, archived: true) }.value
            } catch {
                comeRound(key)
                tellLater("“\(title)” wasn’t archived: \(words(error))", asked: false)
            }
        }
    }

    /// Snoozes a session a swipe went on from, without holding up the swipe, as its Snooze does:
    /// off Needs you and Your turn everywhere until `until`. Not one with a message on its way,
    /// whose prompt would end the snooze as it lands (`Going.of`). It goes after the rest until its Mac
    /// has it snoozed, and isn't kept as dealt with, so it's back when the snooze ends, as the
    /// Mac's queue has it; one its Mac didn't snooze comes round again, saying why.
    func snoozeLater(_ key: String, title: String, until: Date) {
        handled[key] = nil
        passedOver(key)
        Task {
            do {
                try await snooze(key, until: until)
            } catch {
                comeRound(key)
                tellLater("“\(title)” wasn’t snoozed: \(words(error))", asked: false)
            }
        }
    }

    /// Says how what a swipe did went: on the session shown then, or with none shown (you went back
    /// to the list meanwhile), in an alert when it didn't go as asked.
    private func tellLater(_ said: String, asked: Bool) {
        if showing != nil {
            lateOutcomes.append(said)
        } else if !asked {
            notice = [notice, said].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    /// A session a swipe went on from was to leave what waits on you and didn't: it comes round
    /// again after the rest, as one gone on from without a reply does.
    private func comeRound(_ key: String) {
        handled[key] = nil
        passedOver(key)
    }

    /// Names a session on its Mac, where its harness keeps its name.
    func rename(_ key: String, to name: String) async throws {
        let core = try running()
        try await Task.detached { try core.rename(key: key, name: name) }.value
    }

    /// What a session's reply box says before you write, in full and folded to a line (the core's
    /// words).
    func replyPlaceholder(_ key: String, way: Way?, resumePlace: String?, behind: Bool) -> ReplyPlaceholder {
        _ = tick
        return core?.replyPlaceholder(key: key, way: way, resumePlace: resumePlace, behind: behind) ?? ReplyPlaceholder(short: "Reply", full: "Reply")
    }

    /// What the quick search lists (the core's rules). Reads `tick`, so a view that shows it
    /// updates with every change the Macs send.
    func quick(project: String, query: String, said: [SaidHit], ranked: [String]) -> QuickList {
        _ = tick
        return core?.quick(project: project, query: query, said: said, ranked: ranked) ?? QuickList(sections: [], nothingWaits: false, working: 0)
    }

    /// Counts the PRs `login` opened as yours, or not, from now on. One account stays yours.
    func setYours(_ login: String, _ yours: Bool) {
        let picked = github.filter { $0.yours && $0.login != login }.map(\.login) + (yours ? [login] : [])
        guard !picked.isEmpty else { return }
        core?.setGithubYours(picked: picked)
        refresh()
    }

    /// The PRs page's groups (the core's rules). Reads `tick`, as `quick` does.
    func prList(project: String) -> [PrSection] {
        _ = tick
        return core?.prList(project: project) ?? []
    }

    /// The list's sessions by project and worktree. Reads `tick`.
    func byProject(project: String) -> [ProjectGroup] {
        _ = tick
        return core?.byProject(project: project) ?? []
    }

    /// The list's pinned sessions, in their Macs' order, which lead By project and Recent. Reads
    /// `tick`.
    func pinned(project: String) -> [SessionRow] {
        _ = tick
        return core?.pinned(project: project) ?? []
    }

    /// The list's sessions, the last active first. Reads `tick`.
    func recent(project: String) -> [SessionRow] {
        _ = tick
        return core?.recent(project: project) ?? []
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

    /// Attaches an image to a session's reply: in it at once, so the reply waits for it, and kept
    /// on its Mac, so it's ready when you send. `failed` says why it couldn't be, when it couldn't,
    /// and it's taken off.
    func attach(_ data: Data, to key: String, mac: String, failed: @escaping (String) -> Void) {
        guard let prepared = ImagePrep.jpeg(data) else { return failed("That isn't an image.") }
        let image = AttachedImage(thumb: ImagePrep.thumb(prepared.image), state: .keeping)
        attached[key, default: []].append(image)
        let bytes = prepared.data
        Task {
            do {
                let reference = try await keep(bytes, on: mac)
                if let at = attached[key]?.firstIndex(where: { $0.id == image.id }) {
                    attached[key]?[at].state = .kept(reference: reference)
                }
            } catch {
                detach(image.id, from: key)
                failed(words(error))
            }
        }
    }

    func detach(_ id: UUID, from key: String) {
        attached[key]?.removeAll { $0.id == id }
        if attached[key]?.isEmpty == true { attached[key] = nil }
    }

    /// Keeps the images held for a new session's prompt on the Mac it starts on, answering how
    /// the prompt refers to each, in order.
    func keep(_ held: [AttachedImage], on mac: String) async throws -> [String] {
        var references: [String] = []
        for image in held {
            guard case .held(let jpeg) = image.state else { continue }
            references.append(try await keep(jpeg, on: mac))
        }
        return references
    }

    /// Keeps a JPEG on `mac` for a prompt, answering how the prompt refers to it.
    private func keep(_ jpeg: Data, on mac: String) async throws -> String {
        let core = try running()
        let reference = try await Task.detached { try core.keepImage(device: mac, name: "image.jpg", bytes: jpeg) }.value
        // Kept here too, so the prompt shows it at once.
        if let path = ImagePrep.path(of: reference) { images.put(jpeg, at: path) }
        return reference
    }

    /// An image a prompt on `mac` refers to, read from there once and kept.
    func image(mac: String, path: String) async -> UIImage? {
        guard let core = try? running() else { return nil }
        return await images.image(path) { try await Task.detached { try core.readImage(device: mac, path: path) }.value }
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

/// Something that waits on you, as a swipe goes along it: a session, or a PR waiting on your
/// review.
enum Waiting: Equatable {
    case session(SessionRow)
    case pr(PrRow)

    /// Its page's key in the list's path: a session's key, or a PR's after `PrView.prefix`.
    var key: String {
        switch self {
        case .session(let row): row.key
        case .pr(let pr): PrView.prefix + pr.key
        }
    }

    var title: String {
        switch self {
        case .session(let row): row.title
        case .pr(let pr): pr.title
        }
    }

    /// When it last changed: what's read of it ahead is read again then.
    var stamp: Int64 {
        switch self {
        case .session(let row): row.lastActivity
        case .pr(let pr): pr.updatedAt
        }
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
