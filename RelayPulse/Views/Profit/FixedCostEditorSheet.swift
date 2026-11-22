import SwiftUI

struct FixedCostEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StationStore.self) private var store
    @Environment(ProfitLedgerStore.self) private var ledger

    @State private var newName: String = ""
    @State private var newDailyAmountText: String = ""
    @State private var newMonthlyHelperText: String = ""
    @State private var newNote: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#F59E0B"))

                ScrollView {
                    VStack(spacing: 16) {
                        // Summary header
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("当前每日固定成本合计")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(ValueFormatter.currency(ledger.totalDailyFixedCost, currency: store.displayCurrency)) / 天")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(Color(hex: "#F59E0B"))
                                    .monospacedDigit()
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("约合每月 (×30)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(ValueFormatter.currency(ledger.totalDailyFixedCost * 30, currency: store.displayCurrency))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 22, tint: Color(hex: "#F59E0B").opacity(0.10))

                        // Existing items
                        VStack(alignment: .leading, spacing: 12) {
                            Text("已配置的固定成本项目")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            if ledger.fixedCostItems.isEmpty {
                                Text("暂无固定成本项目，可在下方添加（如服务器、代理、域名等）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(ledger.fixedCostItems) { item in
                                    fixedCostRow(item)
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 22)

                        // Add new fixed cost item
                        VStack(alignment: .leading, spacing: 12) {
                            Text("新增每日固定成本")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            TextField("项目名称（如：服务器费用 / 专线节点 / CDN）", text: $newName)
                                .padding(12)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("每日金额 (\(store.displayCurrency.symbol)/天)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("例如：35", text: $newDailyAmountText)
                                        .keyboardType(.decimalPad)
                                        .monospacedDigit()
                                        .padding(10)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("或填月费自动 ÷30")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("例如：900", text: $newMonthlyHelperText)
                                        .keyboardType(.decimalPad)
                                        .monospacedDigit()
                                        .padding(10)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .onChange(of: newMonthlyHelperText) { _, val in
                                            if let monthly = Double(val.replacingOccurrences(of: ",", with: ".")), monthly >= 0 {
                                                newDailyAmountText = String(format: "%.2f", monthly / 30.0)
                                            }
                                        }
                                }
                            }

                            TextField("备注（可选）", text: $newNote)
                                .padding(12)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Button {
                                addNewItem()
                            } label: {
                                Label("添加到每日固定成本", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            .glassButtonStyle(prominent: true)
                            .tint(Color(hex: "#F59E0B"))
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (Double(newDailyAmountText.replacingOccurrences(of: ",", with: ".")) ?? -1) < 0)
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 22)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("每日固定成本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func fixedCostRow(_ item: FixedCostItem) -> some View {
        let amountBinding = Binding<String>(
            get: { String(format: item.dailyAmount.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", item.dailyAmount) },
            set: { raw in
                if let val = Double(raw.replacingOccurrences(of: ",", with: ".")), val >= 0 {
                    var updated = item
                    updated.dailyAmount = val
                    ledger.updateFixedCost(updated)
                }
            }
        )

        return HStack(spacing: 10) {
            Button {
                ledger.toggleFixedCost(item)
            } label: {
                Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isEnabled ? Color(hex: "#F59E0B") : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.isEnabled ? .primary : .secondary)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Text(store.displayCurrency.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                TextField("0", text: amountBinding)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .frame(width: 72)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button(role: .destructive) {
                ledger.deleteFixedCost(item)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func addNewItem() {
        let cleanedAmount = Double(newDailyAmountText.replacingOccurrences(of: ",", with: ".")) ?? 0
        ledger.addFixedCost(name: newName, dailyAmount: max(0, cleanedAmount), note: newNote)
        newName = ""
        newDailyAmountText = ""
        newMonthlyHelperText = ""
        newNote = ""
    }
}
