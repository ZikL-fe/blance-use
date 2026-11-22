import SwiftUI

@main
struct RelayPulseApp: App {
    @State private var store = StationStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
        }
    }
}
