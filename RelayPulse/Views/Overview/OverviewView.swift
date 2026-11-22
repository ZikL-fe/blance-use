import SwiftUI

struct OverviewView: View {
    @Environment(StationStore.self) private var store
    @State private var showAddStation = false

    private var metrics: OverviewMetrics {
        store.overviewMetrics
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#38BDF8"))

                ScrollView {
                    LazyVStack(spacing: 18) {
                        if store.isDemoMode {
                            demoBanner
                        }

                        if let notice = store.fallbackNoticeBanner {
                            fallbackBanner(notice)
                        }

                        TimeRangeBar(
                            selection: Binding(
                                get: { store.selectedRange },
                                set: { store.selectedRange = $0 }
                            ),
                            onRangeChanged: { newRange in
                                store.updateRange(newRange)
                            }
                        )

                        if store.isRefreshingAll && !store.effectiveStations.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("正在同步 \(store.selectedRange.preset.title) 数据...")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .liquidGlassPill(interactive: false)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }

                        if store.effectiveStations.isEmpty {
                            emptyStateCard
                        } else {
                            heroSummaryCard
                            SpendTrendChartCard(
                                title: store.selectedRange.isSingleDay ? "今日分时消耗趋势" : "多站点每日消耗趋势",
                                points: metrics.combinedSeries,
                                isHourly: store.selectedRange.isSingleDay,
                                currency: store.displayCurrency,
                                accentColor: Color(hex: "#38BDF8")
                            )

                            if metrics.stationBreakdowns.count > 1 {
                                StationShareDonutCard(
                                    breakdowns: metrics.stationBreakdowns,
                                    totalConverted: metrics.totalConvertedCost,
                                    currency: store.displayCurrency
                                )
                            }

                            perStationSection

                            if !metrics.topModels.isEmpty {
                                ModelBreakdownListCard(
                                    title: "全站模型 / 项目消耗排行",
                                    models: metrics.topModels,
                                    currency: store.displayCurrency
                                )
                            }
                        }

                        if let updated = store.lastUpdatedAt {
                            Text("最后同步：\(DateFormatters.shortTime.string(from: updated))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
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
            .navigationTitle("消耗总览")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await store.refreshAll() }
                        } label: {
                            if store.isRefreshingAll {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(store.isRefreshingAll)

                        Button {
                            showAddStation = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddStation) {
                StationEditorSheet(editingStation: nil)
            }
            .navigationDestination(for: RelayStation.self) { station in
                StationDetailView(station: station)
            }
        }
    }

    // MARK: - Subviews

    private func fallbackBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(Color(hex: "#F59E0B"))
            VStack(alignment: .leading, spacing: 2) {
                Text("已启用缓存数据兜底")
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation {
                    store.fallbackNoticeBanner = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlassCard(cornerRadius: 18, tint: Color(hex: "#F59E0B").opacity(0.16))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color(hex: "#F59E0B"))
            VStack(alignment: .leading, spacing: 1) {
                Text("当前为演示数据模式")
                    .font(.caption.weight(.semibold))
                Text("添加真实中转站后将自动切换为实时统计")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") {
                withAnimation {
                    store.disableDemoMode()
                }
            }
            .font(.caption.weight(.semibold))
            .glassButtonStyle()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlassCard(cornerRadius: 18, tint: Color(hex: "#F59E0B").opacity(0.14))
    }

    private var emptyStateCard: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#38BDF8").opacity(0.32), Color(hex: "#A855F7").opacity(0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 82, height: 82)
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#38BDF8"), Color(hex: "#818CF8")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("尚未添加中转站")
                    .font(.title3.weight(.bold))
                Text("支持同时接入多个 Sub2API、NewAPI 与 ReMail (remail.best) 平台，自动按各站汇率折算消耗，一站掌握每日、7日、30日及自定义周期的真实花费。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 10) {
                Button {
                    showAddStation = true
                } label: {
                    Label("添加第一个中转站", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassButtonStyle(prominent: true)
                .tint(Color(hex: "#38BDF8"))

                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        store.enableDemoMode()
                    }
                } label: {
                    Label("先体验演示数据界面", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .glassButtonStyle()
            }
        }
        .padding(24)
        .liquidGlassCard(cornerRadius: 28)
        .padding(.top, 12)
    }

    private var heroSummaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("\(store.selectedRange.preset.title)折算总消耗")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(store.displayCurrency.rawValue)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#38BDF8").opacity(0.18), in: Capsule())
                            .foregroundStyle(Color(hex: "#38BDF8"))
                    }

                    Text(ValueFormatter.currency(metrics.totalConvertedCost, currency: store.displayCurrency))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("原始站点额度累计 \(ValueFormatter.usd(metrics.totalCostUSD))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if metrics.errorStationCount > 0 {
                            Text("· \(metrics.errorStationCount) 站同步异常")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("活跃中转站")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(metrics.activeStationCount)")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: "#38BDF8"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .liquidGlassPill(interactive: false)
            }

            // 3-column mini KPI strip
            HStack(spacing: 10) {
                heroMetricTile(
                    icon: "wallet.bifold.fill",
                    iconColor: Color(hex: "#10B981"),
                    label: "总剩余余额",
                    primary: ValueFormatter.currency(metrics.totalRemainingConverted, currency: store.displayCurrency, compact: true),
                    secondary: ValueFormatter.usd(metrics.totalRemainingUSD)
                )

                heroMetricTile(
                    icon: "bolt.horizontal.fill",
                    iconColor: Color(hex: "#F59E0B"),
                    label: "总请求数",
                    primary: ValueFormatter.requests(metrics.totalRequests),
                    secondary: "次调用"
                )

                heroMetricTile(
                    icon: "text.word.spacing",
                    iconColor: Color(hex: "#A855F7"),
                    label: "总 Tokens",
                    primary: ValueFormatter.tokens(metrics.totalTokens),
                    secondary: "累计吞吐"
                )
            }
        }
        .padding(20)
        .liquidGlassCard(cornerRadius: 28, tint: Color(hex: "#38BDF8").opacity(0.08))
    }

    private func heroMetricTile(
        icon: String,
        iconColor: Color,
        label: String,
        primary: String,
        secondary: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(primary)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(secondary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var perStationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(
                title: "各中转站消耗情况",
                subtitle: "已按各自汇率折算为 \(store.displayCurrency.rawValue)，点击查看站点明细",
                trailingText: "\(metrics.stationBreakdowns.count) 站"
            )

            ForEach(metrics.stationBreakdowns) { item in
                NavigationLink(value: item.station) {
                    stationOverviewRow(item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stationOverviewRow(_ item: StationBreakdownItem) -> some View {
        let isLoading = store.refreshingStationIDs.contains(item.station.id)
        let hasError = item.snapshot?.errorMessage != nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(item.station.accentColor)
                    .frame(width: 5, height: 38)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.station.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if item.snapshot?.isUsingFallbackCache == true {
                            Text("缓存兜底")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: "#F59E0B"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "#F59E0B").opacity(0.16), in: Capsule())
                        }
                        StatusDot(isLoading: isLoading, hasError: hasError)
                    }
                    HStack(spacing: 6) {
                        ProviderBadge(provider: item.station.provider)
                        ExchangeRatePill(rate: item.station.exchangeRate, currency: store.displayCurrency, provider: item.station.provider)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(ValueFormatter.currency(item.convertedCost, currency: store.displayCurrency))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("原始 \(item.station.provider.formatRawAmount(item.costUSD))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // Proportional spend bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [item.station.accentColor, item.station.accentColor.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(item.convertedCost > 0 ? 8 : 0, geo.size.width * CGFloat(item.share)))
                }
            }
            .frame(height: 5)

            HStack(spacing: 12) {
                if let balConv = item.balanceConverted, let balUSD = item.balanceUSD {
                    Label(
                        "余额 \(ValueFormatter.currency(balConv, currency: store.displayCurrency)) (\(item.station.provider.formatRawAmount(balUSD)))",
                        systemImage: "creditcard"
                    )
                    .lineLimit(1)
                } else {
                    Label("余额 --", systemImage: "creditcard")
                }

                Spacer()

                if item.station.provider == .remail {
                    Text("\(ValueFormatter.requests(item.requests)) 单")
                        .lineLimit(1)
                } else {
                    Text("\(ValueFormatter.requests(item.requests)) 次 · \(ValueFormatter.tokens(item.tokens))")
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if let err = item.snapshot?.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .lineLimit(2)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22, interactive: true)
    }
}
