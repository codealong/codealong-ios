import SwiftUI

/// A PR, as the Mac's PR panel shows it: where it stands (its state, checks, whether it can merge,
/// how big it is), your draft review of it when you began one, its description, reviews, comments
/// and changed files with their diffs. Merge, beside its state, opens its merge box, and the box at
/// its foot reviews it, as the Mac's does. The phone has no GitHub of its own: its Mac's `gh` reads
/// all of it and does what you ask, as you, so reviewing and merging need remote control on that
/// Mac.
///
/// It goes along what waits on you as a session's screen does, PRs waiting on your review among
/// the sessions, in the Mac's order (`Store.queue`): a bar over the review box names what's next
/// and says what going on to it does to this PR, and a swipe across the page, or a tap on the bar,
/// goes on; a swipe the other way goes back to what you came from. Going on from one waiting on
/// your review skips it, so it comes round again after the rest, as the Mac's ⌘E does, or snoozes
/// your review of it, as the bar's menu picks for this PR (`ReviewSwipeOn`). One you reviewed here
/// goes on as it is.
struct PrView: View {
    /// What a PR's place in the list's path starts with, before its key.
    nonisolated static let prefix = "pr:"
    /// `owner/name#number`.
    let key: String
    /// Shows another page in this one's place.
    var go: (String) -> Void = { _ in }
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The inbox's project: what's next stays in it.
    @AppStorage("project") private var project = ""
    /// What going on to the next does to this PR, as picked over the box: for this PR only, so
    /// each starts at coming back to it later.
    @State private var reviewOn = ReviewSwipeOn.later
    @State private var detail: PrDetail?
    @State private var problem: String?
    @State private var loading = false
    /// Which read is the latest: an earlier one that answers after it is let go.
    @State private var reads = 0
    @State private var merging = false
    /// Pick a time… in its Snooze review menu, asking for the time.
    @State private var snoozing: SnoozePick?
    /// How the last thing done here went.
    @State private var said: String?
    /// You reviewed or merged it here: going on leaves it as it is.
    @State private var acted = false
    /// You're going through what waits on you here (`Store.goingThrough`), as you were once: with
    /// nothing else waiting, going on goes to the end of it, still after you've reviewed it here.
    @State private var goingThrough = false
    /// A swipe across the page, while it goes, and what's beside it.
    @State private var swipe = Swipe()

    /// Opens with what was last read of it, so one a swipe slid in shows as it was drawn.
    init(key: String, kept: PrDetail? = nil, go: @escaping (String) -> Void = { _ in }) {
        self.key = key
        self.go = go
        _detail = State(initialValue: kept)
    }

    private var pr: PrRow? { store.pr(key) }
    /// Its key in the list's path, which what waits on you goes by.
    private var page: String { Self.prefix + key }
    /// The session or PR you went on from to this one: swiping back goes there.
    private var before: Waiting? { store.previous(of: page) }
    /// What waits on you after this one, sessions and PRs; the first is next.
    private var after: [Waiting] { store.queue(after: page, project: project) }
    /// Where going on goes: the next, or on the last, the end of what waits.
    private var onward: Onward? { Onward.of(after, goingThrough: goingThrough) }
    /// What going on to the next does to this one, as the bar over the box says it.
    private var going: Going { Going.of(reviewOn, pr: pr, acted: acted) }
    /// Its Mac is connected.
    private var macOnline: Bool { store.devices.first { $0.key == pr?.device }?.online == true }
    /// Your review as you've written it and not sent.
    private var drafted: Bool { !(store.drafts[page] ?? "").isEmpty }

    /// Why it can't be reviewed or merged from here, if it can't.
    static func whyNot(_ pr: PrRow, store: Store) -> String? {
        guard let mac = store.devices.first(where: { $0.key == pr.device }) else { return "Its Mac isn't linked any more" }
        if !mac.online { return "\(mac.name) isn't connected" }
        if !mac.remoteControl { return "Remote control is off on \(mac.name)" }
        return nil
    }

