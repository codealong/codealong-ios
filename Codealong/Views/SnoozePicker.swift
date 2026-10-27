import SwiftUI

/// What Pick a time… in a Snooze menu snoozes: the sheet that asks (`SnoozePicker`) shows for it,
/// and hands `run` the time picked.
struct SnoozePick: Identifiable {
    let id: String
    /// The sheet's title: Snooze for a session, Snooze review for a PR.
    let title: String
    let run: @MainActor (Date) -> Void
}

/// Any day and time to snooze to, as Pick a time… on the Mac asks for one (SnoozeDialog.tsx): it
/// opens on the next morning, the menus' time for tomorrow, and says when it would come back as
/// they do.
struct SnoozePicker: View {
    let pick: SnoozePick
    @Environment(\.dismiss) private var dismiss
    @State private var until = Snooze.For.morning.picked().until

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Until", selection: $until, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                } footer: {
                    Text(until > .now ? "Until \(Snooze.words(until))" : "That time has passed.")
                }
            }
            .navigationTitle(pick.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Snooze") {
                        pick.run(until)
                        dismiss()
                    }
                    .disabled(until <= .now)
                }
            }
        }
    }
}
