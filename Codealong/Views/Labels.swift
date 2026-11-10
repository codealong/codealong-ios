import SwiftUI

/// The labels you put on sessions, as the Mac draws them: a colored square beside the name, the
/// color naming a category rather than a state.
enum LabelTint {
    /// One of the Mac's eight label colors (`SessionLabel.color`), light and dark as its
    /// tokens.css has them.
    static func ui(_ name: String) -> UIColor {
        let (light, dark) = shades[name] ?? shades["gray"]!
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    static func of(_ name: String) -> Color { Color(uiColor: ui(name)) }

    /// A menu draws its icons in its own color: the label's square, kept in its own.
    static func square(_ name: String) -> Image {
        let square = UIImage(systemName: "square.fill")?.withTintColor(ui(name), renderingMode: .alwaysOriginal)
        return square.map { Image(uiImage: $0) } ?? Image(systemName: "square.fill")
    }

    private static let shades: [String: (UInt32, UInt32)] = [
        "gray": (0x7b827d, 0x8c9490),
        "red": (0xd33a3a, 0xf16b62),
        "pink": (0xcf3478, 0xf06aa8),
        "purple": (0x8558e6, 0xad91fb),
        "indigo": (0x4f5bd5, 0x8b97f5),
        "blue": (0x1f74c9, 0x5ea6f0),
        "teal": (0x0f8484, 0x3cc4c0),
        "green": (0x23884a, 0x5cc97a),
    ]
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// A label on a session's row, as the Mac's row wears it beside its Top and Seen by agent.
struct SessionLabelChip: View {
    let label: SessionLabel

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(LabelTint.of(label.color))
                .frame(width: 7, height: 7)
            Text(verbatim: label.name)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Label: \(label.name)")
    }
}

/// A session's labels as text, each its square and its name, so a line of them ends where there's
/// room: on a row with no room for them beside where it is, and after what's said under its title.
func labelsText(_ labels: [SessionLabel]) -> Text {
    labels.enumerated().reduce(Text(verbatim: "")) { text, each in
        let (i, label) = each
        let square = Text(Image(systemName: "square.fill")).font(.system(size: 7)).foregroundStyle(LabelTint.of(label.color))
        return Text("\(text)\(Text(verbatim: i == 0 ? "" : "  "))\(square) \(Text(verbatim: label.name))")
    }
}

/// What VoiceOver says of a session's labels, which a line of them would read as squares.
func labelsSaid(_ labels: [SessionLabel]) -> String {
    labels.isEmpty ? "" : "Labels: \(labels.map(\.name).joined(separator: ", "))"
}

/// What's said under a session's title (its Mac and project) followed by its labels.
func withLabels(_ text: Text, _ labels: [SessionLabel]) -> Text {
    labels.isEmpty ? text : Text("\(text)  \(labelsText(labels))")
}
