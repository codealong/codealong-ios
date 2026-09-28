import SwiftUI

/// A session in the inbox: a small mark for its state, its title and when you last asked it
/// something, what it's doing or asking, and where it is. Only what wants you is bold; an idle
/// session has no mark at all.
struct SessionRowView: View {
    let row: SessionRow
    /// More than one Mac is linked, so each row says which it's on.
    let showDevice: Bool
    /// The list shows every project, so each row says which it's in.
    var showProject = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusMark(status: row.status, stalled: row.stalled)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.body.weight(wantsYou ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Clock.ago(row.lastPromptAt, now: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let detail = row.detail, !detail.isEmpty {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Clock.text(detail, now: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Text(place)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .opacity(row.deviceOnline ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var wantsYou: Bool {
        row.status == .needs || row.status == .error || row.status == .unread
    }

    /// Where it is: the project and branch, and the Mac when there's more than one.
    private var place: String {
        var parts: [String] = []
        if showDevice { parts.append(Names.short(row.deviceName)) }
        if showProject { parts.append(row.project) }
        if let branch = row.branch, !branch.isEmpty { parts.append(branch) }
        return parts.joined(separator: " · ")
    }
}

/// A session's state as a small dot: orange when it needs you, red on an error, blue (breathing)
/// while it works, the accent color when it's your turn, and nothing when it's idle.
struct StatusMark: View {
    let status: Status
    let stalled: Bool

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .working && !stalled)
            .frame(width: 10)
            .accessibilityLabel(label)
    }

    private var color: Color {
        if stalled { return .orange }
        switch status {
        case .needs: return .orange
        case .error: return .red
        case .working: return .blue
        case .unread: return .accentColor
        case .idle, .stopped: return .clear
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
