import SwiftUI

/// A line above a session's box saying what its agent left running in the background, as the Mac's
/// chip among its header's links does (BackgroundBits.tsx `BackgroundChip`): how many run, else how
/// many ended a little while ago, green while any runs. A tap lists them (`BackgroundSheet`).
struct BackgroundLine: View {
    let background: BackgroundCommands
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(background.running ? .green : .secondary)
                Text(background.words)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Lists them, with the last of what each printed")
    }
}

/// What a session's agent left running in the background, as the Mac lists it under its header's
/// chip (BackgroundBits.tsx `BackgroundList`): its harness's own list, as Claude Code's /tasks and
/// Codex's /ps show it, running ones first. Each command says where it stands and what it's for;
/// Output shows the last of what it printed, read from its Mac again every few seconds while it
/// runs; Stop ends a running one and what it started, and its harness tells the agent. Stop needs
/// remote control on its Mac, as acting on a session does; reading needs none. The Mac's link to a
/// local address a server printed isn't here: that address is the Mac's own, as it is for a
/// session on another Mac there.
struct BackgroundSheet: View {
    let key: String
    /// The first's output shows as it opens, for a test (`PRESS=tasks`).
    var showFirst = false
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var row: SessionRow? { store.row(key) }
    private var commands: [BackgroundCommand] { row?.background?.commands ?? [] }
    /// Why nothing can be stopped from here, or nil when it can.
    private var whyNot: String? { store.cannotReach(row) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if commands.isEmpty {
                        // They go from its Mac's list ten minutes after they end.
                        Text("Nothing it left running is listed now.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(header)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(commands, id: \.id) { command in
                            BackgroundCommandView(key: key, command: command, why: whyNot, showing: showFirst && command.id == commands.first?.id)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("In the background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// What the list is, and why its Stop buttons are off where they are.
    private var header: String {
        let what = "What its agent left running, as its harness lists it, and what ended in the last ten minutes."
        guard let whyNot, commands.contains(where: \.running) else { return what }
        return "\(what) \(whyNot), so nothing can be stopped from here."
    }
}

/// One command on the list (BackgroundBits.tsx `TaskRow`): its name, where it stands, what it's
/// for, and on demand the last of what it printed. Held, it copies the command as written.
private struct BackgroundCommandView: View {
    let key: String
    let command: BackgroundCommand
    let why: String?
    @Environment(Store.self) private var store
    @State private var showing: Bool
    @State private var output: Output?
    @State private var stopping = false
    /// How Stop went, as its Mac said it.
    @State private var said: String?

    init(key: String, command: BackgroundCommand, why: String?, showing: Bool = false) {
        self.key = key
        self.command = command
        self.why = why
        _showing = State(initialValue: showing)
    }

    enum Output: Equatable {
        case text(String)
        /// It hasn't printed anything yet.
        case nothing
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: command.monitor ? "eye" : "terminal")
                    .font(.caption)
                    .foregroundStyle(command.running ? .green : .secondary)
                    .accessibilityLabel(command.monitor ? "Monitor" : "Command")
                Text(verbatim: command.name)
                    .font(.footnote.monospaced())
                    .lineLimit(3)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Clock.text(command.state, now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let about = command.about {
                Text(about)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 16) {
                Button(showing ? "Hide output" : "Output") { showing.toggle() }
                    .accessibilityHint(showing ? "" : "Shows the last of what it printed")
                if command.running {
                    Button(stopping ? "Stopping…" : "Stop", role: .destructive) { Task { await stop() } }
                        .disabled(stopping || why != nil)
                        .accessibilityHint("Ends its process and what it started; its agent is told it ended")
                }
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.borderless)
            if let said {
                Text(said)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showing {
                printed
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .contextMenu {
            if let written = command.written {
                Button("Copy command", systemImage: "doc.on.doc") { UIPasteboard.general.string = written }
            }
        }
        // Read while it's shown, and again every few seconds while it runs.
        .task(id: "\(showing) \(command.running)") { await read() }
    }

    @ViewBuilder
    private var printed: some View {
        switch output {
        case nil:
            Text("Reading…").font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Text(why).font(.caption).foregroundStyle(.red)
        case .nothing:
            Text("It hasn’t printed anything yet.").font(.caption).foregroundStyle(.secondary)
        case .text(let text):
            OutputBlock(text: text)
        }
    }

    /// What it printed, read as it's shown and every four seconds after while it runs, as the
    /// Mac's list reads it (`OUTPUT_EVERY_MS`): a server's lines come as it goes.
    private func read() async {
        guard showing else { return }
        let running = command.running
        repeat {
            do {
                let text = try await store.taskOutput(key, id: command.id)
                guard !Task.isCancelled else { return }
                output = text.map(Output.text) ?? .nothing
            } catch {
                guard !Task.isCancelled else { return }
                output = .failed(words(error))
            }
            guard running else { return }
            try? await Task.sleep(for: .seconds(4))
        } while !Task.isCancelled
    }

    private func stop() async {
        stopping = true
        said = await store.stopTask(key, id: command.id)
        stopping = false
    }
}

/// The last lines a command printed, as written, scrolling both ways past a few lines, held at
/// its end so the latest show as more come; with a button that copies it.
private struct OutputBlock: View {
    let text: String
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: text)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .padding(.trailing, 28)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .defaultScrollAnchor(.bottomLeading)
        .frame(height: min(max(height, 32), 260))
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollBounceBehavior(.basedOnSize)
        .background(.background.tertiary, in: .rect(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { CopyButton(text: text) }
    }
}
