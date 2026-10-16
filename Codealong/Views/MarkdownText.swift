import SwiftUI
import UIKit

/// What agents write, in Markdown, as the Mac's conversation draws it: headings, lists, quotes,
/// code blocks, tables, rules and paragraphs. The core reads the blocks and settles the links (its
/// `markdown`, the Mac's Markdown.tsx rules); each block's text is inline Markdown, which
/// SwiftUI's Text draws with its emphasis, code spans and links. What's indented under a list's
/// item is indented under it here, as deep as lists nest.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownCache.parts(text).enumerated()), id: \.offset) { _, part in
                block(part.block, depth: Int(part.depth))
                    .padding(.leading, CGFloat(part.depth) * 18)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: MdBlock, depth: Int) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(Self.inline(s))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .paragraph(let s):
            Text(Self.inline(s))
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Verbatim, as written: a localized number would read 1,244.
                        Text(verbatim: ordered ? "\(Int(start) + i)." : depth == 0 ? "•" : depth == 1 ? "◦" : "▪").foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(s))
                    }
                }
            }
        case .quote(let s):
            Text(Self.inline(s))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(width: 3)
                }
        case .code(let s):
            CodeView(text: s)
        case .table(let align, let head, let rows):
            TableView(align: align, head: head, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

/// The blocks of each text drawn lately, so a conversation that redraws doesn't read its messages
/// again. A reply being written goes in afresh with every piece, so it's cleared now and then.
@MainActor
private enum MarkdownCache {
    private static var read: [String: [MdPart]] = [:]

    static func parts(_ text: String) -> [MdPart] {
        if let parts = read[text] { return parts }
        let parts = markdown(text: text)
        if read.count > 400 { read.removeAll() }
        read[text] = parts
        return parts
    }
}

/// A fenced code block: as written, scrolling sideways, with a button that copies it.
struct CodeView: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.caption.monospaced())
                .padding(8)
                .padding(.trailing, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { CopyButton(text: text) }
    }
}

/// A table. One of a few columns fits the screen, its cells wrapping; a wider one keeps its cells
/// to a width a phone can read and scrolls sideways, as the Mac's scrolls when its words can't fit.
private struct TableView: View {
    let align: [MdAlign]
    let head: [String]
    let rows: [[String]]
    /// Columns that fit a phone's width with their cells wrapping.
    private let fits = 4
    /// In a table that scrolls, a cell wraps past this, so one long cell doesn't make a column a
    /// screen wide.
    private let widest: CGFloat = 200

    var body: some View {
        Group {
            if head.count <= fits {
                grid.padding(10)
            } else {
                ScrollView(.horizontal) { grid.padding(10) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private var grid: some View {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(head.indices, id: \.self) { j in
                        cell(head[j], column: j)
                            .fontWeight(.semibold)
                            .gridColumnAlignment(alignment(j))
                    }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { k in
                    GridRow {
                        ForEach(rows[k].indices, id: \.self) { j in
                            cell(rows[k][j], column: j)
                        }
                    }
                    if k < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
            .font(.subheadline)
    }

    private func cell(_ s: String, column j: Int) -> some View {
        Text(MarkdownText.inline(s))
            .multilineTextAlignment(textAlignment(j))
            .frame(maxWidth: head.count <= fits ? nil : widest, alignment: Alignment(horizontal: alignment(j), vertical: .center))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ j: Int) -> HorizontalAlignment {
        switch align.indices.contains(j) ? align[j] : .plain {
        case .center: .center
        case .right: .trailing
        case .left, .plain: .leading
        }
    }

    private func textAlignment(_ j: Int) -> TextAlignment {
        switch alignment(j) {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }
}

/// Copies text, and says so for a moment.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}
