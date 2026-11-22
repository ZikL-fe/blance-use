import SwiftUI

@main
struct RelayPulseApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = StationStore()
    @State private var ledger = ProfitLedgerStore()
    @State private var auditStore = AuditLogStore.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(ledger)
                .environment(auditStore)
                .onAppear {
                    auditStore.pruneEntries()
                    auditStore.log(.info, category: .system, message: "应用启动完成")
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
