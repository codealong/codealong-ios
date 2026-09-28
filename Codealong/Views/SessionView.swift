import SwiftUI

/// One session: its conversation, what it waits on you to allow, and a box to reply. It follows the
/// session as it goes: a change in the Mac's feed brings in what came since.
///
/// It also works through what waits on you, as the Mac's session panel does with ⌘⏎: once you've
/// replied or answered, the most urgent session still waiting on you is a tap away above the box,
/// and holding Send sends and goes on at once. The chevron at the top skips to it; one skipped
/// comes round again after the rest.
struct SessionView: View {
    let key: String
    /// Shows another session in this one's place.
    var go: (String) -> Void = { _ in }
    @Environment(Store.self) private var store
    /// The inbox's project: what's next stays in it.
    @AppStorage("project") private var project = ""
    /// You replied or answered here, so what's next is offered.
    @State private var acted = false
    @Environment(\.dismiss) private var dismiss
    @State private var conversation: Conversation?
    @State private var items: [Item] = []
    @State private var hasOlder = false
    @State private var pending: Pending?
    @State private var problem: String?
    @State private var loading = true
    @State private var draft = ""
    @State private var sending = false
    @State private var said: String?
    /// The reply it's writing, while it takes a turn Codealong runs on its Mac.
    @State private var live: Live?
    @State private var watching = false
    @State private var stopping = false
    /// Scrolled to the newest: new items keep it there. Scrolled up to read, it stays put.
    @State private var atBottom = true
    @FocusState private var typing: Bool
    /// The send button's size, which a line of the reply box matches; it grows with the text size.
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32
    /// Between the send button and the reply box's edge.
    private let replyInset: CGFloat = 6

    private var row: SessionRow? { store.sessions.first { $0.key == key } }
    /// What waits on you after this one; the first is next.
    private var after: [SessionRow] { store.queue(after: key, project: project) }

