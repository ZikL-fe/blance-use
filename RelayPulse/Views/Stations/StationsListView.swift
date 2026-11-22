import SwiftUI

struct StationsListView: View {
    @Environment(StationStore.self) private var store
    @State private var showAddSheet = false
    @State private var editingStation: RelayStation? = nil
    @State private var stationPendingDelete: RelayStation? = nil

    private var sub2Count: Int {
        store.effectiveStations.filter { $0.provider == .sub2api }.count
    }

    private var newAPICount: Int {
        store.effectiveStations.filter { $0.provider == .newAPI }.count
    }

    private var remailCount: Int {
        store.effectiveStations.filter { $0.provider == .remail }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#A855F7"))

                ScrollView {
                    LazyVStack(spacing: 14) {
                        // Summary pill bar
                        HStack(spacing: 8) {
                            statMiniPill(title: "总站点", value: "\(store.effectiveStations.count)", color: Color(hex: "#38BDF8"))
                            statMiniPill(title: "Sub2API", value: "\(sub2Count)", color: RelayProviderType.sub2api.badgeColor)
                            statMiniPill(title: "NewAPI", value: "\(newAPICount)", color: RelayProviderType.newAPI.badgeColor)
                            statMiniPill(title: "ReMail", value: "\(remailCount)", color: RelayProviderType.remail.badgeColor)
                        }

                        if store.effectiveStations.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text("还没有添加中转站")
                                    .font(.headline)
                                Text("点击下方按钮登录你的 Sub2API 或 NewAPI 账号，支持多站点并行统计与独立汇率换算。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button {
                                    showAddSheet = true
                                } label: {
                                    Label("添加中转站", systemImage: "plus")
                                        .font(.headline)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                }
                                .glassButtonStyle(prominent: true)
                                .tint(Color(hex: "#A855F7"))
                            }
                            .padding(28)
                            .frame(maxWidth: .infinity)
                            .liquidGlassCard(cornerRadius: 26)
                            .padding(.top, 18)
                        } else {
                            if let primary = store.primarySalesStation {
                                GlassSectionHeader(
                                    title: "主站点（销售额来源）",
                                    subtitle: "每日利润结算时读取该站点的消耗额度作为今日销售额"
                                )
                                stationCard(primary)
                            }

                            if !store.costChannelStations.isEmpty {
                                GlassSectionHeader(
                                    title: "上游成本渠道",
                                    subtitle: "计入每日上游渠道总成本与消耗总览",
                                    trailingText: "\(store.costChannelStations.count) 站"
                                )
                                ForEach(store.costChannelStations) { station in
                                    stationCard(station)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .refreshable {
                    await store.refreshAll()
                }
            }
            .navigationTitle("中转站管理")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("添加站点", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                StationEditorSheet(editingStation: nil)
            }
            .sheet(item: $editingStation) { station in
                StationEditorSheet(editingStation: station)
            }
            .alert("删除中转站", isPresented: Binding(
                get: { stationPendingDelete != nil },
                set: { if !$0 { stationPendingDelete = nil } }
            )) {
                Button("取消", role: .cancel) { stationPendingDelete = nil }
                Button("确认删除", role: .destructive) {
                    if let target = stationPendingDelete {
                        store.deleteStation(target)
                    }
                    stationPendingDelete = nil
                }
            } message: {
                Text("将删除「\(stationPendingDelete?.name ?? "")」及其保存在钥匙串中的登录凭据。")
            }
            .navigationDestination(for: RelayStation.self) { station in
                StationDetailView(station: station)
            }
        }
    }

    private func statMiniPill(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .liquidGlassCard(cornerRadius: 18)
    }

    private func stationCard(_ station: RelayStation) -> some View {
        let snap = store.snapshots[station.id]
        let isLoading = store.refreshingStationIDs.contains(station.id)
        let periodConv = station.convertToDisplayCurrency(snap?.periodCostUSD ?? 0)
        let balConv = snap?.balanceUSD.map { station.convertToDisplayCurrency($0) }

        return VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: station) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Circle()
                            .fill(station.accentColor)
                            .frame(width: 12, height: 12)
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(station.name)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if !station.isEnabled {
                                    Text("已暂停")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.2), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(station.hostLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        StatusDot(isLoading: isLoading, hasError: snap?.errorMessage != nil)
                    }

                    HStack(spacing: 6) {
                        if station.role == .primarySales {
                            Label("主站点·销售", systemImage: "crown.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(hex: "#EC4899"))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(hex: "#EC4899").opacity(0.15), in: Capsule())
                        }
                        ProviderBadge(provider: station.provider)
                        ExchangeRatePill(rate: station.exchangeRate, currency: store.displayCurrency, provider: station.provider)
                        Label(station.provider == .remail ? "API Key" : station.authMethod.shortName, systemImage: station.authMethod.iconName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    Divider().opacity(0.25)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(store.selectedRange.preset.title)消耗")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(ValueFormatter.currency(periodConv, currency: store.displayCurrency))
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text(station.provider.formatRawAmount(snap?.periodCostUSD ?? 0))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("当前余额")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let balConv, let balUSD = snap?.balanceUSD {
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Text(ValueFormatter.currency(balConv, currency: store.displayCurrency))
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(Color(hex: "#10B981"))
                                    Text(station.provider.formatRawAmount(balUSD))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .monospacedDigit()
                            } else {
                                Text("--")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if !store.isDemoMode {
                HStack(spacing: 8) {
                    Button {
                        Task { await store.refreshStation(station) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .glassButtonStyle()

                    Button {
                        editingStation = station
                    } label: {
                        Label("编辑 / 汇率", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.medium))
                    }
                    .glassButtonStyle()

                    Spacer()

                    Button {
                        store.toggleStationEnabled(station)
                    } label: {
                        Image(systemName: station.isEnabled ? "eye.fill" : "eye.slash")
                            .font(.caption.weight(.semibold))
                    }
                    .glassButtonStyle()
                    .accessibilityLabel(station.isEnabled ? "移出总览" : "加入总览")

                    Button(role: .destructive) {
                        stationPendingDelete = station
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .glassButtonStyle()
                }
            }
        }
        .padding(16)
        .opacity(station.isEnabled ? 1.0 : 0.65)
        .liquidGlassCard(cornerRadius: 22)
    }
}
