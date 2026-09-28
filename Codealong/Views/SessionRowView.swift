import SwiftUI

struct SessionRowView: View {
    let row: SessionRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusGlyph(status: row.status, stalled: row.stalled)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Clock.ago(row.lastPromptAt, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(place)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail = row.detail, !detail.isEmpty {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Clock.text(detail, now: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .opacity(row.deviceOnline ? 1 : 0.6)
    }

    /// Where it is: the Mac, then the project and branch.
    private var place: String {
        var parts = [row.deviceName, row.project]
        if let branch = row.branch, !branch.isEmpty { parts.append(branch) }
        return parts.joined(separator: " · ")
    }
}

struct StatusGlyph: View {
    let status: Status
    let stalled: Bool

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .font(.body)
            .frame(width: 18)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        if stalled { return "exclamationmark.triangle.fill" }
        switch status {
        case .needs: return "hand.raised.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .working: return "circle.dotted.circle"
        case .unread: return "circle.fill"
        case .idle: return "circle"
        case .stopped: return "stop.circle"
        }
    }

    private var color: Color {
        if stalled { return .orange }
        switch status {
        case .needs: return .orange
        case .error: return .red
        case .working: return .blue
        case .unread: return .accentColor
        case .idle, .stopped: return .secondary
        }
    }

    private var label: String {
        if stalled { return "Stuck" }
        switch status {
        case .needs: return "Needs you"
        case .error: return "Error"
        case .working: return "Working"
        case .unread: return "Your turn"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        }
    }
}