    var body: some View {
        Paged(swipe: swipe, key: page, next: onward, back: before, leaves: false, ready: detail != nil || problem != nil) {
            content
        }
        // What's next is in the menu and a swipe away; on a keyboard, ⌘] as on the Mac.
        .background {
            if let onward {
                // Unseen, at no size: one that takes no touches takes no keys either.
                Button("Next") { goOn(to: onward) }
                    .keyboardShortcut("]", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .navigationTitle(pr.map { "#" + String($0.number) } ?? "PR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { menu }
        // Again once its Mac connects (one opened before, as from a link, read nothing), when the
        // PR changes, and when another Mac is the one asked.
        .task(id: "\(key) \(macOnline) \(pr?.updatedAt ?? 0) \(pr?.device ?? "")") { await load() }
        .onChange(of: store.goingThrough(page, project: project), initial: true) { _, now in
            if now { goingThrough = true }
        }
        .onAppear {
            store.showing = page
            // Gone on to from another: say how that one went.
            if let outcome = store.outcome {
                said = outcome
                store.outcome = nil
            }
            takeLateOutcome()
        }
        .onDisappear {
            if store.showing == page { store.showing = nil }
        }
        .onChange(of: store.lateOutcomes) { _, _ in takeLateOutcome() }
    }

    @ViewBuilder
    private var content: some View {
        if let pr {
            let whyNot = Self.whyNot(pr, store: store)
            ScrollView {
                PrContent(pr: pr, detail: detail, problem: problem, canMerge: whyNot == nil && !pr.slug.isEmpty) { merging = true }
                    .padding()
            }
            .refreshable { await load() }
            .scrollDismissesKeyboard(.interactively)
            .gesture(QueueSwipe(back: before != nil, moved: { swipe.moved($0) }, ended: swiped))
            // A bar, as the list's start bar is, with a hard edge: the page goes under it
            // rather than reading through the box's glass.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    // Not while you write your review: the box needs the room, and what's next waits.
                    if let onward, !drafted {
                        GoOnBar(next: onward, left: after.count, going: going, picked: reviewOn.label, choices: { ReviewSwipeOn.picker($reviewOn) }) { goOn(to: onward) }
                            .padding(.horizontal)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    ReviewBoxView(pr: pr, draft: detail?.draft, reviews: detail?.reviews ?? [], read: detail != nil, whyNot: whyNot ?? (pr.slug.isEmpty ? "Its Mac can't review this PR: its repo has no GitHub name there." : nil), said: said) { words in
                        said = words
                        // A review submitted is the one asked of you, whatever its verdict.
                        acted = true
                        store.dealtWith(page)
                        Task { await load() }
                    }
                }
            }
            .sheet(isPresented: $merging) {
                MergeSheet(pr: pr) { words in
                    said = words
                    acted = true
                    Task { await load() }
                }
            }
            .sheet(item: $snoozing) { SnoozePicker(pick: $0) }
        } else {
            ContentUnavailableView("No longer listed", systemImage: "arrow.triangle.pull", description: Text("Its Mac doesn't list this PR now."))
        }
    }

    private func load() async {
        guard let pr, !pr.slug.isEmpty else {
            problem = "Its Mac can't read this PR from GitHub: its repo has no GitHub name there."
            return
        }
        reads += 1
        let read = reads
        loading = true
        defer { if read == reads { loading = false } }
        do {
            let got = try await store.prDetail(pr)
            guard read == reads else { return }
            detail = got
            problem = nil
        } catch {
            guard read == reads else { return }
            problem = words(error)
        }
    }

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TitleBlock(key: swipe.to?.key ?? page)
        }
        ToolbarItem(placement: .topBarTrailing) {
            ImproveButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // A swipe across the page does it too, and what the bar says goes with it.
                if let onward {
                    Button { goOn(to: onward) } label: {
                        if let next = onward.waiting {
                            Label("Go to next", systemImage: "arrow.forward")
                            Text(next.title)
                        } else {
                            Label("Finish", systemImage: "checkmark.circle")
                            Text("Nothing else waits on you")
                        }
                    }
                    Divider()
                }
                if let pr, let url = URL(string: pr.url) {
                    Button("Open on GitHub", systemImage: "safari") { openURL(url) }
                }
                if let pr, pr.reviewRequested || pr.snoozedUntil != nil {
                    Menu("Snooze review", systemImage: "moon.zzz") {
                        ForEach(Snooze.choices()) { c in
                            Button(c.label) { Task { await snooze(pr, until: c.until) } }
                        }
                        Button("Pick a time…", systemImage: "calendar") {
                            snoozing = SnoozePick(id: pr.key, title: "Snooze review") { until in Task { await snooze(pr, until: until) } }
                        }
                        if pr.snoozedUntil != nil {
                            Button("Wake now", systemImage: "sun.max") { Task { await snooze(pr, until: nil) } }
                        }
                    }
                    .disabled(!macOnline)
                }
                // What the Mac's menu copies.
                if let pr {
                    Section {
                        if !pr.url.isEmpty {
                            Button("Copy link", systemImage: "link") { UIPasteboard.general.string = pr.url }
                        }
                        if let branch = pr.branch, !branch.isEmpty {
                            Button("Copy branch name", systemImage: "arrow.triangle.branch") { UIPasteboard.general.string = branch }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func snooze(_ pr: PrRow, until: Date?) async {
        do {
            try await store.prSnooze(pr, until: until)
            said = until.map { "Your review is snoozed until \(Snooze.words($0))." } ?? "Your review waits on you again."
        } catch {
            said = words(error)
        }
    }

    /// A swipe let go: far or fast enough toward what's that way, it slides there; otherwise the
    /// page settles back.
    private func swiped(_ distance: CGFloat, _ speed: CGFloat) {
        let ahead = distance < 0
        guard swipe.letGo(distance, speed, toward: ahead ? onward != nil : distance > 0 && before != nil) else { return }
        if ahead, let onward {
            goOn(to: onward, speed: speed)
        } else if let target = before {
            // Back is a step by hand: nothing is done to this one for it.
            store.outcome = acted ? said : nil
            slide(to: target.key, back: true, speed: speed) { store.back(to: target.key) }
        }
    }

    /// Goes on to `next` as a swipe does, doing to this PR what the bar says. Snoozing waits on its
    /// Mac, which the swipe doesn't: it goes after the rest meanwhile, and leaves what waits on you
    /// once its Mac has it snoozed; it isn't kept as dealt with, so it's back when the snooze ends,
    /// as the Mac's queue has it. One its Mac didn't snooze says why (`Store.snoozeLater`).
    private func goOn(to next: Onward, speed: CGFloat = 0) {
        guard swipe.to == nil else { return }
        if case .snooze = going, let pr, let snooze = reviewOn.snoozeChoice() {
            store.snoozeLater(pr, until: snooze.until)
            moveOn(to: next, outcome: "Snoozed your review of #\(pr.number) until \(Snooze.words(snooze.until)).", speed: speed)
        } else {
            moveOn(to: next, speed: speed)
        }
    }

    /// Shows `next` in this one's place, saying there how this one went once you've acted here.
    /// Left without a review while it waits on one, this one comes round again after the rest.
    private func moveOn(to next: Onward, outcome: String? = nil, speed: CGFloat = 0) {
        guard swipe.to == nil else { return }
        if next.key != page { store.trail.append(page) }
        if next == .end { store.goingToEnd(from: page) }
        store.outcome = outcome ?? (acted ? said : nil)
        slide(to: next.key, back: false, speed: speed)
    }

    /// Slides this page away and `target`'s in after it, then does `then` and shows `target` in its
    /// place, starting as it was drawn sliding in.
    private func slide(to target: String, back: Bool, speed: CGFloat = 0, then: @escaping () -> Void = {}) {
        if !target.hasPrefix(Self.prefix) {
            store.slidIn = (target, Opening(kept: swipe.kept[target] ?? Kept(), said: store.outcome))
        }
        swipe.slide(to: target, back: back, speed: speed, reduceMotion: reduceMotion, go: go, then: then)
    }

    /// Says how what a swipe did to what was gone on from went, once its Mac has answered, unless
    /// this page is sliding away: the one sliding in says it.
    private func takeLateOutcome() {
        guard !store.lateOutcomes.isEmpty, store.showing == page, swipe.to == nil else { return }
        said = store.lateOutcomes.joined(separator: "\n")
        store.lateOutcomes = []
    }
}

/// What a PR's page shows over its review box, from what was read of it: where it stands, then
/// what was read, or why it couldn't be. The page and the glance a swipe brings in draw it alike.
private struct PrContent: View {
    let pr: PrRow
    let detail: PrDetail?
    let problem: String?
    let canMerge: Bool
    let merge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PrHeader(pr: pr, canMerge: canMerge, merge: merge)
            // A read again that failed, over what was read before.
            if detail != nil, let problem {
                Label("Couldn’t read it again: \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let detail {
                if let draft = detail.draft {
                    DraftSection(draft: draft)
                }
                DescriptionSection(body: detail.body)
                ReviewsSection(reviews: detail.reviews, requested: detail.requested)
                if !detail.comments.isEmpty {
                    CommentsSection(comments: detail.comments)
                }
                FilesSection(files: detail.files, more: detail.moreFiles, changed: pr.changedFiles)
            } else if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            }
        }
    }
}

/// A PR beside the page shown, as a swipe brings it in: its page as it first draws it, from what
/// was last read of it, at its top, with its review box and the bar over it.
struct PrGlance: View {
    let key: String
    /// How the page gone on from went, as this one will say it.
    let said: String?
    /// The page a swipe goes on from to this one, and whether that leaves what waits on you: nil
    /// going back to one.
    var from: (key: String, leaves: Bool)?
    @Environment(Store.self) private var store
    @AppStorage("project") private var project = ""

    var body: some View {
        if let pr = store.pr(key) {
            let whyNot = PrView.whyNot(pr, store: store)
            let detail = store.prDetails[key]
            // Its top under the bar, what doesn't fit going off the foot: laid over a screen's worth
            // of nothing, so it's a screen high however long the page is.
            Color.clear.overlay(alignment: .top) {
                PrContent(pr: pr, detail: detail, problem: nil, canMerge: whyNot == nil) {}
                    .padding()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .clipped()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    let after = waitingAfter(PrView.prefix + key, from: from, store: store, project: project)
                    // As its page will have it: gone on to, it's part of what you're going through.
                    let onward = Onward.of(after, goingThrough: from != nil || store.goingThrough(PrView.prefix + key, project: project))
                    if let next = onward, (store.drafts[PrView.prefix + key] ?? "").isEmpty {
                        GoOnBar(next: next, left: after.count, going: Going.of(.later, pr: pr, acted: false), picked: ReviewSwipeOn.later.label, choices: { EmptyView() }) {}
                            .padding(.horizontal)
                    }
                    ReviewBoxView(pr: pr, draft: detail?.draft, reviews: detail?.reviews ?? [], read: detail != nil, whyNot: whyNot, said: said) { _ in }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Where a PR stands, at the top of its page, with Merge beside its state, as the Mac's panel has
/// it under its header.
private struct PrHeader: View {
    let pr: PrRow
    let canMerge: Bool
    let merge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pr.title).font(.title3.weight(.semibold))
            Text([pr.slug.isEmpty ? pr.repo : pr.slug, "#\(pr.number)", pr.author.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let head = pr.branch {
                Text(pr.base.map { "\(head) → \($0)" } ?? head)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                StateChip(state: pr.state, turn: pr.turn)
                ChecksLine(passed: pr.passed, failed: pr.failing, pending: pr.pending)
                if pr.additions + pr.deletions > 0 {
                    // The first to give way, short of room.
                    Text("+\(pr.additions) −\(pr.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
                mergeButton.fixedSize()
            }
            if let words = mergeWords {
                Text(words).font(.caption).foregroundStyle(.secondary)
            }
            if !pr.labels.isEmpty {
                PrLabels(labels: pr.labels)
            }
            if let stale = pr.stale {
                Label {
                    Text(stale)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
                .font(.footnote)
            }
            if let turn = pr.turn {
                TurnLabel(turn: turn)
            }
            if let review = pr.agentReview {
                AgentReviewLabel(review: review)
            }
            if pr.waits {
                Label {
                    Text(pr.requestedBy.map { "\($0) asked for your review" } ?? "Your review is asked for")
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                }
                .font(.footnote)
            } else if let until = pr.snoozedUntil {
                Label("Your review is snoozed until \(Snooze.words(Date(timeIntervalSince1970: Double(until) / 1000)))", systemImage: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SessionsSection(keys: pr.sessions)
        }
    }

    /// Opens the merge box: for an open PR, merging it; for one that's closed or merged, what's
    /// left to do with its branch. Filled when it's ready to merge.
    @ViewBuilder
    private var mergeButton: some View {
        let button = Button(action: merge) {
            Label(open ? "Merge…" : "Branch…", systemImage: "arrow.triangle.merge")
                .font(.subheadline.weight(.medium))
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .disabled(!canMerge)
        if open && (pr.merge == "clean" || pr.merge == "unstable") {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var open: Bool { ["open", "draft", "approved", "changes"].contains(pr.state) }

    /// Whether it can merge, as the board reads it, for an open PR.
    private var mergeWords: String? {
        guard open else { return nil }
        switch pr.merge {
        case "clean": return "Ready to merge"
        case "conflicts": return "Conflicts with \(pr.base ?? "its base")"
        case "behind": return "Behind \(pr.base ?? "its base")"
        case "blocked": return "Merging is blocked"
        case "unstable": return "Ready to merge, with checks the repo doesn’t require not passing"
        default: return nil
        }
    }
}

/// The sessions that worked on it, under where it stands, as the Mac's panel has them under its
/// header (`PanelPlaces`): each opens its session, so the one that made it is a tap away. Only
/// the ones the list has: an archived session has no row here to open.
private struct SessionsSection: View {
    let keys: [String]
    @Environment(Store.self) private var store

    var body: some View {
        let rows = keys.compactMap { key in store.sessions.first { $0.key == key } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Heading(text: rows.count == 1 ? "Session" : "Sessions")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.key) { i, r in
                        if i > 0 {
                            Divider().padding(.leading, 12)
                        }
                        NavigationLink(value: r.key) {
                            HStack(spacing: 8) {
                                QuickSessionRow(row: r, showDevice: store.devices.count > 1, showProject: false)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
            .padding(.top, 10)
        }
    }
}

/// A PR's labels from GitHub, each with a dot in its color, as the Mac shows them: all of them on
/// its page, wrapping, and on a row as many as fit on its line.
struct PrLabels: View {
    let labels: [PrLabelRow]
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 8) {
                ForEach(labels, id: \.name) { chip($0) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(labels, id: \.name) { label in
                    chip(label)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.background.secondary, in: .capsule)
                        .accessibilityHint(label.description ?? "")
                }
            }
            .font(.caption)
        }
    }

    private func chip(_ label: PrLabelRow) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(label.color.map { Color(red: Double($0.red), green: Double($0.green), blue: Double($0.blue)) } ?? .secondary)
                .frame(width: 7, height: 7)
            Text(label.name).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Label: \(label.name)")
    }
}

/// Lays its views out in rows, going on to the next row where one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if !row.items.isEmpty && row.width + spacing + w > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + w
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Where Codealong's own review of a PR stands on its Mac, as the line over the Mac's review box
/// says it: the latest round, and what its agent suggests until its review goes as yours.
struct AgentReviewLabel: View {
    let review: AgentReviewLine

    var body: some View {
        Label {
            Text(review.suggests.map { "\(review.says) · \($0)" } ?? review.says)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var icon: String {
        switch review.stage {
        case "queued": "hourglass"
        case "reviewing": "eye"
        case "posted": "text.bubble"
        case "drafted": "note.text"
        case "skipped": "circle.dashed"
        case "failed": "exclamationmark.triangle"
        default: "checkmark.circle"
        }
    }

    private var tint: Color {
        switch review.stage {
        case "failed": .orange
        case "reviewing", "queued": .blue
        default: .secondary
        }
    }
}

/// Whose move a PR is, where its review state doesn't say, in a sentence: what the Mac's pill says
/// when you hover it.
struct TurnLabel: View {
    let turn: PrTurn

    var body: some View {
        Label {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Clock.text(turn.says, now: context.date))
            }
        } icon: {
            Image(systemName: Self.symbol(turn)).foregroundStyle(turn.yours ? Color.orange : Color.secondary)
        }
        .font(.footnote)
    }

    static func symbol(_ turn: PrTurn) -> String {
        switch turn.kind {
        case "reply-needed": "arrowshape.turn.up.left"
        case "rereview-asked": "hourglass"
        // It waits on your review, as the Mac's mark for one asked of you has it.
        case "assigned": "eye"
        default: "text.bubble"
        }
    }
}

/// A PR's state, as a chip, or whose move it is in its place where the Mac says, as its pill has
/// it: GitHub keeps Changes requested after the fixes are in or the author has answered.
struct StateChip: View {
    let state: String
    var turn: PrTurn? = nil

    var body: some View {
        let (word, color) = said
        Text(word)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
    }

    private var said: (String, Color) {
        if let turn { return (turn.words, turn.yours ? .orange : .gray) }
        return switch state {
        case "draft": ("Draft", .gray)
        case "approved": ("Approved", .green)
        case "changes": ("Changes requested", .red)
        case "merged": ("Merged", .purple)
        case "closed": ("Closed", .red)
        default: ("Open", .green)
        }
    }
}

/// A PR's checks in a line: passed, failed, still running.
private struct ChecksLine: View {
    let passed: UInt32
    let failed: UInt32
    let pending: UInt32

    var body: some View {
        HStack(spacing: 6) {
            if failed > 0 { Label("\(failed)", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
            if pending > 0 { Label("\(pending)", systemImage: "clock").foregroundStyle(.orange) }
            if passed > 0 { Label("\(passed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .font(.caption.monospacedDigit())
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([failed > 0 ? "\(failed) checks failed" : nil, pending > 0 ? "\(pending) running" : nil, passed > 0 ? "\(passed) passed" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A heading over one part of the page.
private struct Heading: View {
    let text: String

    var body: some View {
        Text(text).font(.headline)
    }
}

/// Your draft review: submitted with whatever review you send from here, so it's shown first. A
/// long one (an agent's often is) shows its start, and the rest a tap away.
private struct DraftSection: View {
    let draft: PrDraft
    @State private var whole = false
    @State private var long = false
    private let shortHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your draft review", systemImage: "pencil.and.list.clipboard").font(.headline)
            Text("A review from here submits it, with its \(draft.count) \(draft.count == 1 ? "comment" : "comments"), as GitHub’s Finish your review does.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            let cut = long && !whole
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Bool.self) { $0.size.height > shortHeight + 80 } action: { long = $0 }
                .frame(maxHeight: cut ? shortHeight : nil, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: cut ? 0.7 : 1), .init(color: cut ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
            if long {
                Button(whole ? "Show less" : "Show the whole draft") {
                    withAnimation(.snappy) { whole.toggle() }
                }
                .font(.subheadline.weight(.medium))
            }
            if draft.count > UInt64(draft.comments.count) {
                Text("And \(draft.count - UInt64(draft.comments.count)) more on GitHub, more than can be shown here: finish this review on GitHub.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 16))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draft.body.isEmpty {
                MarkdownText(text: draft.body)
            }
            ForEach(Array(draft.comments.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.line.map { "\(c.path):\($0)" } ?? c.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    MarkdownText(text: c.body).font(.subheadline)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            }
        }
    }
}

private struct DescriptionSection: View {
    let body_: String

    init(body: String) { body_ = body }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(text: "Description")
            if body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                MarkdownText(text: body_)
            }
        }
    }
}

private struct ReviewsSection: View {
    let reviews: [PrReview]
    let requested: [String]

    var body: some View {
        if !reviews.isEmpty || !requested.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Heading(text: "Reviews")
                ForEach(Array(reviews.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 8) {
                        Image(systemName: icon(r.state)).foregroundStyle(color(r.state))
                        Text(r.mine ? "You" : r.author).font(.subheadline.weight(.medium))
                        Text(word(r.state)).font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let at = r.at {
                            Text(Date(timeIntervalSince1970: Double(at) / 1000), style: .relative).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !requested.isEmpty {
                    Text("Waiting on \(requested.joined(separator: ", "))").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func word(_ s: String) -> String {
        switch s {
        case "APPROVED": "approved"
        case "CHANGES_REQUESTED": "asked for changes"
        case "DISMISSED": "was dismissed"
        default: "commented"
        }
    }

    private func icon(_ s: String) -> String {
        switch s {
        case "APPROVED": "checkmark.circle.fill"
        case "CHANGES_REQUESTED": "exclamationmark.circle.fill"
        default: "text.bubble"
        }
    }

    private func color(_ s: String) -> Color {
        switch s {
        case "APPROVED": .green
        case "CHANGES_REQUESTED": .red
        default: .secondary
        }
    }
}

private struct CommentsSection: View {
    let comments: [PrComment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Heading(text: "Comments")
            ForEach(comments, id: \.id) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(c.author).font(.subheadline.weight(.medium))
                        if let path = c.path {
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if c.resolved {
                            Text("Resolved").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let at = c.at {
                            Text(Date(timeIntervalSince1970: Double(at) / 1000), style: .relative).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    MarkdownText(text: c.body).font(.subheadline)
                        .opacity(c.resolved ? 0.6 : 1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
        }
    }
}

/// The files it changes, each opening to its diff.
private struct FilesSection: View {
    let files: [PrFile]
    let more: Bool
    let changed: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(text: "Files changed (\(max(changed, UInt64(files.count))))")
            ForEach(files, id: \.path) { f in
                FileRow(file: f)
            }
            if more {
                Text("More files than GitHub sends at once: the rest are on GitHub.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileRow: View {
    let file: PrFile
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(file.path).font(.caption.monospaced()).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text("+\(file.additions)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                    Text("−\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                if let patch = file.patch {
                    DiffView(patch: patch)
                } else {
                    Text("GitHub doesn’t show a diff this big.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A unified diff, a line at a time: what's added green, what's taken out red, the hunks' heads
/// quiet. Scrolls sideways, and long ones stop at a few hundred lines.
private struct DiffView: View {
    let patch: String
    private let most = 400

    var body: some View {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(most).enumerated()), id: \.offset) { _, line in
                        let (fg, bg) = colors(line.first)
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(.caption2.monospaced())
                            .foregroundStyle(fg)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(bg)
                    }
                }
                .textSelection(.enabled)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            if lines.count > most {
                Text("\(lines.count - most) more lines, on GitHub.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func colors(_ first: Character?) -> (Color, Color) {
        switch first {
        case "+": (.primary, .green.opacity(0.14))
        case "-": (.primary, .red.opacity(0.14))
        case "@": (.secondary, .blue.opacity(0.08))
        default: (.primary, .clear)
        }
    }
}

/// The box at the foot of a PR's page, as the Mac's (PrBox.tsx): what you write goes to GitHub with
/// a verdict, Request changes, Comment or Approve, as you, through its Mac; your own PR, or one
/// that's closed, takes a comment (the core's `review_box`). A verdict submits your draft review
/// when there's one, which the page shows first, so they wait until the page has read the PR. It
/// floats over the page in glass, as a session's reply box does, and what's written is kept with
/// the PR while you look at others. Over it, where the PR stands and how you last reviewed it, as
/// the top of the page says, so a verdict isn't given twice or with failing checks unseen.
private struct ReviewBoxView: View {
    let pr: PrRow
    let draft: PrDraft?
    let reviews: [PrReview]
    /// The page has read the PR, and so knows whether you have a draft review of it.
    let read: Bool
    /// Why nothing can be sent from here, if it can't.
    let whyNot: String?
    /// How the last thing done on the page went.
    let said: String?
    let done: (String) -> Void
    @Environment(Store.self) private var store
    @FocusState private var typing: Bool
    @State private var sending: PrVerdict?
    /// Why the last review didn't go, what was written still in the box.
    @State private var failed: String?
    @State private var sent = 0

    private var text: String {
        get { store.drafts[PrView.prefix + pr.key] ?? "" }
        nonmutating set { store.drafts[PrView.prefix + pr.key] = newValue.isEmpty ? nil : newValue }
    }

    var body: some View {
        let box = reviewBox(pr: pr, draft: draft, reviews: reviews)
        VStack(alignment: .leading, spacing: 6) {
            // On one line where it fits; with less room (a larger text size), how you reviewed it
            // goes under the state, wrapping rather than losing its time.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    standing
                    yours(box).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    standing
                    yours(box)
                }
            }
            .padding(.horizontal, 10)
            if let line = failed ?? (sending == nil ? nil : "Sending to GitHub…") ?? whyNot ?? said ?? box.note {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(failed == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }
            VStack(alignment: .leading, spacing: 10) {
                TextField(box.hint, text: Binding(get: { text }, set: { text = $0; failed = nil }), axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .disabled(whyNot != nil || sending != nil)
                    // ⌘⏎ on a keyboard approves (comments, where it can't), ⌥⌘⏎ comments, as on the Mac.
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        let verdict: PrVerdict = box.reviewable && !press.modifiers.contains(.option) ? .approve : .comment
                        if can(verdict) { Task { await send(verdict) } }
                        return .handled
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                // With less room (a larger text size), Request changes and Comment show as icons.
                ViewThatFits(in: .horizontal) {
                    verdicts(box, short: false)
                    verdicts(box, short: true)
                }
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(.snappy, value: failed)
        .sensoryFeedback(.success, trigger: sent)
    }

    /// The PR's state and checks, as the top of the page has them.
    private var standing: some View {
        HStack(spacing: 8) {
            StateChip(state: pr.state, turn: pr.turn)
            ChecksLine(passed: pr.passed, failed: pr.failing, pending: pr.pending)
        }
        .fixedSize()
    }

    /// How you last reviewed it, and when.
    @ViewBuilder
    private func yours(_ box: ReviewBox) -> some View {
        if let yours = box.yours {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Clock.text(yours, now: context.date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Request changes and Comment, then Approve at the far end, filled. Where only a comment goes,
    /// Comment is at the end, filled.
    private func verdicts(_ box: ReviewBox, short: Bool) -> some View {
        HStack(spacing: 8) {
            if box.reviewable {
                button(.requestChanges, short: short, filled: false)
                button(.comment, short: short, filled: false)
                Spacer(minLength: 0)
                button(.approve, short: false, filled: true)
            } else {
                Spacer(minLength: 0)
                button(.comment, short: false, filled: true)
            }
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
    }

    /// A verdict's button: the filled one says what it is with its icon too, and with little room
    /// the others are only their icons.
    @ViewBuilder
    private func button(_ verdict: PrVerdict, short: Bool, filled: Bool) -> some View {
        let (label, icon): (String, String) = switch verdict {
        case .approve: ("Approve", "checkmark")
        case .comment: ("Comment", "text.bubble")
        case .requestChanges: ("Request changes", "exclamationmark.bubble")
        }
        let button = Button {
            Task { await send(verdict) }
        } label: {
            Group {
                if short {
                    Image(systemName: icon)
                } else if filled {
                    Label(label, systemImage: icon)
                } else {
                    Text(label)
                }
            }
            .font(.footnote.weight(filled ? .semibold : .medium))
        }
        .disabled(!can(verdict))
        .accessibilityLabel(label)
        if filled {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func can(_ verdict: PrVerdict) -> Bool {
        read && whyNot == nil && sending == nil && reviewSaysSomething(verdict: verdict, written: text, draft: draft)
    }

    private func send(_ verdict: PrVerdict) async {
        guard can(verdict) else { return }
        sending = verdict
        failed = nil
        defer { sending = nil }
        let written = text
        do {
            let went = try await store.prReview(pr, verdict: verdict, body: written.trimmingCharacters(in: .whitespacesAndNewlines), draft: draft?.stamp)
            // Only what went: the page left and opened again meanwhile may have more written.
            if text == written { text = "" }
            typing = false
            sent += 1
            done(reviewedWords(verdict: verdict, number: pr.number, draft: went))
        } catch {
            failed = words(error)
        }
    }
}

/// A PR's merge box, as GitHub's and the Mac's: where it stands for merging, the way to merge (the
/// one picked in its repo before, else GitHub's pick for you) with the commit's title and message
/// GitHub would write, and what it offers you now: merge (past the rules, for one who may and
/// chooses to), the merge queue, auto-merge, bringing the branch up to date, ready for review, and
/// the branch's deletion. The core has the rules (merge.rs, the Mac's merge.ts).
private struct MergeSheet: View {
    let pr: PrRow
    let done: (String) -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var box: MergeBox?
    /// Why the box couldn't be read, while it can't.
    @State private var problem: String?
    /// Why the last thing asked of it didn't go: kept, over the box read again since, until you
    /// ask another.
    @State private var failed: String?
    /// Which read is the latest: an earlier one that answers after it is let go.
    @State private var reads = 0
    @State private var bypassing = false
    @State private var method: MergeMethod?
    @State private var title = ""
    @State private var message = ""
    @State private var email: String?
    @State private var deleteBranch = true
    @State private var acting = false
    /// How many times the box was read again while GitHub settled (`mergeRereads`).
    @State private var rereads = 0

    /// What the box is read for, as the Mac's `boxKey`: the PR as last updated, its state, where
    /// it stands for merging and its checks, which change without the PR being updated. When
    /// that changes, the box is read again, keeping what you wrote.
    private var boxKey: String {
        "\(pr.key)@\(pr.updatedAt):\(pr.state):\(pr.merge):\(pr.passed)/\(pr.failing)/\(pr.pending)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let box {
                    // What went wrong with the last thing asked, over the box read again since.
                    if let failed {
                        Section { Text(failed).foregroundStyle(.red) }
                    }
                    if let problem {
                        Section { Label("Couldn’t read it again: \(problem)", systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                    content(box)
                } else if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .navigationTitle("Merge #" + String(pr.number))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: boxKey) {
            rereads = 0
            await read()
        }
    }

    @ViewBuilder
    private func content(_ box: MergeBox) -> some View {
        let standing = mergeStanding(mergeBox: box, base: pr.base, slug: pr.slug, failed: pr.failing, pending: pr.pending, passed: pr.passed)
        let offers = mergeOffers(mergeBox: box)
        let mode = mergeMainMode(offers: offers, bypassing: bypassing)
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(standing.says).font(.headline)
                    if let more = standing.more {
                        Text(more).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: icon(standing.tone)).foregroundStyle(color(standing.tone))
            }
        }
        if offers.bypass {
            Section {
                Toggle("Merge without waiting for its requirements", isOn: $bypassing)
            } footer: {
                Text("You can merge past this repo’s rules. GitHub records that you did.")
            }
        }
        if let mode {
            let picked = method ?? mergePickMethod(mergeBox: box, picked: nil)
            if mode != .queue, let picked {
                Section {
                    if box.methods.count > 1 {
                        Picker("Merge with", selection: Binding(get: { picked }, set: { pick($0, box) })) {
                            ForEach(box.methods, id: \.self) { m in
                                Text(methodLabel(method: m)).tag(m)
                            }
                        }
                    }
                    if picked != .rebase {
                        TextField("Commit title", text: $title, axis: .vertical).lineLimit(1...3)
                            .disabled(acting)
                        TextField("Commit message", text: $message, axis: .vertical).lineLimit(3...10)
                            .disabled(acting)
                        if box.emails.count > 1 {
                            Picker("Commit email", selection: Binding(get: { email ?? box.defaultEmail ?? box.emails[0] }, set: { email = $0 })) {
                                ForEach(box.emails, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                } footer: {
                    Text(needsTitle(mode, picked) ? "The commit needs a title." : methodWhat(method: picked))
                }
            }
            if mergeDeletesWith(mergeBox: box, mode: mode) {
                Section {
                    Toggle("Delete \(box.branch) after merging", isOn: $deleteBranch)
                }
            }
            Section {
                Button {
                    let form = MergeForm(method: picked ?? .merge, title: title, body: message, email: email ?? box.defaultEmail, deleteBranch: deleteBranch)
                    Task { await act(box, mergeActFor(mergeBox: box, mode: mode, form: form)) }
                } label: {
                    Text(acting ? "Working…" : mergeModeLabel(mode: mode, method: picked ?? .merge))
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .disabled(acting || needsTitle(mode, picked))
            }
        }
        let rest = others(box, offers)
        if !rest.isEmpty {
            Section {
                ForEach(rest, id: \.0) { label, act in
                    Button(label) { Task { await act() } }.disabled(acting)
                }
            }
        }
        if offers.conflicts, let url = URL(string: pr.url + "/conflicts") {
            Section {
                Button("Resolve conflicts on GitHub") { openURL(url) }
            }
        }
    }

    /// A merge that writes a commit goes only with a title: GitHub would put its own in place of
    /// an empty one, not the one shown.
    private func needsTitle(_ mode: MergeMode, _ method: MergeMethod?) -> Bool {
        mode != .queue && method != .rebase && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What else the box offers now, beside its main button.
    private func others(_ box: MergeBox, _ offers: Offers) -> [(String, () async -> Void)] {
        var out: [(String, () async -> Void)] = []
        if offers.stopAuto { out.append(("Turn off auto-merge", { await act(box, .stopAuto) })) }
        if offers.dequeue { out.append(("Take it out of the merge queue", { await act(box, .dequeue) })) }
        if offers.update {
            out.append(("Update branch", { await act(box, .updateBranch(rebase: false, head: box.head)) }))
            out.append(("Update branch by a rebase", { await act(box, .updateBranch(rebase: true, head: box.head)) }))
        }
        if offers.ready { out.append(("Ready for review", { await act(box, .ready) })) }
        if offers.deleteBranch, let ref = box.branchRef { out.append(("Delete \(box.branch)", { await act(box, .deleteBranch(branchRef: ref)) })) }
        return out
    }

    /// The method picked, kept for this repo, with the commit words GitHub would write for it.
    private func pick(_ m: MergeMethod, _ box: MergeBox) {
        method = m
        UserDefaults.standard.set(methodLabel(method: m), forKey: "mergeMethod:\(pr.slug)")
        let text = mergeCommitText(mergeBox: box, method: m) ?? ["", ""]
        title = text[0]
        message = text[1]
    }

    /// Reads the box. The first read fills in the form; one after keeps what's in it (what you
    /// wrote, the method you picked while the repo still allows it). GitHub that hasn't settled
    /// yet is asked again in a moment, a few times, as the Mac does.
    private func read() async {
        reads += 1
        let read = reads
        do {
            let b = try await store.prMergeBox(pr)
            guard read == reads else { return }
            let first = box == nil
            box = b
            problem = nil
            if first || !(method.map { b.methods.contains($0) } ?? false) {
                let kept = UserDefaults.standard.string(forKey: "mergeMethod:\(pr.slug)").flatMap { label in b.methods.first { methodLabel(method: $0) == label } }
                if let m = mergePickMethod(mergeBox: b, picked: kept) { pick(m, b) }
            }
            if first {
                email = b.defaultEmail
                deleteBranch = true
            }
            if mergeRereads(mergeBox: b, merge: pr.merge) && rereads < 3 {
                rereads += 1
                // Not when another read began meanwhile: it's the one that counts.
                guard (try? await Task.sleep(for: .seconds(3))) != nil, read == reads else { return }
                await self.read()
            }
        } catch {
            guard read == reads else { return }
            problem = words(error)
        }
    }

    private func act(_ box: MergeBox, _ act: MergeAct) async {
        acting = true
        failed = nil
        defer { acting = false }
        do {
            let result = try await store.prMerge(pr, id: box.id, act: act)
            let said = mergeDoneWords(act: act, number: pr.number, branch: box.branch)
            done(result.note.map { "\(said) \($0)" } ?? said)
            dismiss()
        } catch {
            // Say what went wrong, over where it stands now.
            failed = words(error)
            await read()
        }
    }

    private func icon(_ tone: MergeTone) -> String {
        switch tone {
        case .ok: "checkmark.circle.fill"
        case .wait: "clock.fill"
        case .bad: "exclamationmark.triangle.fill"
        case .done: "arrow.triangle.merge"
        }
    }

    private func color(_ tone: MergeTone) -> Color {
        switch tone {
        case .ok: .green
        case .wait: .orange
        case .bad: .red
        case .done: .purple
        }
    }
}
