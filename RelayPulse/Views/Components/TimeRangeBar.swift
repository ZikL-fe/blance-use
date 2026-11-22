import SwiftUI

struct TimeRangeBar: View {
    @Binding var selection: DateRangeSelection
    var onRangeChanged: (DateRangeSelection) -> Void

    @Namespace private var pillNamespace
    @State private var showCustomSheet = false

    var body: some View {
        VStack(spacing: 8) {
            AdaptiveGlassContainer(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(TimeRangePreset.allCases) { preset in
                        let isSelected = selection.preset == preset
                        Button {
                            if preset == .custom {
                                showCustomSheet = true
                            } else {
                                var updated = selection
                                updated.preset = preset
                                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                                    selection = updated
                                }
                                onRangeChanged(updated)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: preset.iconName)
                                    .font(.caption.weight(.semibold))
                                Text(preset.title)
                                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 6)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [Color(hex: "#38BDF8"), Color(hex: "#6366F1")],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .matchedGeometryEffect(id: "activeRangePill", in: pillNamespace)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .liquidGlassPill(
                            tint: isSelected ? Color(hex: "#38BDF8").opacity(0.28) : nil,
                            interactive: true
                        )
                        .adaptiveGlassEffectID(preset.rawValue, in: pillNamespace)
                    }
                }
            }

            // Active date interval subtitle + quick custom adjust button
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(selection.formattedSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if selection.preset == .custom {
                    Button {
                        showCustomSheet = true
                    } label: {
                        Label("修改日期", systemImage: "calendar")
                            .font(.caption.weight(.medium))
                    }
                    .tint(Color(hex: "#38BDF8"))
                }
            }
            .padding(.horizontal, 6)
        }
        .sheet(isPresented: $showCustomSheet) {
            CustomDateRangeSheet(selection: $selection) { updated in
                onRangeChanged(updated)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

struct CustomDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: DateRangeSelection
    var onApply: (DateRangeSelection) -> Void

    @State private var startDate: Date
    @State private var endDate: Date

    init(selection: Binding<DateRangeSelection>, onApply: @escaping (DateRangeSelection) -> Void) {
        self._selection = selection
        self.onApply = onApply
        let interval = selection.wrappedValue.resolvedInterval
        self._startDate = State(initialValue: interval.start)
        self._endDate = State(initialValue: interval.end)
    }

    private var daySpan: Int {
        let cal = Calendar.current
        let s = cal.startOfDay(for: min(startDate, endDate))
        let e = cal.startOfDay(for: max(startDate, endDate))
        return max(1, (cal.dateComponents([.day], from: s, to: e).day ?? 0) + 1)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#6366F1"))

                ScrollView {
                    VStack(spacing: 16) {
                        // Quick range chips
                        VStack(alignment: .leading, spacing: 10) {
                            Text("快捷时间段")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                quickRangeChip("近 14 天") {
                                    applyDaysBack(13)
                                }
                                quickRangeChip("本月至今") {
                                    let cal = Calendar.current
                                    let now = Date()
                                    if let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) {
                                        startDate = startOfMonth
                                        endDate = now
                                    }
                                }
                                quickRangeChip("上个月") {
                                    let cal = Calendar.current
                                    let now = Date()
                                    if let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)),
                                       let prevMonth = cal.date(byAdding: .month, value: -1, to: thisMonth),
                                       let prevEnd = cal.date(byAdding: .day, value: -1, to: thisMonth) {
                                        startDate = prevMonth
                                        endDate = prevEnd
                                    }
                                }
                                quickRangeChip("近 90 天") {
                                    applyDaysBack(89)
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 22)

                        // Pickers
                        VStack(spacing: 14) {
                            DatePicker(
                                "开始日期",
                                selection: $startDate,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                            .onChange(of: startDate) { _, newStart in
                                if endDate < newStart {
                                    endDate = newStart
                                }
                            }

                            Divider().opacity(0.35)

                            DatePicker(
                                "结束日期",
                                selection: $endDate,
                                in: startDate...Date(),
                                displayedComponents: .date
                            )
                            .environment(\.locale, Locale(identifier: "zh_CN"))

                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color(hex: "#38BDF8"))
                                Text("已选择共 \(daySpan) 天（超 28 天 NewAPI 自动分段拉取）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.top, 4)
                        }
                        .padding(18)
                        .liquidGlassCard(cornerRadius: 22)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("自定义统计范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        let normalizedStart = min(startDate, endDate)
                        let normalizedEnd = max(startDate, endDate)
                        let updated = DateRangeSelection(
                            preset: .custom,
                            customStart: normalizedStart,
                            customEnd: normalizedEnd
                        )
                        selection = updated
                        onApply(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func applyDaysBack(_ days: Int) {
        let cal = Calendar.current
        let now = Date()
        startDate = cal.date(byAdding: .day, value: -days, to: now) ?? now
        endDate = now
    }

    private func quickRangeChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .glassButtonStyle()
    }
}
