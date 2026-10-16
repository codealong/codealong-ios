import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A field of up to a few lines that takes a copied image as well as words, as Messages' does:
/// Paste in its menu, or ⌘V, attaches what was copied when it's an image. SwiftUI's TextField
/// offers no Paste for an image alone, hence UIKit's text view under it. Pasting from the menu
/// or the keyboard is yours, so iOS doesn't ask whether the app may.
struct WritingField: View {
    @Binding var text: String
    /// It has the keyboard: set to give it, cleared to put it away.
    @Binding var focused: Bool
    /// What VoiceOver calls it; the placeholder is the caller's, drawn behind it.
    let label: String
    var style: UIFont.TextStyle = .body
    var lines = 6
    var editable = true
    /// Takes each image pasted, in order; nil where none can go, when Paste takes only words.
    var pasted: ((Data) -> Void)?
    /// ⌘⏎ on a keyboard.
    var commandReturn: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let font = font
        let baseline = font.ascender
        Words(field: self, font: font)
            // Its first line's baseline, as a TextField reports it, for what sits beside it.
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }

    private var font: UIFont {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
    }
}

private struct Words: UIViewRepresentable {
    let field: WritingField
    let font: UIFont

    func makeUIView(context: Context) -> FieldView {
        let view = FieldView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.tintColor = UIColor(Color.accentColor)
        // Its words start where SwiftUI's would, with no margin of their own.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: FieldView, context: Context) {
        context.coordinator.field = field
        // Each only when it changed: setting one restyles the words, and would end what's being
        // composed (marked text) too.
        if view.font != font { view.font = font }
        let color: UIColor = field.editable ? .label : .secondaryLabel
        if view.textColor != color { view.textColor = color }
        if view.isEditable != field.editable {
            view.isEditable = field.editable
            view.isUserInteractionEnabled = field.editable
        }
        view.accessibilityLabel = field.label
        view.pasted = field.pasted
        view.commandReturn = field.commandReturn
        if view.text != field.text { view.text = field.text }
        view.wantsFocus = field.focused
        // After this update, since giving or taking the keyboard tells the coordinator at once.
        if field.focused != view.isFirstResponder || !field.editable {
            Task { @MainActor in view.followFocus() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: FieldView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let fits = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let most = (font.lineHeight * CGFloat(field.lines)).rounded(.up)
        // Past its lines it scrolls; under them it's as tall as its words, so it never scrolls.
        view.isScrollEnabled = fits > most
        return CGSize(width: width, height: min(fits, most))
    }

    func makeCoordinator() -> Coordinator { Coordinator(field: field) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var field: WritingField

        init(field: WritingField) { self.field = field }

        func textViewDidChange(_ view: UITextView) {
            field.text = view.text
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !field.focused { field.focused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if field.focused { field.focused = false }
        }
    }

    final class FieldView: UITextView {
        var pasted: ((Data) -> Void)?
        var commandReturn: (() -> Void)?
        /// Whether it should have the keyboard, kept for when it's in a window to take it.
        var wantsFocus = false

        /// Takes the keyboard or puts it away as `wantsFocus` says; one that can't be written in
        /// doesn't keep it, as a disabled TextField doesn't.
        func followFocus() {
            if wantsFocus, isEditable, !isFirstResponder, window != nil {
                becomeFirstResponder()
            } else if !(wantsFocus && isEditable), isFirstResponder {
                resignFirstResponder()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            followFocus()
        }

        /// Copied words paste as words; an image alone attaches.
        private var pastesImages: Bool {
            let board = UIPasteboard.general
            return pasted != nil && board.hasImages && !board.hasStrings
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) && pastesImages { return true }
            if action == #selector(commandReturned) { return commandReturn != nil }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard pastesImages, let pasted else { return super.paste(sender) }
            let images = UIPasteboard.general.itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            Task { @MainActor in
                for image in images {
                    if let data = await Self.data(of: image) { pasted(data) }
                }
            }
        }

        private static func data(of image: NSItemProvider) async -> Data? {
            await withCheckedContinuation { done in
                _ = image.loadDataRepresentation(for: .image) { @Sendable data, _ in done.resume(returning: data) }
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            let send = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturned))
            send.wantsPriorityOverSystemBehavior = true
            return (super.keyCommands ?? []) + [send]
        }

        @objc private func commandReturned() {
            commandReturn?()
        }
    }
}
