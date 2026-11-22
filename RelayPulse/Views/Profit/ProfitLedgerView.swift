import Charts
import SwiftUI

private enum ProfitSummaryWindow: String, CaseIterable, Identifiable {
    case today = "今日"
    case days7 = "近7天"
    case days30 = "近30天"
    case custom = "自定义"
    case all = "全部"

    var id: String { rawValue }
}

private enum ProfitChartMode: String, CaseIterable, Identifiable {
    case netProfit = "净利润"
    case revVsCost = "销售/成本"

    var id: String { rawValue }
}

struct ProfitLedgerView: View {
    @Environment(StationStore.self) private var store
    @Environment(ProfitLedgerStore.self) private var ledger

    @State private var summaryWindow: ProfitSummaryWindow = .days7
    @State private var customFilterStart: Date = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
    @State private var customFilterEnd: Date = Date()
    @State private var showCustomFilterSheet: Bool = false

    @State private var chartMode: ProfitChartMode = .netProfit
    @State private var selectedChartDateKey: String? = nil

    @State private var showFixedCostSheet = false
    @State private var showScheduleSheet = false
    @State private var showBackfillSheet = false
    @State private var showAddPrimarySalesSheet = false

    @State private var backfillStartDate: Date = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var backfillEndDate: Date = Date()
    @State private var backfillOverwriteExisting: Bool = true

    private var allRecords: [DailyProfitRecord] {
        ledger.effectiveRecords(isDemoMode: store.isDemoMode)
    }

