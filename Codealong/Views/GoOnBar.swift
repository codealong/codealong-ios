import SwiftUI

/// What going on to the next session that waits on you does to the one you go on from: a swipe
/// across the conversation, Next over the box, Go to next in the menu and ⌘] all do it. You pick it
/// over the reply box, and it's kept for every session after.
enum SwipeOn: String, CaseIterable, Identifiable {
    case seen, done, archive

    var id: Self { self }

    var label: String {
        switch self {
        case .seen: "Mark as seen"
        case .done: "Mark as done"
        case .archive: "Archive"
        }
    }

    /// As the session's menu draws the same.
    var symbol: String {
        switch self {
        case .seen: "eye"
        case .done: "checkmark.circle"
        case .archive: "archivebox"
        }
    }
}

/// What going on from a session does to it: what you picked (`SwipeOn`), where that applies. A
/// session you've replied to or answered here is left to the turn you gave it, one at work is left
/// to its work (Mark as done would only be held by it), and one that waits on you to allow a call
/// or answer its questions comes round again after the rest, as it did before there was a choice.
enum Going: Equatable {
    case seen, done, archive
    /// Nothing more is done to it: you've replied here, or there's nothing in it to mark seen.
    case on
    /// It's at work, so Mark as done or Archive leaves it be.
    case working
    /// It waits on an answer from you, so it comes round again after the rest.
    case later

    static func of(_ pick: SwipeOn, row: SessionRow?, pending: Pending?, acted: Bool) -> Going {
        guard let row, !acted else { return .on }
        // Before its Mac has said what it waits on, its status says it waits on something.
        if pending != nil || (row.status == .needs && !row.seenable) { return .later }
        switch pick {
        case .seen: return row.seenable ? .seen : .on
        case .done: return row.status == .working ? .working : .done
        case .archive: return row.status == .working ? .working : .archive
        }
    }

    /// What the bar says it does.
    var words: String {
        switch self {
        case .seen: "Swipe to mark as seen"
        case .done: "Swipe to mark as done"
        case .archive: "Swipe to archive"
        case .on: "Swipe to go on"
        case .working: "It’s working: swipe to go on"
        case .later: "Swipe to come back to it later"
        }
    }

    var symbol: String {
        switch self {
        case .seen: SwipeOn.seen.symbol
        case .done: SwipeOn.done.symbol
        case .archive: SwipeOn.archive.symbol
        case .on, .working: "arrow.forward"
        case .later: "clock.arrow.circlepath"
        }
    }

    /// What going on does to this one, for VoiceOver on Next.
    var spoken: String? {
        switch self {
        case .seen: "Marks this one seen"
        case .done: "Marks this one done"
        case .archive: "Archives this one"
        case .on: nil
        case .working: "Leaves this one to its work"
        case .later: "This one comes round again after the rest"
        }
    }
}

/// Over the reply box while another session waits on you: what going on to it does to this one,
/// and the session it goes to. The first line says what a swipe does here, and its menu picks what
/// going on does from then on (`SwipeOn`); under it, the next session, which a tap goes on to as
/// the swipe does.
struct GoOnBar: View {
    let next: SessionRow
    let more: Int
    let showDevice: Bool
    /// The inbox shows every project, so it says which it's in.
    let showProject: Bool
    let going: Going
    @Binding var pick: SwipeOn
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Where it is goes under what the swipe does when the line can't hold both in full: a
            // menu's label otherwise gave up its room, and what the swipe does was cut short.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    choice.fixedSize()
                    Spacer(minLength: 8)
                    placeText.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    choice
                    placeText
                }
            }
            Button(action: action) {
                HStack(spacing: 10) {
                    StatusMark(status: next.status, stalled: next.stalled, waiting: next.waitsInBackground)
                    HStack(spacing: 5) {
                        if let emblem = next.emblem {
                            EmblemView(emblem: emblem, size: 15)
                        }
                        Text(next.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text("Next")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Next: \(next.title)")
            .accessibilityHint([going.spoken, more > 0 ? "\(more) more wait on you after it" : "The last that waits on you"].compactMap { $0 }.joined(separator: ". "))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// What a swipe does here, and the menu that picks what going on does.
    private var choice: some View {
        Menu {
            Picker("When you go on to the next", selection: $pick) {
                ForEach(SwipeOn.allCases) { c in
                    Label(c.label, systemImage: c.symbol).tag(c)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: going.symbol)
                Text(going.words)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .contentShape(.rect)
        }
        // Gray, under the session it goes to: a menu's label takes the tint, which washed out.
        .tint(.secondary)
        .accessibilityLabel(going.words)
        .accessibilityHint("Picks what going on to the next does. Now: \(pick.label)")
    }

    private var placeText: some View {
        Text(place)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    /// Where the next is, and how many wait after it.
    private var place: String {
        var parts: [String] = []
        if showDevice { parts.append(Names.short(next.deviceName)) }
        if showProject { parts.append(next.project) }
        if more > 0 { parts.append("\(more) more after it") }
        if parts.isEmpty { parts.append("The last that waits on you") }
        return parts.joined(separator: " · ")
    }
}
