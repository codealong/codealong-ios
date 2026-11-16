import SwiftUI

/// Where a session's commands run, as its page hands it to the code blocks in what its agent
/// wrote (the Mac's RunButton.tsx `RunContext`): on its Mac, in a terminal there, as you, the
/// session told what they printed once they end. None where the phone can't act on it.
struct RunPlace {
    let conversation: Conversation
    /// The Mac it runs on, for the question asked before it does.
    let mac: String
    /// Who's told what it prints.
    let account: String
    /// The Mac has said which commands its shell takes (`learnCommands`), so a block with no
    /// language can tell whether it's commands.
    let commandsKnown: Bool
    /// Says how a run went, where the page says how what you did went.
    let said: @MainActor (String) -> Void
}

extension EnvironmentValues {
    /// Where the commands in a session's conversation run; none outside one, or where it can't.
    @Entry var runPlace: RunPlace?
}

/// Runs a code block's commands on the session's Mac. It asks first: what runs there runs as you,
/// and a tap meant for scrolling lands on a button more often than a click on the Mac does.
struct RunButton: View {
    let text: String
    /// Without its comments, as a shell block runs; else as typed, led by `!`.
    let block: Bool
    let place: RunPlace
    @State private var asking = false
    @State private var going = false
    @State private var ran = false

    var body: some View {
        Button {
            asking = true
        } label: {
            Group {
                if going {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: ran ? "checkmark" : "play")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(going)
        .accessibilityLabel(going ? "Starting" : ran ? "Running" : "Run on \(place.mac)")
        .confirmationDialog("Run on \(place.mac)?", isPresented: $asking, titleVisibility: .visible) {
            Button("Run") { Task { await run() } }
        } message: {
            Text("It runs in a terminal there, as you, in the folder the session works in. What it prints goes to \(place.account) when it ends.")
        }
    }

    private func run() async {
        going = true
        defer { going = false }
        let conv = place.conversation
        let (text, block) = (text, block)
        do {
            let said = try await Task.detached { try conv.runCommand(text: text, block: block) }.value
            place.said(said)
            ran = true
            try? await Task.sleep(for: .seconds(1.5))
            ran = false
        } catch {
            place.said(words(error))
        }
    }
}
