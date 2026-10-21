import SwiftUI

/// Edit from here, as the Mac's EditFrom.tsx: a prompt of yours, rewritten, starts a copy of the
/// session that goes on from just before it, on its Mac without a window. The session itself
/// carries on as it was, and the files stay as they are: only the conversation goes back. The
/// images the prompt came with show under its words, and go with the edit unless taken out.
struct EditFromSheet: View {
    let title: String
    /// The Mac its images are kept on.
    let mac: String
    /// Forks the session from before the prompt, this in its place.
    let fork: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var images: [PromptImage]
    @FocusState private var focused: Bool

    init(title: String, mac: String, prompt: Item, fork: @escaping (String) -> Void) {
        self.title = title
        self.mac = mac
        self.fork = fork
        // Its words as written, the files it came with still in them, and its images apart.
        let edit = promptEdit(text: prompt.text)
        _text = State(initialValue: edit.words)
        _images = State(initialValue: edit.images)
    }

    /// The edit as it goes: the images first, each on a line of its own, as a reply sends them.
    private var full: String {
        ImagePrep.prompt(images: images.map(\.reference), text: text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your message", text: $text, axis: .vertical)
                        .lineLimit(4...14)
                        .focused($focused)
                } header: {
                    Text("Your message")
                } footer: {
                    Text("A copy of “\(title)” goes on from just before this message, with your edit in its place. This session stays as it is, and so do the files: only the conversation goes back.")
                }
                if !images.isEmpty {
                    Section("Images") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(images, id: \.reference) { image in
                                    KeptImage(mac: mac, path: image.path, side: 72)
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                images.removeAll { $0 == image }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.6))
                                            }
                                            .buttonStyle(.plain)
                                            .padding(4)
                                            .accessibilityLabel("Take out \(image.name)")
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .navigationTitle("Edit from here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fork and send") {
                        fork(full)
                        dismiss()
                    }
                    .disabled(full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// Holding a prompt of yours that Edit from here can go back to offers it, as a right-click on one
/// does on the Mac, with Copy beside it; one it can't keeps its text to select.
struct EditFromMenu: ViewModifier {
    let text: String
    let edit: (() -> Void)?

    func body(content: Content) -> some View {
        if let edit {
            content.contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                Button("Edit from here", systemImage: "arrow.triangle.branch", action: edit)
            }
        } else {
            content
        }
    }
}
