import SwiftUI

/// A session's side conversations, from its menu or `/side` in its box: something asked about it
/// and answered by a throwaway copy of its conversation on its Mac, while the session carries on
/// and never hears of it, as `/side` asks on the Mac (its side.rs). The open one shows as it's
/// answered, and the box asks it; with none open, the box starts one, over the earlier ones its
/// Mac keeps, each to read and go on with, or delete. Done puts the sheet away and leaves the open
/// one open on its Mac, whose windows show it above the session's box as they do one asked there;
/// Close closes it, a copy that's answering answering first, and keeps it to read with the earlier
/// ones.
struct SideSheet: View {
    let key: String
    /// A question to ask as it opens: `/side` and a question in the session's box.
    var question: String?
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var conversation: Conversation?
    /// What it shows; the open one shows the earlier ones while there's none open.
    @State private var shown = Shown.open
    @State private var open: SideConversation?
    @State private var earlier: [SideKept] = []
    /// The latest read of the earlier ones asked for: one that answers after a later one is dropped.
    @State private var earlierRead = 0
    /// The ones closed while their copies answered, by id, as their Mac last said.
    @State private var closing: [String: SideConversation] = [:]
    /// Closing the open one is on its way: a question waits for it, or it could go to the one
    /// being closed rather than a new one.
    @State private var closingOpen = false
    /// Scrolled to the newest: an answer as it's written keeps it there. Scrolled up to read, it
    /// stays put.
    @State private var atBottom = true
    @State private var text = ""
    @State private var typing = false
    @State private var asking = false
    @State private var problem: String?
    @State private var loading = true
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 32

    enum Shown: Equatable {
        case open
        case list
        case past(String)
    }

    private var row: SessionRow? { store.sessions.first { $0.key == key } }
    private var mac: String { row?.deviceName ?? "its Mac" }
    private var whyNot: String? { store.cannotReach(row) }
    private var online: Bool { row?.deviceOnline == true }

    /// The earlier ones show in the open one's place while there's none.
    private var showing: Shown { shown == .open && open == nil ? .list : shown }

