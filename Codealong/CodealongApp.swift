import SwiftUI

@main
struct CodealongApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            InboxView()
                .environment(store)
        }
        // Connected only while the app is open: iOS suspends it in the background anyway, and a
        // reconnect is quick, with the last feeds on screen meanwhile.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.start()
            case .background: store.stop()
            default: break
            }
        }
    }
}
