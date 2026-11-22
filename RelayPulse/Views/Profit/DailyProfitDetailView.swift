import SwiftUI

struct DailyProfitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StationStore.self) private var store
    @Environment(ProfitLedgerStore.self) private var ledger

    let record: DailyProfitRecord

    @State private var noteText: String = ""
    @State private var showDeleteConfirm: Bool = false

    private var liveRecord: DailyProfitRecord {
        ledger.effectiveRecords(isDemoMode: store.isDemoMode)
            .first(where: { $0.dateKey == record.dateKey }) ?? record
    }

    var body: some View {
        let isPositive = liveRecord.netProfit >= 0
        let accent = isPositive ? Color(hex: "#10B981") : Color(hex: "#F43F5E")

        ZStack {
            LiquidAmbientBackground(accent: accent)

            ScrollView {
                VStack(spacing: 16) {
                    summaryCard(accent: accent)
                    salesSectionCard
                    channelCostsCard
                    fixedCostsCard
                    auditNoteCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("\(liveRecord.dateKey) 盈亏详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    if !store.isDemoMode {
                        Button {
                            Task {
                                _ = await ledger.settleDate(liveRecord.date, trigger: .manual, using: store)
                            }
                        } label: {
                            if ledger.isSettling {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(ledger.isSettling)

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .onAppear {
            noteText = liveRecord.note
        }
        .alert("删除当日账单记录？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) {
                ledger.deleteRecord(liveRecord)
                dismiss()
            }
        } message: {
            Text("删除 \(liveRecord.dateKey) 的利润记录后，可随时通过历史补录重新拉取计算。")
        }
    }

    // MARK: - Cards

    private func summaryCard(accent: Color) -> some View {
        let sign = liveRecord.netProfit > 0 ? "+" : ""
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(liveRecord.triggerSource.badgeTitle, systemImage: liveRecord.triggerSource.iconName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .liquidGlassPill(interactive: false)
                Spacer()
                Text("结算于 \(DateFormatters.shortTime.string(from: liveRecord.settledAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("当日净利润")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(sign)\(ValueFormatter.currency(liveRecord.netProfit, currency: liveRecord.currency))")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                    Text("毛利率 \(ValueFormatter.percent(liveRecord.profitMargin))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.16), in: Capsule())
                        .monospacedDigit()
                }
            }

            Divider().opacity(0.25)

            // Waterfall Formula Summary
            VStack(spacing: 8) {
                waterfallRow("主站点销售额", ValueFormatter.currency(liveRecord.revenue, currency: liveRecord.currency), color: Color(hex: "#EC4899"))
                waterfallRow("− 上游渠道成本", "-\(ValueFormatter.currency(liveRecord.totalChannelCost, currency: liveRecord.currency))", color: Color(hex: "#38BDF8"))
                waterfallRow("− 每日固定成本", "-\(ValueFormatter.currency(liveRecord.fixedCost, currency: liveRecord.currency))", color: Color(hex: "#F59E0B"))
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 26, tint: accent.opacity(0.10))
    }

    private func waterfallRow(_ title: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    private var salesSectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("主站点销售额明细", systemImage: "crown.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(ValueFormatter.currency(liveRecord.revenue, currency: liveRecord.currency))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(hex: "#EC4899"))
                    .monospacedDigit()
            }

            if let sales = liveRecord.sales {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(sales.stationName)
                            .font(.subheadline.weight(.semibold))
                        if let provider = sales.provider {
                            ProviderBadge(provider: provider)
                        }
                        if let scope = sales.usageScope {
                            Text(scope.shortName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("原始额度 \(ValueFormatter.usd(sales.rawAmount)) × 汇率 \(ValueFormatter.rate(sales.exchangeRate))")
                        Spacer()
                        Text("\(ValueFormatter.requests(sales.requests)) 次 · \(ValueFormatter.tokens(sales.tokens))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                    if let err = sales.errorMessage {
                        Text("拉取异常：\(err)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Text("结算当日未配置主站点，销售额记为 0。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var channelCostsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("各上游渠道成本明细", systemImage: "server.rack")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(ValueFormatter.currency(liveRecord.totalChannelCost, currency: liveRecord.currency))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(hex: "#38BDF8"))
                    .monospacedDigit()
            }

            if liveRecord.channelCosts.isEmpty {
                Text("当日无上游渠道成本记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(liveRecord.channelCosts) { ch in
                    let share = liveRecord.totalChannelCost > 0 ? ch.convertedCost / liveRecord.totalChannelCost : 0
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(ch.stationName)
                                .font(.subheadline.weight(.semibold))
                            ProviderBadge(provider: ch.provider)
                            Spacer()
                            Text(ValueFormatter.currency(ch.convertedCost, currency: liveRecord.currency))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                        }

                        HStack {
                            Text("原始 \(ch.provider.formatRawAmount(ch.rawAmount)) × \(ValueFormatter.rate(ch.exchangeRate))")
                            Spacer()
                            if ch.provider == .remail {
                                Text("\(ValueFormatter.requests(ch.requests)) 单 · 占 \(ValueFormatter.percent(share))")
                            } else {
                                Text("\(ValueFormatter.requests(ch.requests)) 次 · 占 \(ValueFormatter.percent(share))")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                        if let err = ch.errorMessage {
                            Text("拉取异常：\(err)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var fixedCostsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("当日固定成本明细", systemImage: "building.2.fill")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(ValueFormatter.currency(liveRecord.fixedCost, currency: liveRecord.currency))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(hex: "#F59E0B"))
                    .monospacedDigit()
            }

            if liveRecord.fixedCostItems.isEmpty {
                Text("当日固定成本为 0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(liveRecord.fixedCostItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                            if !item.note.isEmpty {
                                Text(item.note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(ValueFormatter.currency(item.dailyAmount, currency: liveRecord.currency))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    if item.id != liveRecord.fixedCostItems.last?.id {
                        Divider().opacity(0.22)
                    }
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var auditNoteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("审查备注", systemImage: "note.text")
                .font(.headline.weight(.semibold))

            TextField("例如：今日大客户集中调用 / 上游临时调价说明...", text: $noteText, axis: .vertical)
                .lineLimit(2...5)
                .padding(12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(store.isDemoMode)
                .onChange(of: noteText) { _, newValue in
                    if !store.isDemoMode {
                        ledger.updateNote(for: liveRecord.dateKey, note: newValue)
                    }
                }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }
}