    /// The one read, from what its Mac keeps, or as it answers when it was closed answering.
    private var past: (kept: SideKept, turns: [SideTurn], running: Bool)? {
        guard case .past(let id) = shown, let kept = earlier.first(where: { $0.id == id }) else { return nil }
        if let c = closing[id], c.turns.count >= kept.turns.count { return (kept, c.turns, c.running) }
        return (kept, kept.turns, kept.answering)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                        if let problem {
                            Text(problem).font(.footnote).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                // A long one opens at its newest; what's short sits at the top.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollDismissesKeyboard(.immediately)
                .onScrollGeometryChange(for: Bool.self) { $0.atEnd } action: { _, now in atBottom = now }
                .onChange(of: open?.turns.last?.answer) { _, _ in
                    if showing == .open && atBottom { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: showing) { _, now in
                    if now != .list { proxy.scrollTo("end", anchor: .bottom) }
                }
                .scrollEdgeEffectStyle(.hard, for: .bottom)
                .safeAreaBar(edge: .bottom) { box }
            }
            // A question asked on the Mac with images shows them, read from its Mac.
            .environment(\.imageMac, row?.device)
            .navigationTitle("On the side")
            .navigationSubtitle(row?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        menu
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await start() }
        // Each change its Mac tells of comes as a change the core reports.
        .onChange(of: store.tick) { _, _ in follow() }
        // Back after its Mac went away: it may have answered, or closed, meanwhile.
        .onChange(of: online) { _, now in
            if now { Task { await reread() } }
        }
        .onChange(of: showing) { _, now in
            if now == .list { Task { await readEarlier() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch showing {
        case .open:
            if let open {
                SideTurns(turns: open.turns, running: open.running)
                if open.ended {
                    Text("Its copy has ended: what you ask next goes to a new one, told what was said.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .list:
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                Text("A copy of the session’s conversation answers on \(mac). The session carries on and never hears of it. The copy may do what the session can without asking, but changes nothing unless you ask for that change in so many words.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !earlier.isEmpty {
                    Text("Earlier")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(earlier, id: \.id) { kept in
                            EarlierRow(kept: kept, isOpen: kept.id == open?.id, answering: closing[kept.id]?.running ?? kept.answering) {
                                shown = kept.id == open?.id ? .open : .past(kept.id)
                            }
                            .contextMenu {
                                if kept.id != open?.id {
                                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await forget(kept.id) } }
                                }
                            }
                            if kept.id != earlier.last?.id { Divider() }
                        }
                    }
                }
            }
        case .past:
            if let past {
                SideTurns(turns: past.turns, running: past.running)
                Text(past.running ? "Closed while it answered: it answers what it was asked, then it’s kept to read." : "What you ask goes on in this one, its copy told what was said.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if showing == .open {
            Button {
                Task { await close() }
            } label: {
                Label("Close", systemImage: "xmark.circle")
                Text("Kept on \(mac) to read. What you ask next starts another")
            }
            // Not while a question is on its way, which would go on in what's closed, or start
            // another that knows none of it.
            .disabled(!online || asking)
        } else if open != nil {
            Button("Back to the open one", systemImage: "arrow.uturn.backward") { shown = .open }
        }
        if showing != .list {
            Button("Earlier", systemImage: "clock.arrow.circlepath") { shown = .list }
        }
        if case .past(let id) = showing {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await forget(id) } }
                .disabled(!online || asking)
        }
    }

    private var box: some View {
        ReplyBox(open: typing || !text.isEmpty, size: sendSize, attach: nil) {
            EmptyView()
        } field: {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // ⌘⏎ on a keyboard asks, as on the Mac.
                WritingField(text: $text, focused: $typing, label: placeholder, editable: whyNot == nil && !asking, commandReturn: {
                    Task { await send() }
                })
            }
        } tools: {
            EmptyView()
        } action: {
            Button {
                Task { await send() }
            } label: {
                SendMark(ready: canSend || asking, sending: asking, size: sendSize)
                    .contentShape(.circle.inset(by: -replyInset))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Ask")
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var placeholder: String {
        if let whyNot { return whyNot }
        if case .past = showing { return "Go on with this one" }
        return "Ask on the side"
    }

    private var canSend: Bool {
        whyNot == nil && !asking && !closingOpen && !loading && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() async {
        guard conversation == nil, let conv = store.conversation(key) else { return }
        conversation = conv
        // What's known shows at once; its Mac says what it is now.
        open = conv.side()
        if open != nil { loading = false }
        await reread()
        loading = false
        if let question, !question.isEmpty {
            await ask(question)
        } else if open == nil {
            typing = true
        }
    }

    /// Reads the open one from its Mac, which tells of each change from then on, and the earlier
    /// ones when they show.
    private func reread() async {
        guard let conv = conversation else { return }
        do {
            // As the core has it after the read: a read the Mac's word overtook is dropped there.
            _ = try await Task.detached { try conv.readSide() }.value
            open = conv.side()
            problem = nil
        } catch {
            problem = words(error)
        }
        if showing != .open { await readEarlier() }
    }

    private func readEarlier() async {
        guard let conv = conversation else { return }
        earlierRead += 1
        let read = earlierRead
        do {
            let kept = try await Task.detached { try conv.earlierSides() }.value
            guard read == earlierRead else { return }
            earlier = kept
            // What's kept says how far each closed one got; the core let go of the ones done.
            follow()
        } catch {
            if read == earlierRead { problem = words(error) }
        }
    }

    /// Takes what its Mac said: the open one as it's answered, and one closed answering as it's
    /// read. A turn that ended, or the open one gone, changes what's kept.
    private func follow() {
        guard let conv = conversation else { return }
        // While it's first read, what's read says.
        let now = conv.side()
        if !loading && now != open {
            let turnEnded = now?.turns.filter(\.done).count != open?.turns.filter(\.done).count
            open = now
            if turnEnded && showing != .open { Task { await readEarlier() } }
        }
        // Each closed one still answering, listed or read: once it has answered, what's kept has
        // its answer.
        var told: [String: SideConversation] = [:]
        for kept in earlier where kept.answering || closing[kept.id] != nil {
            if let c = conv.sideClosing(id: kept.id) { told[kept.id] = c }
        }
        if told != closing {
            let answered = closing.contains { id, was in was.running && told[id]?.running != true }
            closing = told
            if answered { Task { await readEarlier() } }
        }
    }

    private func send() async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        await ask(question)
    }

    /// Asks the open one, or a new one, or the one being read, which is the open one then.
    private func ask(_ question: String) async {
        guard let conv = conversation else { return }
        let from: String? = if case .past(let id) = showing { id } else { nil }
        asking = true
        defer { asking = false }
        problem = nil
        do {
            _ = try await Task.detached { try conv.askSide(text: question, from: from) }.value
            open = conv.side()
            shown = .open
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == question { text = "" }
        } catch {
            problem = words(error)
            // `/side` and a question from the session's box: it's here to ask again.
            if text.isEmpty { text = question }
        }
    }

    /// Closes the open one: it's gone from here at once, and back if its Mac didn't hear it.
    private func close() async {
        guard let conv = conversation, let was = open else { return }
        open = nil
        shown = .list
        closingOpen = true
        defer { closingOpen = false }
        do {
            try await Task.detached { try conv.closeSide() }.value
            open = conv.side()
            await readEarlier()
        } catch {
            open = was
            shown = .open
            problem = words(error)
        }
    }

    /// Deletes one kept on its Mac: it's off the list at once.
    private func forget(_ id: String) async {
        guard let conv = conversation else { return }
        earlier.removeAll { $0.id == id }
        if shown == .past(id) { shown = .list }
        do {
            try await Task.detached { try conv.forgetSide(id: id) }.value
        } catch {
            problem = words(error)
        }
        await readEarlier()
    }
}

/// A side conversation's questions and answers, with what its copy did to answer each.
private struct SideTurns: View {
    let turns: [SideTurn]
    /// Its copy is answering: a turn without its answer is on its way.
    let running: Bool

    var body: some View {
        ForEach(Array(turns.enumerated()), id: \.offset) { i, turn in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer(minLength: 40)
                    PromptText(text: turn.question)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 16))
                        .textSelection(.enabled)
                }
                if !turn.tools.isEmpty {
                    SideTools(lines: turn.tools)
                }
                if !turn.answer.isEmpty {
                    MarkdownText(text: turn.answer)
                }
                if let error = turn.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if running && !turn.done {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(state(turn, first: !turns[..<i].contains { !$0.done }))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// What a turn without its answer is doing, as the Mac's side.ts `turnState` says it: the tool
    /// its copy runs, or reading the conversation before it starts; one after the turn the copy is
    /// on waits.
    private func state(_ turn: SideTurn, first: Bool) -> String {
        if let tool = turn.tool { return tool }
        if !first { return "Next" }
        return turn.answer.isEmpty ? "Reading the conversation…" : "Writing…"
    }
}

/// What the copy did to answer: how many tool calls, opening to each, a line apiece.
private struct SideTools: View {
    let lines: [String]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                Text(open ? "Hide tool calls" : lines.count == 1 ? "1 tool call" : "\(lines.count) tool calls")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// One of a session's side conversations kept on its Mac, by what it was first asked.
private struct EarlierRow: View {
    let kept: SideKept
    /// It's the open one, which shows instead of being read.
    let isOpen: Bool
    /// Closed while its copy answered, and answering still, as its Mac last said.
    let answering: Bool
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: firstLine)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(when)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var firstLine: String {
        kept.turns.first?.question.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Where it stands since when, as the Mac's card says it (Answering, Answered 2h ago).
    private var when: String {
        let last = Date(timeIntervalSince1970: TimeInterval(kept.lastAt) / 1000)
        let ago = last.formatted(.relative(presentation: .named))
        let asked = kept.turns.count == 1 ? "" : " · \(kept.turns.count) questions"
        if isOpen { return "Open · last asked \(ago)\(asked)" }
        if answering { return "Answering\(asked)" }
        return "Answered \(ago)\(asked)"
    }
}
