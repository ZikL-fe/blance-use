import SwiftUI

struct StationDetailView: View {
    @Environment(StationStore.self) private var store
    let station: RelayStation

    @State private var showEditSheet = false
    @State private var showRateSheet = false
    @State private var quickRateText = ""

    private var liveStation: RelayStation {
        store.effectiveStations.first(where: { $0.id == station.id }) ?? station
    }

    private var snapshot: StationUsageSnapshot? {
        store.snapshots[liveStation.id]
    }

    private var isLoading: Bool {
        store.refreshingStationIDs.contains(liveStation.id)
    }

    var body: some View {
        ZStack {
            LiquidAmbientBackground(accent: liveStation.accentColor)

            ScrollView {
                LazyVStack(spacing: 16) {
                    TimeRangeBar(
                        selection: Binding(
                            get: { store.selectedRange },
                            set: { store.selectedRange = $0 }
                        ),
                        onRangeChanged: { newRange in
                            store.updateRange(newRange)
                        }
                    )

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("正在同步 \(store.selectedRange.preset.title) 数据...")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .liquidGlassPill(interactive: false)
                        .transition(.opacity)
                    }

                    if let err = snapshot?.errorMessage {
                        errorCard(err)
                    }

                    stationHeroCard

                    if let snap = snapshot {
                        SpendTrendChartCard(
                            title: store.selectedRange.isSingleDay ? "今日分时消耗" : "每日消耗明细",
                            points: snap.dailyPoints,
                            isHourly: store.selectedRange.isSingleDay,
                            currency: store.displayCurrency,
                            accentColor: liveStation.accentColor,
                            provider: liveStation.provider
                        )

                        if snap.periodInputTokens > 0 || snap.periodOutputTokens > 0 || snap.periodCacheTokens > 0 {
                            tokenCompositionCard(snap)
                        }

                        ModelBreakdownListCard(
                            title: liveStation.provider.breakdownTitle,
                            models: snap.modelStats,
                            currency: store.displayCurrency,
                            maxItems: 12,
                            provider: liveStation.provider
                        )

                        dailyLedgerCard(snap.dailyPoints)
                    } else {
                        ProgressView("正在同步中转站数据...")
                            .padding(40)
                            .frame(maxWidth: .infinity)
                            .liquidGlassCard(cornerRadius: 24)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable {
                await store.refreshStation(liveStation)
            }
        }
        .navigationTitle(liveStation.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        Task { await store.refreshStation(liveStation) }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }

                    if !store.isDemoMode {
                        Button {
                            showEditSheet = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            StationEditorSheet(editingStation: liveStation)
        }
        .sheet(isPresented: $showRateSheet) {
            quickRateEditorSheet
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Sections

    private var stationHeroCard: some View {
        let costUSD = snapshot?.periodCostUSD ?? 0
        let convertedCost = liveStation.convertToDisplayCurrency(costUSD)
        let balUSD = snapshot?.balanceUSD
        let balConv = balUSD.map { liveStation.convertToDisplayCurrency($0) }

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ProviderBadge(provider: liveStation.provider)
                Button {
                    if !store.isDemoMode {
                        quickRateText = ValueFormatter.rate(liveStation.exchangeRate)
                        showRateSheet = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        ExchangeRatePill(rate: liveStation.exchangeRate, currency: store.displayCurrency, provider: liveStation.provider)
                        if !store.isDemoMode {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text(snapshot?.accountLabel ?? liveStation.hostLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(store.selectedRange.preset.title)折算消耗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ValueFormatter.currency(convertedCost, currency: store.displayCurrency))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("原始 \(liveStation.provider.formatRawAmount(costUSD)) × \(ValueFormatter.rate(liveStation.exchangeRate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if let balConv, let balUSD {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("剩余余额")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(ValueFormatter.currency(balConv, currency: store.displayCurrency))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color(hex: "#10B981"))
                            .monospacedDigit()
                        Text(liveStation.provider.formatRawAmount(balUSD))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#10B981").opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            HStack(spacing: 10) {
                compactPill(title: liveStation.provider.requestMetricName, value: ValueFormatter.requests(snapshot?.periodRequests ?? 0))
                if liveStation.provider != .remail {
                    compactPill(title: "Tokens", value: ValueFormatter.tokens(snapshot?.periodTokens ?? 0))
                }
                if let usedLife = snapshot?.lifetimeUsedUSD {
                    compactPill(
                        title: "历史总计",
                        value: ValueFormatter.currency(liveStation.convertToDisplayCurrency(usedLife), currency: store.displayCurrency, compact: true)
                    )
                } else {
                    compactPill(title: "站点域名", value: liveStation.hostLabel)
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 26, tint: liveStation.accentColor.opacity(0.10))
    }

    private func compactPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tokenCompositionCard(_ snap: StationUsageSnapshot) -> some View {
        let total = max(Int64(1), snap.periodInputTokens + snap.periodOutputTokens + snap.periodCacheTokens)
        let inRatio = Double(snap.periodInputTokens) / Double(total)
        let outRatio = Double(snap.periodOutputTokens) / Double(total)
        let cacheRatio = Double(snap.periodCacheTokens) / Double(total)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Token 构成明细")
                .font(.headline.weight(.semibold))

            GeometryReader { geo in
                HStack(spacing: 3) {
                    if inRatio > 0 {
                        Capsule().fill(Color(hex: "#38BDF8"))
                            .frame(width: max(6, geo.size.width * CGFloat(inRatio)))
                    }
                    if outRatio > 0 {
                        Capsule().fill(Color(hex: "#A855F7"))
                            .frame(width: max(6, geo.size.width * CGFloat(outRatio)))
                    }
                    if cacheRatio > 0 {
                        Capsule().fill(Color(hex: "#10B981"))
                            .frame(width: max(6, geo.size.width * CGFloat(cacheRatio)))
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 12) {
                tokenLegend("输入", ValueFormatter.tokens(snap.periodInputTokens), Color(hex: "#38BDF8"))
                tokenLegend("输出", ValueFormatter.tokens(snap.periodOutputTokens), Color(hex: "#A855F7"))
                tokenLegend("缓存", ValueFormatter.tokens(snap.periodCacheTokens), Color(hex: "#10B981"))
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private func tokenLegend(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailyLedgerCard(_ points: [UsageBucketPoint]) -> some View {
        let nonZero = points.filter { $0.convertedCost > 0 || $0.requests > 0 }.reversed()
        let rows = Array(nonZero)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.selectedRange.isSingleDay ? "分时账单记录" : "每日账单记录")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("\(rows.count) 条有消耗")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Text("所选周期内暂无消耗记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ForEach(rows) { pt in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.selectedRange.isSingleDay ? DateFormatters.hourLabel.string(from: pt.date) : DateFormatters.fullDate.string(from: pt.date))
                                .font(.subheadline.weight(.medium))
                            Text(liveStation.provider == .remail
                                 ? "\(ValueFormatter.requests(pt.requests)) 笔订单"
                                 : "\(ValueFormatter.requests(pt.requests)) 次请求 · \(ValueFormatter.tokens(pt.totalTokens)) Tokens")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ValueFormatter.currency(pt.convertedCost, currency: store.displayCurrency))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                            Text(liveStation.provider.formatRawAmount(pt.costUSD))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 6)

                    if pt.id != rows.last?.id {
                        Divider().opacity(0.22)
                    }
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private func errorCard(_ message: String) -> some View {
        let isFallback = snapshot?.isUsingFallbackCache == true
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isFallback ? "clock.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(isFallback ? "已使用最近缓存数据兜底" : "数据同步遇到问题")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.isDemoMode {
                Button("编辑") { showEditSheet = true }
                    .font(.caption.weight(.semibold))
                    .glassButtonStyle()
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18, tint: Color.orange.opacity(0.15))
    }

    private var quickRateEditorSheet: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: liveStation.accentColor)
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("设置「\(liveStation.name)」汇率比例")
                            .font(.headline)
                        Text("站点内每 \(liveStation.provider.unitShortPrefix) 折合多少 \(store.displayCurrency.rawValue) (\(store.displayCurrency.symbol))：")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("\(liveStation.provider.unitShortPrefix) = \(store.displayCurrency.symbol)")
                                .font(.title3.weight(.bold))
                            TextField("汇率比例", text: $quickRateText)
                                .keyboardType(.decimalPad)
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .textFieldStyle(.roundedBorder)
                        }

                        let previewRate = Double(quickRateText) ?? liveStation.exchangeRate
                        let sampleUnit: Double = liveStation.provider.usesPointsUnit ? 100.0 : 10.0
                        Text("预览：\(liveStation.provider.formatRawAmount(sampleUnit)) ≈ \(ValueFormatter.currency(sampleUnit * previewRate, currency: store.displayCurrency))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(liveStation.accentColor)

                        HStack(spacing: 8) {
                            ForEach(liveStation.provider.quickExchangeRatePresets, id: \.self) { preset in
                                Button(ValueFormatter.rate(preset)) {
                                    quickRateText = ValueFormatter.rate(preset)
                                }
                                .font(.caption.weight(.semibold))
                                .glassButtonStyle()
                            }
                        }
                    }
                    .padding(18)
                    .liquidGlassCard(cornerRadius: 22)
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("调整汇率比例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showRateSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let val = Double(quickRateText), val > 0 {
                            store.updateExchangeRate(for: liveStation.id, newRate: val)
                        }
                        showRateSheet = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