    private var filteredRecords: [DailyProfitRecord] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch summaryWindow {
        case .today:
            let todayKey = DateFormatters.apiDay.string(from: today)
            return allRecords.filter { $0.dateKey == todayKey }
        case .days7:
            let cutoff = cal.date(byAdding: .day, value: -6, to: today) ?? today
            return allRecords.filter { $0.date >= cutoff }
        case .days30:
            let cutoff = cal.date(byAdding: .day, value: -29, to: today) ?? today
            return allRecords.filter { $0.date >= cutoff }
        case .custom:
            let s = cal.startOfDay(for: min(customFilterStart, customFilterEnd))
            let e = cal.startOfDay(for: max(customFilterStart, customFilterEnd))
            return allRecords.filter { rec in
                let d = cal.startOfDay(for: rec.date)
                return d >= s && d <= e
            }
        case .all:
            return allRecords
        }
    }

    private var activeWindowSubtitle: String? {
        guard summaryWindow == .custom else { return nil }
        let cal = Calendar.current
        let s = cal.startOfDay(for: min(customFilterStart, customFilterEnd))
        let e = cal.startOfDay(for: max(customFilterStart, customFilterEnd))
        let days = max(1, (cal.dateComponents([.day], from: s, to: e).day ?? 0) + 1)
        return "\(DateFormatters.monthDay.string(from: s)) - \(DateFormatters.monthDay.string(from: e)) · 共 \(days) 天"
    }

    private var chartRecords: [DailyProfitRecord] {
        let base = summaryWindow == .today ? Array(allRecords.prefix(7)) : filteredRecords
        return base.sorted { $0.dateKey < $1.dateKey }
    }

    private var totalRevenue: Double { filteredRecords.reduce(0) { $0 + $1.revenue } }
    private var totalChannelCost: Double { filteredRecords.reduce(0) { $0 + $1.totalChannelCost } }
    private var totalFixedCost: Double { filteredRecords.reduce(0) { $0 + $1.fixedCost } }
    private var totalCost: Double { filteredRecords.reduce(0) { $0 + $1.totalCost } }
    private var totalNetProfit: Double { filteredRecords.reduce(0) { $0 + $1.netProfit } }
    private var overallMargin: Double { totalRevenue > 0 ? totalNetProfit / totalRevenue : 0 }

    private var activeChartRecord: DailyProfitRecord? {
        guard let key = selectedChartDateKey else { return nil }
        return chartRecords.first(where: { $0.dateKey == key })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: totalNetProfit >= 0 ? Color(hex: "#10B981") : Color(hex: "#F43F5E"))

                ScrollView {
                    LazyVStack(spacing: 16) {
                        windowSelectorBar
                        profitHeroCard
                        configStatusRow
                        if !chartRecords.isEmpty {
                            profitTrendChartCard
                        }
                        ledgerHistorySection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("利润账本")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            showBackfillSheet = true
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .accessibilityLabel("补录历史日期")

                        ShareLink(
                            item: ledger.exportCSV(isDemoMode: store.isDemoMode),
                            preview: SharePreview("RelayPulse 每日利润账本.csv")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(allRecords.isEmpty)
                    }
                }
            }
            .navigationDestination(for: DailyProfitRecord.self) { record in
                DailyProfitDetailView(record: record)
            }
            .sheet(isPresented: $showFixedCostSheet) {
                FixedCostEditorSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showScheduleSheet) {
                ScheduleSettingsSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showAddPrimarySalesSheet) {
                StationEditorSheet(editingStation: store.primarySalesStation, defaultRole: .primarySales)
            }
            .sheet(isPresented: $showBackfillSheet) {
                backfillSheet
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCustomFilterSheet) {
                customFilterRangeSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Window Picker

    private var windowSelectorBar: some View {
        VStack(spacing: 8) {
            AdaptiveGlassContainer(spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(ProfitSummaryWindow.allCases) { item in
                        let active = summaryWindow == item
                        Button {
                            if item == .custom {
                                showCustomFilterSheet = true
                            } else {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                                    summaryWindow = item
                                    selectedChartDateKey = nil
                                }
                            }
                        } label: {
                            Text(item.rawValue)
                                .font(.caption.weight(active ? .semibold : .medium))
                                .foregroundStyle(active ? Color.white : Color.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background {
                                    if active {
                                        Capsule().fill(
                                            LinearGradient(
                                                colors: [Color(hex: "#10B981"), Color(hex: "#0EA5E9")],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .liquidGlassPill(tint: active ? Color(hex: "#10B981").opacity(0.25) : nil, interactive: true)
                    }
                }
            }

            if let subtitle = activeWindowSubtitle {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(Color(hex: "#10B981"))
                    Text("统计区间：\(subtitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("修改范围") {
                        showCustomFilterSheet = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: "#10B981"))
                }
                .padding(.horizontal, 6)
            }
        }
    }

    // MARK: - Hero Card

    private var profitHeroCard: some View {
        let isPositive = totalNetProfit >= 0
        let profitColor = isPositive ? Color(hex: "#10B981") : Color(hex: "#F43F5E")
        let sign = totalNetProfit > 0 ? "+" : ""

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("\(summaryWindow.rawValue)净利润")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("毛利率 \(ValueFormatter.percent(overallMargin))")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(profitColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(profitColor)
                            .monospacedDigit()
                    }

                    Text("\(sign)\(ValueFormatter.currency(totalNetProfit, currency: store.displayCurrency))")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(profitColor)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)

                    Text("统计周期内共 \(filteredRecords.count) 天已结算记录 · 总成本 \(ValueFormatter.currency(totalCost, currency: store.displayCurrency))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }

            HStack(spacing: 10) {
                pnlTile(
                    title: "销售额",
                    value: ValueFormatter.currency(totalRevenue, currency: store.displayCurrency, compact: true),
                    icon: "crown.fill",
                    color: Color(hex: "#EC4899")
                )
                pnlTile(
                    title: "渠道成本",
                    value: ValueFormatter.currency(totalChannelCost, currency: store.displayCurrency, compact: true),
                    icon: "server.rack",
                    color: Color(hex: "#38BDF8")
                )
                pnlTile(
                    title: "固定成本",
                    value: ValueFormatter.currency(totalFixedCost, currency: store.displayCurrency, compact: true),
                    icon: "building.2.fill",
                    color: Color(hex: "#F59E0B")
                )
            }

            Button {
                Task {
                    _ = await ledger.settleDate(Date(), trigger: .manual, using: store)
                }
            } label: {
                HStack(spacing: 8) {
                    if ledger.isSettling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.seal.fill")
                    }
                    Text(ledger.settlingProgressText ?? "立即核算并保存今日利润")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .glassButtonStyle(prominent: true)
            .tint(Color(hex: "#10B981"))
            .disabled(ledger.isSettling)
        }
        .padding(20)
        .liquidGlassCard(cornerRadius: 28, tint: profitColor.opacity(0.08))
    }

    private func pnlTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    // MARK: - Config Status Row (Primary Sales / Fixed Cost / 23:59 Auto Task)

    private var configStatusRow: some View {
        VStack(spacing: 10) {
            // Primary Sales Station Row
            Button {
                showAddPrimarySalesSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.callout)
                        .foregroundStyle(Color(hex: "#EC4899"))
                        .frame(width: 34, height: 34)
                        .background(Color(hex: "#EC4899").opacity(0.16), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("主站点（今日销售额来源）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let primary = store.primarySalesStation {
                            HStack(spacing: 6) {
                                Text(primary.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                ProviderBadge(provider: primary.provider)
                                Text(primary.usageScope.shortName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("未设置主站点 · 点击配置 Sub2API / NewAPI")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            .buttonStyle(.plain)
            .liquidGlassCard(cornerRadius: 20, interactive: true)

            HStack(spacing: 10) {
                // Daily Fixed Cost Card
                Button {
                    showFixedCostSheet = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundStyle(Color(hex: "#F59E0B"))
                            Text("每日固定成本")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(ValueFormatter.currency(ledger.totalDailyFixedCost, currency: store.displayCurrency))/天")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text("\(ledger.fixedCostItems.filter(\.isEnabled).count) 项生效中（服务器等）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: 20, interactive: true)

                // 23:59 Scheduled Task Card
                Button {
                    showScheduleSheet = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "clock.badge.checkmark.fill")
                                .foregroundStyle(ledger.scheduleConfig.isEnabled ? Color(hex: "#10B981") : .secondary)
                            Text("每日定时结算")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Circle()
                                .fill(ledger.scheduleConfig.isEnabled ? Color(hex: "#10B981") : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                        }
                        Text(ledger.scheduleConfig.isEnabled ? "每晚 \(ledger.scheduleConfig.formattedTime)" : "已暂停")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text(ledger.scheduleConfig.autoCatchUpYesterday ? "含次日自动补算" : "点击调整时间")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: 20, interactive: true)
            }
        }
    }

    // MARK: - Profit Trend Chart

    private var profitTrendChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chartMode == .netProfit ? "每日净利润趋势" : "每日销售额 vs 总成本")
                        .font(.headline.weight(.semibold))
                    if let active = activeChartRecord {
                        Text("\(active.dateKey) · 净利 \(active.netProfit >= 0 ? "+" : "")\(ValueFormatter.currency(active.netProfit, currency: active.currency))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(active.netProfit >= 0 ? Color(hex: "#10B981") : Color(hex: "#F43F5E"))
                            .monospacedDigit()
                    } else {
                        Text("点击或拖动图表查看当日盈亏")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Picker("图表模式", selection: $chartMode) {
                    ForEach(ProfitChartMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 145)
            }

            Chart {
                if chartMode == .netProfit {
                    RuleMark(y: .value("盈亏线", 0))
                        .foregroundStyle(Color.primary.opacity(0.22))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    ForEach(chartRecords) { rec in
                        BarMark(
                            x: .value("日期", rec.dateKey),
                            y: .value("净利润", rec.netProfit)
                        )
                        .foregroundStyle(rec.netProfit >= 0 ? Color(hex: "#10B981") : Color(hex: "#F43F5E"))
                        .cornerRadius(6)
                        .opacity(selectedChartDateKey == nil || selectedChartDateKey == rec.dateKey ? 1.0 : 0.4)
                    }
                } else {
                    ForEach(chartRecords) { rec in
                        BarMark(
                            x: .value("日期", rec.dateKey),
                            y: .value("金额", rec.revenue)
                        )
                        .foregroundStyle(by: .value("类型", "销售额"))
                        .position(by: .value("类型", "销售额"))
                        .cornerRadius(4)

                        BarMark(
                            x: .value("日期", rec.dateKey),
                            y: .value("金额", rec.totalCost)
                        )
                        .foregroundStyle(by: .value("类型", "总成本"))
                        .position(by: .value("类型", "总成本"))
                        .cornerRadius(4)
                    }
                }
            }
            .chartForegroundStyleScale([
                "销售额": Color(hex: "#EC4899"),
                "总成本": Color(hex: "#38BDF8")
            ])
            .chartXSelection(value: $selectedChartDateKey)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            Text(String(key.suffix(5)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.primary.opacity(0.1))
                    AxisValueLabel {
                        if let num = value.as(Double.self) {
                            Text(ValueFormatter.currency(num, currency: store.displayCurrency, compact: true))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    // MARK: - Historical Audit Ledger

    private var ledgerHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(
                title: "每日利润审查账本",
                subtitle: "记录每天销售额、各渠道成本与固定成本，点击查看逐渠道明细",
                trailingText: "\(filteredRecords.count) 条"
            )

            if filteredRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无结算记录")
                        .font(.subheadline.weight(.semibold))
                    Text("配置好主站点与成本渠道后，每晚 \(ledger.scheduleConfig.formattedTime) 将自动核算并保存；你也可以点击上方「立即核算今日」或右上角补录历史日期。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .liquidGlassCard(cornerRadius: 22)
            } else {
                ForEach(filteredRecords) { rec in
                    NavigationLink(value: rec) {
                        dailyRecordRow(rec)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dailyRecordRow(_ rec: DailyProfitRecord) -> some View {
        let isPositive = rec.netProfit >= 0
        let profitColor = isPositive ? Color(hex: "#10B981") : Color(hex: "#F43F5E")
        let sign = rec.netProfit > 0 ? "+" : ""

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(rec.dateKey)
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                        Label(rec.triggerSource.badgeTitle, systemImage: rec.triggerSource.iconName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                        if rec.hasAnyError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("\(rec.channelCosts.count) 个成本渠道 · 结算于 \(DateFormatters.shortTime.string(from: rec.settledAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(sign)\(ValueFormatter.currency(rec.netProfit, currency: rec.currency))")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(profitColor)
                        .monospacedDigit()
                    Text("毛利 \(ValueFormatter.percent(rec.profitMargin))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(profitColor.opacity(0.85))
                        .monospacedDigit()
                }
            }

            HStack(spacing: 10) {
                Text("销售 \(ValueFormatter.currency(rec.revenue, currency: rec.currency))")
                    .foregroundStyle(Color(hex: "#EC4899"))
                Text("·")
                Text("渠道 \(ValueFormatter.currency(rec.totalChannelCost, currency: rec.currency))")
                    .foregroundStyle(Color(hex: "#38BDF8"))
                Text("·")
                Text("固定 \(ValueFormatter.currency(rec.fixedCost, currency: rec.currency))")
                    .foregroundStyle(Color(hex: "#F59E0B"))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22, interactive: true)
    }

    // MARK: - Backfill Sheet (Custom Date Range + Quick Presets)

    private var backfillDayCount: Int {
        let cal = Calendar.current
        let s = cal.startOfDay(for: min(backfillStartDate, backfillEndDate))
        let e = cal.startOfDay(for: max(backfillStartDate, backfillEndDate))
        return max(1, (cal.dateComponents([.day], from: s, to: e).day ?? 0) + 1)
    }

    private var backfillSheet: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#38BDF8"))

                ScrollView {
                    VStack(spacing: 16) {
                        // Quick Range Presets
                        VStack(alignment: .leading, spacing: 10) {
                            Text("快捷选择补录区间")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                quickPresetButton("本月至今") {
                                    applyQuickRange(.thisMonth, toStart: $backfillStartDate, toEnd: $backfillEndDate)
                                }
                                quickPresetButton("上个月") {
                                    applyQuickRange(.lastMonth, toStart: $backfillStartDate, toEnd: $backfillEndDate)
                                }
                                quickPresetButton("最近14天") {
                                    applyQuickRange(.last14Days, toStart: $backfillStartDate, toEnd: $backfillEndDate)
                                }
                                quickPresetButton("最近7天") {
                                    applyQuickRange(.last7Days, toStart: $backfillStartDate, toEnd: $backfillEndDate)
                                }
                                quickPresetButton("最近30天") {
                                    applyQuickRange(.last30Days, toStart: $backfillStartDate, toEnd: $backfillEndDate)
                                }
                                quickPresetButton("昨天") {
                                    applyQuickRange(.yesterday, toStart: $backfillStartDate, toEnd: $backfillEndDate)
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 22)

                        // Custom Start & End Date Pickers
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自定义补录日期范围")
                                .font(.headline)
                            Text("例如选择 11月4日 到 11月20日，按站点一次拉取并逐日生成利润账单（单日补录只需起止选同一天）。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            DatePicker(
                                "开始日期",
                                selection: $backfillStartDate,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                            .onChange(of: backfillStartDate) { _, newStart in
                                if backfillEndDate < newStart {
                                    backfillEndDate = newStart
                                }
                            }

                            Divider().opacity(0.25)

                            DatePicker(
                                "结束日期",
                                selection: $backfillEndDate,
                                in: backfillStartDate...Date(),
                                displayedComponents: .date
                            )
                            .environment(\.locale, Locale(identifier: "zh_CN"))

                            Divider().opacity(0.25)

                            Toggle(isOn: $backfillOverwriteExisting) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("覆盖重算已有记录")
                                        .font(.subheadline.weight(.medium))
                                    Text("关闭后仅补录尚未记录的缺失日期")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(Color(hex: "#38BDF8"))

                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color(hex: "#38BDF8"))
                                Text("已选区间：\(DateFormatters.apiDay.string(from: backfillStartDate)) 至 \(DateFormatters.apiDay.string(from: backfillEndDate))（共 \(backfillDayCount) 天）")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Spacer()
                            }
                            .padding(.top, 2)

                            Button {
                                let s = backfillStartDate
                                let e = backfillEndDate
                                let overwrite = backfillOverwriteExisting
                                Task {
                                    _ = await ledger.backfillDateRange(
                                        start: s,
                                        end: e,
                                        overwriteExisting: overwrite,
                                        using: store
                                    )
                                    customFilterStart = s
                                    customFilterEnd = e
                                    summaryWindow = .custom
                                    showBackfillSheet = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if ledger.isSettling {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                    Text(ledger.settlingProgressText ?? "开始补录（共 \(backfillDayCount) 天）")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }
                            .glassButtonStyle(prominent: true)
                            .tint(Color(hex: "#38BDF8"))
                            .disabled(ledger.isSettling)
                        }
                        .padding(18)
                        .liquidGlassCard(cornerRadius: 22)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("历史利润补录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showBackfillSheet = false }
                }
            }
        }
    }

    // MARK: - Custom Profit Filter Range Sheet

    private var customFilterDayCount: Int {
        let cal = Calendar.current
        let s = cal.startOfDay(for: min(customFilterStart, customFilterEnd))
        let e = cal.startOfDay(for: max(customFilterStart, customFilterEnd))
        return max(1, (cal.dateComponents([.day], from: s, to: e).day ?? 0) + 1)
    }

    private var customFilterRangeSheet: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#10B981"))

                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("快捷统计区间")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                quickPresetButton("本月至今") {
                                    applyQuickRange(.thisMonth, toStart: $customFilterStart, toEnd: $customFilterEnd)
                                }
                                quickPresetButton("上个月") {
                                    applyQuickRange(.lastMonth, toStart: $customFilterStart, toEnd: $customFilterEnd)
                                }
                                quickPresetButton("最近14天") {
                                    applyQuickRange(.last14Days, toStart: $customFilterStart, toEnd: $customFilterEnd)
                                }
                                quickPresetButton("最近7天") {
                                    applyQuickRange(.last7Days, toStart: $customFilterStart, toEnd: $customFilterEnd)
                                }
                                quickPresetButton("最近30天") {
                                    applyQuickRange(.last30Days, toStart: $customFilterStart, toEnd: $customFilterEnd)
                                }
                                quickPresetButton("最近90天") {
                                    applyQuickRange(.last90Days, toStart: $customFilterStart, toEnd: $customFilterEnd)
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 22)

                        VStack(spacing: 14) {
                            DatePicker(
                                "开始日期",
                                selection: $customFilterStart,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                            .onChange(of: customFilterStart) { _, newStart in
                                if customFilterEnd < newStart {
                                    customFilterEnd = newStart
                                }
                            }

                            Divider().opacity(0.25)

                            DatePicker(
                                "结束日期",
                                selection: $customFilterEnd,
                                in: customFilterStart...Date(),
                                displayedComponents: .date
                            )
                            .environment(\.locale, Locale(identifier: "zh_CN"))

                            HStack {
                                Image(systemName: "chart.bar.doc.horizontal")
                                    .foregroundStyle(Color(hex: "#10B981"))
                                Text("将统计 \(DateFormatters.apiDay.string(from: customFilterStart)) 至 \(DateFormatters.apiDay.string(from: customFilterEnd))（共 \(customFilterDayCount) 天）内已保存的利润账单")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Spacer()
                            }
                        }
                        .padding(18)
                        .liquidGlassCard(cornerRadius: 22)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("自定义利润统计范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCustomFilterSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            summaryWindow = .custom
                            selectedChartDateKey = nil
                        }
                        showCustomFilterSheet = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private enum QuickDatePreset {
        case yesterday, last7Days, last14Days, last30Days, last90Days, thisMonth, lastMonth
    }

    private func applyQuickRange(_ preset: QuickDatePreset, toStart: Binding<Date>, toEnd: Binding<Date>) {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        switch preset {
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: today) ?? today
            toStart.wrappedValue = y
            toEnd.wrappedValue = y
        case .last7Days:
            toStart.wrappedValue = cal.date(byAdding: .day, value: -6, to: today) ?? today
            toEnd.wrappedValue = today
        case .last14Days:
            toStart.wrappedValue = cal.date(byAdding: .day, value: -13, to: today) ?? today
            toEnd.wrappedValue = today
        case .last30Days:
            toStart.wrappedValue = cal.date(byAdding: .day, value: -29, to: today) ?? today
            toEnd.wrappedValue = today
        case .last90Days:
            toStart.wrappedValue = cal.date(byAdding: .day, value: -89, to: today) ?? today
            toEnd.wrappedValue = today
        case .thisMonth:
            let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
            toStart.wrappedValue = startOfMonth
            toEnd.wrappedValue = today
        case .lastMonth:
            let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
            let prevMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart) ?? thisMonthStart
            let prevMonthEnd = cal.date(byAdding: .day, value: -1, to: thisMonthStart) ?? prevMonthStart
            toStart.wrappedValue = prevMonthStart
            toEnd.wrappedValue = prevMonthEnd
        }
    }

    private func quickPresetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .glassButtonStyle()
    }
}
