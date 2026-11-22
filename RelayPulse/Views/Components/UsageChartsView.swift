import Charts
import SwiftUI

enum TrendChartStyle: String, CaseIterable, Identifiable {
    case bar = "柱状"
    case area = "曲线"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .bar: return "chart.bar.fill"
        case .area: return "waveform.path.ecg"
        }
    }
}

struct SpendTrendChartCard: View {
    let title: String
    let points: [UsageBucketPoint]
    let isHourly: Bool
    let currency: DisplayCurrency
    var accentColor: Color = Color(hex: "#38BDF8")

    @State private var chartStyle: TrendChartStyle = .bar
    @State private var selectedDate: Date? = nil

    private var selectedPoint: UsageBucketPoint? {
        guard let selectedDate, !points.isEmpty else { return nil }
        return points.min(by: {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        })
    }

    private var peakCost: Double {
        points.map(\.convertedCost).max() ?? 0
    }

    private var averageCost: Double {
        let nonZero = points.filter { $0.convertedCost > 0 }
        guard !nonZero.isEmpty else { return 0 }
        return nonZero.reduce(0) { $0 + $1.convertedCost } / Double(nonZero.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    if let active = selectedPoint {
                        HStack(spacing: 8) {
                            Text(formattedBucketDate(active.date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accentColor)
                            Text(ValueFormatter.currency(active.convertedCost, currency: currency))
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                            Text("(\(ValueFormatter.usd(active.costUSD)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 10) {
                            Text("峰值 \(ValueFormatter.currency(peakCost, currency: currency))")
                            Text("·")
                            Text("均值 \(ValueFormatter.currency(averageCost, currency: currency))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }

                Spacer()

                // Style toggle pills
                AdaptiveGlassContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(TrendChartStyle.allCases) { style in
                            let active = chartStyle == style
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    chartStyle = style
                                }
                            } label: {
                                Image(systemName: style.icon)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(active ? Color.white : Color.secondary)
                                    .frame(width: 30, height: 28)
                                    .background(active ? accentColor : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .liquidGlassPill(interactive: true)
                        }
                    }
                }
            }

            // Chart body
            if points.allSatisfy({ $0.convertedCost == 0 && $0.requests == 0 }) {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.title2)
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text("所选时间范围内暂无消耗记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
            } else {
                Chart {
                    ForEach(points) { point in
                        if chartStyle == .bar {
                            BarMark(
                                x: .value("时间", point.date, unit: isHourly ? .hour : .day),
                                y: .value("消耗", point.convertedCost)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [accentColor, accentColor.opacity(0.45)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .cornerRadius(6)
                            .opacity(selectedPoint == nil || selectedPoint?.id == point.id ? 1.0 : 0.38)
                        } else {
                            AreaMark(
                                x: .value("时间", point.date),
                                y: .value("消耗", point.convertedCost)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [accentColor.opacity(0.42), accentColor.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("时间", point.date),
                                y: .value("消耗", point.convertedCost)
                            )
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .foregroundStyle(accentColor)

                            if points.count <= 14 {
                                PointMark(
                                    x: .value("时间", point.date),
                                    y: .value("消耗", point.convertedCost)
                                )
                                .symbolSize(selectedPoint?.id == point.id ? 70 : 28)
                                .foregroundStyle(accentColor)
                            }
                        }
                    }

                    if let active = selectedPoint {
                        RuleMark(x: .value("选中", active.date))
                            .foregroundStyle(accentColor.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Color.primary.opacity(0.1))
                        AxisValueLabel {
                            if let num = value.as(Double.self) {
                                Text(ValueFormatter.currency(num, currency: currency, compact: true))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: isHourly ? 6 : 5)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(isHourly ? DateFormatters.hourLabel.string(from: date) : DateFormatters.monthDay.string(from: date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(height: 205)

                // Detail bar when scrubbing
                if let active = selectedPoint {
                    HStack(spacing: 14) {
                        Label("\(ValueFormatter.requests(active.requests)) 次请求", systemImage: "arrow.up.arrow.down")
                        Label("\(ValueFormatter.tokens(active.totalTokens)) Tokens", systemImage: "text.word.spacing")
                        Spacer()
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlassPill(interactive: false)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private func formattedBucketDate(_ date: Date) -> String {
        if isHourly {
            return DateFormatters.hourLabel.string(from: date)
        }
        return DateFormatters.monthDay.string(from: date)
    }
}

// MARK: - Multi-Station Share Donut Card

struct StationShareDonutCard: View {
    let breakdowns: [StationBreakdownItem]
    let totalConverted: Double
    let currency: DisplayCurrency

    private var nonZeroItems: [StationBreakdownItem] {
        breakdowns.filter { $0.convertedCost > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("中转站消耗占比")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("\(breakdowns.count) 个活跃站点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if nonZeroItems.isEmpty {
                Text("暂无消耗占比数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                HStack(spacing: 16) {
                    ZStack {
                        Chart(nonZeroItems) { item in
                            SectorMark(
                                angle: .value("消耗", item.convertedCost),
                                innerRadius: .ratio(0.64),
                                angularInset: 2.5
                            )
                            .cornerRadius(6)
                            .foregroundStyle(item.station.accentColor)
                        }
                        .frame(width: 132, height: 132)

                        VStack(spacing: 2) {
                            Text("总计")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(ValueFormatter.currency(totalConverted, currency: currency, compact: true))
                                .font(.callout.weight(.bold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(width: 82)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(nonZeroItems.prefix(5)) { item in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.station.accentColor)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.station.name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(ValueFormatter.currency(item.convertedCost, currency: currency))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer()
                                Text(ValueFormatter.percent(item.share))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(item.station.accentColor)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }
}

// MARK: - Model Breakdown List Card

struct ModelBreakdownListCard: View {
    let title: String
    let models: [ModelUsageStat]
    let currency: DisplayCurrency
    var maxItems: Int = 8

    private var totalCost: Double {
        models.reduce(0) { $0 + $1.convertedCost }
    }

    private let palette: [Color] = [
        Color(hex: "#38BDF8"),
        Color(hex: "#818CF8"),
        Color(hex: "#C084FC"),
        Color(hex: "#F472B6"),
        Color(hex: "#FB923C"),
        Color(hex: "#34D399"),
        Color(hex: "#2DD4BF"),
        Color(hex: "#FBBF24")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("共 \(models.count) 个模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if models.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    Text("所选范围内暂无模型消耗明细")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(models.prefix(maxItems).enumerated()), id: \.element.id) { idx, model in
                        let share = totalCost > 0 ? (model.convertedCost / totalCost) : 0
                        let barColor = palette[idx % palette.count]

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(model.modelName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(ValueFormatter.currency(model.convertedCost, currency: currency))
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.08))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [barColor, barColor.opacity(0.6)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(6, geo.size.width * CGFloat(share)))
                                }
                            }
                            .frame(height: 6)

                            HStack(spacing: 10) {
                                Text(ValueFormatter.usd(model.costUSD))
                                Text("·")
                                Text("\(ValueFormatter.requests(model.requests)) 次")
                                Text("·")
                                Text("\(ValueFormatter.tokens(model.totalTokens)) tok")
                                Spacer()
                                Text(ValueFormatter.percent(share))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(barColor)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }
}
