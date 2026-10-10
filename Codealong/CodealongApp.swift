import SwiftUI

@main
struct CodealongApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            QuickView()
                .environment(store)
                .onOpenURL { store.open($0) }
        }
        // Connected while the app is open and for a little while after (`Store.leave`): iOS
        // suspends it in the background anyway, and a reconnect is quick, with the last feeds on
        // screen meanwhile.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.start()
            case .background: store.leave()
            default: break
            }
        }
    }
}