    /// The conversation as it reads: what was said, and each run of tool calls between as one.
    private var entries: [Entry] {
        var out: [Entry] = []
        var run: [Item] = []
        for item in items {
            if item.kind == .tool {
                run.append(item)
                continue
            }
            if !run.isEmpty { out.append(.tools(run)) }
            run = []
            out.append(.said(item))
        }
        if !run.isEmpty { out.append(.tools(run)) }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if hasOlder {
                        Button("Earlier") { Task { await older() } }
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(entries) { entry in
                        switch entry {
                        case .said(let item): ItemView(item: item)
                        case .tools(let calls): ToolRun(calls: calls)
                        }
                    }
                    if let live {
                        LiveReply(live: live)
                    }
                    if loading && items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, now in
                atBottom = now
            }
            .onChange(of: items.count) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: live?.text) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { bottom }
        .navigationTitle(row?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(row?.title ?? "Session").font(.headline).lineLimit(1)
                    if let row {
                        Text("\(Names.short(row.deviceName)) · \(row.project)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if let next = after.first {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { moveOn(to: next) } label: {
                        Label("Next", systemImage: "chevron.down")
                    }
                    .keyboardShortcut("]", modifiers: .command)
                    .accessibilityLabel("Next that waits on you: \(next.title)")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canStop {
                        Button("Stop", systemImage: "stop.circle") { Task { await stop() } }
                    }
                    Button("Archive", systemImage: "archivebox") {
                        store.archive(key)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: key) { await open() }
        // The Mac's feed says the session moved: bring in what came since.
        .onChange(of: row?.lastActivity) { _, _ in Task { await refresh() } }
        // A turn that ends while it's shown here has been seen.
        .onChange(of: row?.status) { _, status in
            if status == .unread { store.markSeen(key) }
        }
        // A reply being written comes as a change the core reports.
        .onChange(of: store.tick) { _, _ in
            guard watching, let conv = conversation else { return }
            let now = conv.live()
            // The turn ended: the reply stays up until the conversation has it, so the list never
            // shrinks under where it's scrolled to.
            if now == nil, live != nil {
                Task {
                    await refresh()
                    live = conv.live()
                }
            } else {
                live = now
            }
        }
        .onDisappear {
            if watching, let conv = conversation {
                Task.detached { conv.unwatch() }
            }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 8) {
            if let pending {
                ApprovalCard(pending: pending, canAct: canAct, why: whyNot) { choice in
                    Task { await answer(pending, choice) }
                }
            }
            if canStop {
                Button(role: .destructive) {
                    Task { await stop() }
                } label: {
                    Label(stopping ? "Stopping…" : "Stop this turn", systemImage: "stop.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(stopping)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let said {
                Text(said).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if acted, let next = after.first {
                NextButton(next: next, more: after.count - 1, showDevice: store.devices.count > 1, showProject: project.isEmpty) { moveOn(to: next) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // The reply box floats over the conversation in glass, as a control, not a bar. A line
            // of text is as tall as the send button, so the button sits centered in the pill, and
            // as the text grows it stays at the bottom, as far from the edges as before.
            HStack(alignment: .bottom, spacing: 8) {
                TextField(canAct ? "Reply" : (whyNot ?? "Reply"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .disabled(!canAct || sending)
                    .frame(minHeight: sendSize)
                    // ⌘⏎ on a keyboard sends and goes on, as on the Mac.
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command), canSend else { return .ignored }
                        Task { await send(thenNext: true) }
                        return .handled
                    }
                Button {
                    Task { await send() }
                } label: {
                    // Accent while there's something to send, a quiet grey while there isn't.
                    let ready = canSend || sending
                    ZStack {
                        Circle().fill(ready ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        if sending {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: sendSize / 2, weight: .bold))
                                .foregroundStyle(ready ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        }
                    }
                    .frame(width: sendSize, height: sendSize)
                    // The margin around it takes a tap too.
                    .contentShape(.circle.inset(by: -replyInset))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                // Held, as Messages offers its send options: send and go straight on.
                .contextMenu {
                    if let next = after.first {
                        Button {
                            Task { await send(thenNext: true) }
                        } label: {
                            Label("Send and go to next", systemImage: "arrow.forward")
                            Text(next.title)
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, replyInset)
            .padding(.vertical, replyInset)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: sendSize / 2 + replyInset))
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    /// Only a Mac with remote control on takes a reply or an answer from here.
    private var canAct: Bool { whyNot == nil }

    private var canSend: Bool { canAct && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A turn Codealong runs on its Mac can be stopped from here.
    private var canStop: Bool { canAct && row?.hosted == true && row?.status == .working }

    private var whyNot: String? {
        guard let row, let device = store.devices.first(where: { $0.key == row.device }) else { return "That session isn't on a linked Mac any more" }
        if !device.online { return "\(device.name) isn't connected" }
        if !device.remoteControl { return "Remote control is off on \(device.name)" }
        return nil
    }

    private func open() async {
        guard conversation == nil, let conv = store.conversation(key) else { return }
        conversation = conv
        // Moved on to from another: say how that one went.
        if let outcome = store.outcome {
            said = outcome
            store.outcome = nil
        }
        await refresh()
        loading = false
        if row?.status == .unread { store.markSeen(key) }
        // A session Codealong runs sends its reply as it's written, while it's shown here.
        if row?.hosted == true {
            watching = await Task.detached { conv.watch() }.value
            live = conv.live()
        }
    }

    private func refresh() async {
        guard let conv = conversation else { return }
        do {
            items = try await Task.detached { try conv.refresh() }.value
            hasOlder = conv.hasOlder()
            problem = nil
        } catch {
            problem = words(error)
        }
        // What it waits on you for comes from the Mac only when it's waiting.
        if row?.status == .needs {
            pending = try? await Task.detached { try conv.pending() }.value
        } else {
            pending = nil
        }
    }

    private func older() async {
        guard let conv = conversation else { return }
        let all = try? await Task.detached { try conv.older() }.value
        if let all {
            items = all
            hasOlder = conv.hasOlder()
        }
    }

    /// Sends the box; with `thenNext`, goes on to what waits on you once it's gone. One that
    /// fails stays, saying why.
    private func send(thenNext: Bool = false) async {
        guard let conv = conversation else { return }
        let text = draft
        sending = true
        defer { sending = false }
        do {
            let result = try await Task.detached { try conv.send(text: text) }.value
            draft = ""
            typing = false
            done(result, outcome: "Sent to “\(title)”.", thenNext: thenNext)
        } catch {
            said = words(error)
        }
    }

    private func answer(_ p: Pending, _ choice: Choice) async {
        guard let conv = conversation else { return }
        do {
            let result = try await Task.detached { try conv.answer(id: p.id, choice: choice) }.value
            pending = nil
            done(result, outcome: choice == .deny ? "Denied “\(title)”." : "Allowed “\(title)” to go on.")
        } catch {
            said = words(error)
        }
    }

    /// A reply or an answer went: this one is dealt with until it waits on you anew, and what's
    /// next is offered, or gone on to.
    private func done(_ result: String, outcome: String, thenNext: Bool = false) {
        store.dealtWith(key)
        if thenNext, let next = after.first {
            moveOn(to: next, outcome: outcome)
            return
        }
        said = after.isEmpty ? "\(result) Nothing else waits on you." : result
        withAnimation(.snappy) { acted = true }
    }

    /// Shows `next` in this one's place, saying there how this one went once you've acted here.
    /// Left without a reply, this one comes round again after the rest.
    private func moveOn(to next: SessionRow, outcome: String? = nil) {
        if !acted && outcome == nil { store.passedOver(key) }
        store.outcome = outcome ?? (acted ? said : nil)
        go(next.key)
    }

    private var title: String { row?.title ?? "Session" }

    private func stop() async {
        guard let conv = conversation else { return }
        stopping = true
        defer { stopping = false }
        do {
            try await Task.detached { try conv.stop() }.value
            said = "Stopped."
        } catch {
            said = words(error)
        }
    }
}

/// The next session that waits on you, offered once you've replied or answered: its title, where
/// it is, and how many more wait after it.
private struct NextButton: View {
    let next: SessionRow
    let more: Int
    let showDevice: Bool
    /// The inbox shows every project, so it says which it's in.
    let showProject: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StatusMark(status: next.status, stalled: next.stalled)
                VStack(alignment: .leading, spacing: 1) {
                    Text(next.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Next")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next: \(next.title)")
        .accessibilityHint(more > 0 ? "\(more) more wait on you after it" : "The last that waits on you")
    }

    /// Where it is, and how many wait after it.
    private var place: String {
        var parts: [String] = []
        if showDevice { parts.append(Names.short(next.deviceName)) }
        if showProject { parts.append(next.project) }
        if more > 0 { parts.append("\(more) more after it") }
        if parts.isEmpty { parts.append("The last that waits on you") }
        return parts.joined(separator: " · ")
    }
}

/// A tool call the session waits on you to allow.
private struct ApprovalCard: View {
    let pending: Pending
    let canAct: Bool
    let why: String?
    let answer: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Clock.text(pending.label, now: .now)).font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            if let input = pending.input, !input.isEmpty {
                // A plan is prose to read; anything else is a command or a change, shown as is.
                ScrollView {
                    if pending.plan {
                        MarkdownText(text: input).font(.subheadline)
                    } else {
                        Text(input).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
                .frame(maxHeight: pending.plan ? 320 : 120)
            }
            if let cannot = pending.cannot {
                Text(cannot).font(.footnote).foregroundStyle(.secondary)
            } else if canAct {
                HStack {
                    Button("Deny", role: .destructive) { answer(.deny) }
                        .buttonStyle(.bordered)
                    Spacer()
                    if pending.always {
                        Button("Always allow") { answer(.always) }
                            .buttonStyle(.bordered)
                    }
                    Button(pending.plan ? "Approve" : "Allow") { answer(.allow) }
                        .buttonStyle(.borderedProminent)
                }
            } else if let why {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 20))
    }
}

/// A piece of the conversation: something said, or a run of tool calls.
private enum Entry: Identifiable {
    case said(Item)
    case tools([Item])

    var id: String {
        switch self {
        case .said(let item): item.id
        case .tools(let calls): "run:" + (calls.first?.id ?? "")
        }
    }
}

/// One thing said: your prompts on the right, the agent's replies as text, notes small between.
private struct ItemView: View {
    let item: Item

    var body: some View {
        switch item.kind {
        case .you:
            HStack {
                Spacer(minLength: 40)
                Text(inline(item.text))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 16))
                    .textSelection(.enabled)
            }
        case .agent:
            MarkdownText(text: item.text)
        case .tool:
            ToolLine(item: item)
        case .note:
            Text(inline(item.text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A run of tool calls between what was said: the latest as a line, the ones before it folded
/// into one that says how many and which tools, as the Mac's panel does. Plain text, no icons:
/// the calls are the quiet part of the conversation.
private struct ToolRun: View {
    let calls: [Item]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Folding one line into one saves nothing, so two calls show as two.
            if calls.count > 2 {
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    Text(open ? "Hide \(calls.count - 1) tool calls" : summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(calls.dropLast(), id: \.id) { ToolLine(item: $0) }
                }
            } else {
                ForEach(calls.dropLast(), id: \.id) { ToolLine(item: $0) }
            }
            if let last = calls.last {
                ToolLine(item: last)
            }
        }
    }

    /// "4 tool calls · Bash, Read · 1 failed" for the ones before the latest.
    private var summary: String {
        let earlier = calls.dropLast()
        var names: [String] = []
        for call in earlier {
            let name = call.text.components(separatedBy: " · ").first ?? call.text
            if !names.contains(name) { names.append(name) }
        }
        var parts = ["\(earlier.count) tool calls", names.prefix(3).joined(separator: ", ")]
        let failed = earlier.filter(\.failed).count
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

/// A tool call as one quiet line, red when it failed, that opens to what went in and came out.
private struct ToolLine: View {
    let item: Item
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                Text(inline(item.text))
                    .font(.caption)
                    .foregroundStyle(item.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(open ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.failed ? "Failed: \(item.text)" : item.text)
            if open {
                if let input = item.input, !input.isEmpty { Block(text: input) }
                if let output = item.output, !output.isEmpty { Block(text: output, failed: item.failed) }
            }
        }
    }
}

/// Inline Markdown, code spans and emphasis, keeping the text's own line breaks.
private func inline(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
}

/// The reply a session Codealong runs is writing, as it comes, and the tool it's running.
private struct LiveReply: View {
    let live: Live

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !live.text.isEmpty {
                MarkdownText(text: live.text)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(live.tool.map { Clock.text($0, now: .now) } ?? AttributedString("Writing…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Block: View {
    let text: String
    var failed = false

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(failed ? .red : .primary)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}
