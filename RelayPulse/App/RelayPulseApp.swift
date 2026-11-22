import SwiftUI

@main
struct RelayPulseApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = StationStore()
    @State private var ledger = ProfitLedgerStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(ledger)
                .onAppear {
                    DailySettlementScheduler.shared.configure(stationStore: store, ledgerStore: ledger)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task {
                            await DailySettlementScheduler.shared.checkAndCatchUpOnForeground()
                        }
                    case .background:
                        DailySettlementScheduler.shared.scheduleNextBackgroundTask()
                    default:
                        break
                    }
                }
        }
    }
}
