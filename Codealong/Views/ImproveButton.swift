import SwiftUI

/// The lightbulb on every screen: Improve Codealong (`Store.improveCodealong`), which takes a
/// picture of the screen it's pressed on and hands the list the session to start. In a toolbar
/// it's the bare symbol; `glass` is the list's own header button. It lights orange while a
/// session is being improved, and does nothing without a Mac to start on.
struct ImproveButton: View {
    @Environment(Store.self) private var store
    var glass = false

    var body: some View {
        if glass {
            button
                .buttonStyle(.glass)
        } else {
            button
        }
    }

    private var button: some View {
        Button { store.improveCodealong() } label: {
            if glass {
                Image(systemName: "lightbulb")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 32)
            } else {
                Image(systemName: "lightbulb")
            }
        }
        .tint(store.improving == nil ? nil : .orange)
        .disabled(store.devices.isEmpty)
        .accessibilityLabel("Improve Codealong")
        .accessibilityHint("Starts a session that improves Codealong itself, with a picture of this screen")
    }
}
