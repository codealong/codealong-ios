import SwiftUI

/// One session: its conversation, what it waits on you to allow, and a box to reply. It follows the
/// session as it goes: a change in the Mac's feed brings in what came since.
struct SessionView: View {
    let key: String
    @Environment(Store.self) private var store
    @State private var conversation: Conversation?
    @State private var items: [Item] = []
    @State private var hasOlder = false
    @State private var pending: Pending?
    @State private var problem: String?
    @State private var loading = true
    @State private var draft = ""
    @State private var sending = false
    @State private var said: String?
    /// Scrolled to the newest: new items keep it there. Scrolled up to read, it stays put.
    @State private var atBottom = true
    @FocusState private var typing: Bool

    private var row: SessionRow? { store.sessions.first { $0.key == key } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if hasOlder {
                        Button("Earlier") { Task { await older() } }
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(items, id: \.id) { item in
                        ItemView(item: item)
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
        }
        .safeAreaInset(edge: .bottom) { bottom }
        .navigationTitle(row?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(row?.title ?? "Session").font(.headline).lineLimit(1)
                    if let row {
                        Text("\(row.deviceName) · \(row.project)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Archive", systemImage: "archivebox") { store.archive(key) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: key) { await open() }
        // The Mac's feed says the session moved: bring in what came since.
        .onChange(of: row?.lastActivity) { _, _ in Task { await refresh() } }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 8) {
            if let pending {
                ApprovalCard(pending: pending, canAct: canAct, why: whyNot) { allow in
                    Task { await answer(pending, allow: allow) }
                }
            }
            if let said {
                Text(said).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(canAct ? "Reply" : (whyNot ?? "Reply"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .disabled(!canAct || sending)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background.secondary, in: .rect(cornerRadius: 18))
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: sending ? "ellipsis" : "arrow.up.circle.fill").font(.title)
                }
                .disabled(!canAct || sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Only a Mac with remote control on takes a reply or an answer from here.
    private var canAct: Bool { whyNot == nil }

    private var whyNot: String? {
        guard let row, let device = store.devices.first(where: { $0.key == row.device }) else { return "That session isn't on a linked Mac any more" }
        if !device.online { return "\(device.name) isn't connected" }
        if !device.remoteControl { return "Remote control is off on \(device.name)" }
        return nil
    }

    private func open() async {
        guard conversation == nil, let conv = store.conversation(key) else { return }
        conversation = conv
        await refresh()
        loading = false
        if row?.status == .unread { store.markSeen(key) }
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

    private func send() async {
        guard let conv = conversation else { return }
        let text = draft
        sending = true
        defer { sending = false }
        do {
            said = try await Task.detached { try conv.send(text: text) }.value
            draft = ""
            typing = false
        } catch {
            said = words(error)
        }
    }

    private func answer(_ p: Pending, allow: Bool) async {
        guard let conv = conversation else { return }
        do {
            said = try await Task.detached { try conv.answer(id: p.id, allow: allow) }.value
            pending = nil
        } catch {
            said = words(error)
        }
    }
}

/// A tool call the session waits on you to allow.
private struct ApprovalCard: View {
    let pending: Pending
    let canAct: Bool
    let why: String?
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Live.text(pending.label, now: .now)).font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            if let input = pending.input, !input.isEmpty {
                ScrollView {
                    Text(input).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }
            if let cannot = pending.cannot {
                Text(cannot).font(.footnote).foregroundStyle(.secondary)
            } else if canAct {
                HStack {
                    Button("Deny", role: .destructive) { answer(false) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Allow") { answer(true) }
                        .buttonStyle(.borderedProminent)
                }
            } else if let why {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 14))
    }
}

/// One thing in the conversation: your prompts on the right, the agent's replies as text, tool
/// calls as a line that opens to what went in and came out.
private struct ItemView: View {
    let item: Item
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .you:
            HStack {
                Spacer(minLength: 40)
                Text(markdown(item.text))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 16))
                    .textSelection(.enabled)
            }
        case .agent:
            Text(markdown(item.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.failed ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver")
                            .foregroundStyle(item.failed ? .red : .secondary)
                            .font(.caption)
                        Text(markdown(item.text))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(open ? nil : 1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                if open {
                    if let input = item.input, !input.isEmpty { Block(text: input) }
                    if let output = item.output, !output.isEmpty { Block(text: output, failed: item.failed) }
                }
            }
        case .note:
            Text(markdown(item.text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
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
