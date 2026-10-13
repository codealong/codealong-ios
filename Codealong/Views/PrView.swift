import SwiftUI

/// A PR, as the Mac's PR panel shows it: where it stands (its state, checks, whether it can merge,
/// how big it is), your draft review of it when you began one, its description, reviews, comments
/// and changed files with their diffs. Review approves it, comments or asks for changes; Merge opens
/// its merge box. The phone has no GitHub of its own: its Mac's `gh` reads all of it and does what
/// you ask, as you, so reviewing and merging need remote control on that Mac.
struct PrView: View {
    /// What a PR's place in the list's path starts with, before its key.
    static let prefix = "pr:"
    /// `owner/name#number`.
    let key: String
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var detail: PrDetail?
    @State private var problem: String?
    @State private var loading = false
    /// Which read is the latest: an earlier one that answers after it is let go.
    @State private var reads = 0
    /// The review sheet, open with the draft the page showed when it opened: what it submits
    /// with, however the page reads the PR again behind it.
    @State private var reviewing: ReviewAsk?
    @State private var merging = false
    /// How the last thing done here went.
    @State private var said: String?

    private var pr: PrRow? { store.pr(key) }
    private var mac: DeviceRow? { store.devices.first { $0.key == pr?.device } }

    /// Why it can't be reviewed or merged from here, if it can't.
    private var whyNot: String? {
        guard let mac else { return "Its Mac isn't linked any more" }
        if !mac.online { return "\(mac.name) isn't connected" }
        if !mac.remoteControl { return "Remote control is off on \(mac.name)" }
        return nil
    }

    var body: some View {
        Group {
            if let pr {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PrHeader(pr: pr)
                        if let said {
                            Text(said).font(.footnote).foregroundStyle(.secondary)
                        }
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
                    .padding()
                }
                .refreshable { await load() }
                .safeAreaInset(edge: .bottom) { actions(pr) }
                .navigationTitle("#" + String(pr.number))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { menu(pr) }
                .sheet(item: $reviewing) { ask in
                    ReviewSheet(pr: pr, draft: ask.draft) { words in
                        said = words
                        Task { await load() }
                    }
                }
                .sheet(isPresented: $merging) {
                    MergeSheet(pr: pr) { words in
                        said = words
                        Task { await load() }
                    }
                }
            } else {
                ContentUnavailableView("No longer listed", systemImage: "arrow.triangle.pull", description: Text("Its Mac doesn't list this PR now."))
            }
        }
        // Again once its Mac connects (one opened before, as from a link, read nothing), when the
        // PR changes, and when another Mac is the one asked.
        .task(id: "\(key) \(mac?.online == true) \(pr?.updatedAt ?? 0) \(pr?.device ?? "")") { await load() }
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
    private func menu(_ pr: PrRow) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ImproveButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let url = URL(string: pr.url) {
                    Button("Open on GitHub", systemImage: "safari") { openURL(url) }
                }
                if pr.reviewRequested || pr.snoozedUntil != nil {
                    Menu("Snooze review", systemImage: "moon.zzz") {
                        ForEach(Snooze.choices()) { c in
                            Button(c.label) { Task { await snooze(pr, until: c.until) } }
                        }
                        if pr.snoozedUntil != nil {
                            Button("Wake now", systemImage: "sun.max") { Task { await snooze(pr, until: nil) } }
                        }
                    }
                    .disabled(mac?.online != true)
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

    /// Review and merge, over the foot of the page; why they can't be, when they can't.
    @ViewBuilder
    private func actions(_ pr: PrRow) -> some View {
        let open = ["open", "draft", "approved", "changes"].contains(pr.state)
        VStack(spacing: 6) {
            if let whyNot {
                Text(whyNot).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if open {
                    // Only once the page has read the PR: a review submits your draft of it,
                    // which the page shows first.
                    Button {
                        reviewing = ReviewAsk(draft: detail?.draft)
                    } label: {
                        Label("Review", systemImage: "checkmark.bubble").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(detail == nil)
                }
                Button {
                    merging = true
                } label: {
                    Label(open ? "Merge…" : "Branch…", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .disabled(whyNot != nil || pr.slug.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The review sheet asked for, with the draft the page showed then.
private struct ReviewAsk: Identifiable {
    let id = UUID()
    let draft: PrDraft?
}

/// Where a PR stands, at the top of its page.
private struct PrHeader: View {
    let pr: PrRow

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
                StateChip(state: pr.state)
                ChecksLine(passed: pr.passed, failed: pr.failing, pending: pr.pending)
                if pr.additions + pr.deletions > 0 {
                    Text("+\(pr.additions) −\(pr.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let words = mergeWords {
                Text(words).font(.caption).foregroundStyle(.secondary)
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
        }
    }

    /// Whether it can merge, as the board reads it, for an open PR.
    private var mergeWords: String? {
        guard ["open", "draft", "approved", "changes"].contains(pr.state) else { return nil }
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

/// A PR's state, as a chip.
struct StateChip: View {
    let state: String

    var body: some View {
        let (word, color): (String, Color) = switch state {
        case "draft": ("Draft", .gray)
        case "approved": ("Approved", .green)
        case "changes": ("Changes requested", .red)
        case "merged": ("Merged", .purple)
        case "closed": ("Closed", .red)
        default: ("Open", .green)
        }
        Text(word)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
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
                        Text(r.author).font(.subheadline.weight(.medium))
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

/// Approves a PR, comments on it or asks for changes, as you on GitHub through its Mac. A comment
/// or a request for changes needs something written. It submits your draft review when there's
/// one, which the page above showed.
private struct ReviewSheet: View {
    let pr: PrRow
    let draft: PrDraft?
    let done: (String) -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var verdict: PrVerdict = .approve
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?

    private var needsText: Bool { verdict != .approve && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (draft?.body.isEmpty ?? true) && (draft?.count ?? 0) == 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Review", selection: $verdict) {
                        Text("Approve").tag(PrVerdict.approve)
                        Text("Comment").tag(PrVerdict.comment)
                        Text("Request changes").tag(PrVerdict.requestChanges)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .disabled(sending)
                }
                Section {
                    TextField(verdict == .approve ? "Add a comment (optional)" : "What to say", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .disabled(sending)
                } footer: {
                    if let draft {
                        Text("Submits your draft review too, with its \(draft.count) \(draft.count == 1 ? "comment" : "comments").")
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Review #" + String(pr.number))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : send) { Task { await submit() } }
                        .disabled(sending || needsText)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var send: String {
        switch verdict {
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request changes"
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        // What went, as it was when sent.
        let verdict = verdict
        do {
            let went = try await store.prReview(pr, verdict: verdict, body: text, draft: draft?.stamp)
            let what = switch verdict {
            case .approve: "Approved"
            case .comment: "Commented on"
            case .requestChanges: "Asked for changes on"
            }
            let with = went.map { $0 > 0 ? ", with your draft review’s \($0) \($0 == 1 ? "comment" : "comments")" : "" } ?? ""
            done("\(what) #\(pr.number)\(with).")
            dismiss()
        } catch {
            problem = words(error)
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
