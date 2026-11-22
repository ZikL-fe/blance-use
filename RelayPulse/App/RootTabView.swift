import SwiftUI

struct RootTabView: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                TabView {
                    Tab("总览", systemImage: "chart.pie.fill") {
                        OverviewView()
                    }
                    Tab("利润", systemImage: "chart.line.uptrend.xyaxis") {
                        ProfitLedgerView()
                    }
                    Tab("中转站", systemImage: "server.rack") {
                        StationsListView()
                    }
                    Tab("设置", systemImage: "gearshape.fill") {
                        SettingsView()
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            } else {
                TabView {
                    OverviewView()
                        .tabItem {
                            Label("总览", systemImage: "chart.pie.fill")
                        }
                    ProfitLedgerView()
                        .tabItem {
                            Label("利润", systemImage: "chart.line.uptrend.xyaxis")
                        }
                    StationsListView()
                        .tabItem {
                            Label("中转站", systemImage: "server.rack")
                        }
                    SettingsView()
                        .tabItem {
                            Label("设置", systemImage: "gearshape.fill")
                        }
                }
            }
        }
        .tint(Color(hex: "#38BDF8"))
        .task {
            if !store.effectiveStations.isEmpty {
                await store.refreshAll()
            }
            await DailySettlementScheduler.shared.checkAndCatchUpOnForeground()
        }
    }
}
