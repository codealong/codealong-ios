import SwiftUI

/// What agents write, in Markdown, as blocks: headings, lists, code blocks and paragraphs, each
/// line's own emphasis and code spans kept. SwiftUI's Text reads Markdown inline only, so a plan's
/// `## Steps` would show its hashes.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    Text(Self.inline(s))
                        .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 4)
                case .item(let marker, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(s))
                    }
                case .code(let s):
                    ScrollView(.horizontal) {
                        Text(s).font(.caption.monospaced()).padding(8)
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                case .paragraph(let s):
                    Text(Self.inline(s))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block: Equatable {
        case heading(Int, String)
        case item(String, String)
        case code(String)
        case paragraph(String)
    }

    /// The text's blocks, in order. Lines of a paragraph are joined; a blank line ends one.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty {
                out.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    out.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                flush()
            } else if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }), level > 0, level <= 6, line.dropFirst(level).first == " " {
                flush()
                out.append(.heading(level, String(line.dropFirst(level + 1))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                out.append(.item("•", String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(.item(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code {
            out.append(.code(lines.joined(separator: "\n")))
        }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
