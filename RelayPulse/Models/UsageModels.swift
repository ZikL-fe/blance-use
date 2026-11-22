import Foundation

enum TimeRangePreset: String, CaseIterable, Identifiable, Codable {
    case today = "today"
    case last7Days = "7d"
    case last30Days = "30d"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今日"
        case .last7Days: return "近7天"
        case .last30Days: return "近30天"
        case .custom: return "自定义"
        }
    }

    var shortLabel: String {
        switch self {
        case .today: return "今日"
        case .last7Days: return "7日"
        case .last30Days: return "30日"
        case .custom: return "自定义"
        }
    }

    var iconName: String {
        switch self {
        case .today: return "sun.max.fill"
        case .last7Days: return "calendar.badge.clock"
        case .last30Days: return "calendar"
        case .custom: return "slider.horizontal.3"
        }
    }
}

struct DateRangeSelection: Equatable, Hashable {
    var preset: TimeRangePreset
    var customStart: Date
    var customEnd: Date

    init(
        preset: TimeRangePreset = .last7Days,
        customStart: Date = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date(),
        customEnd: Date = Date()
    ) {
        self.preset = preset
        self.customStart = customStart
        self.customEnd = customEnd
    }

    /// Inclusive start of day and end of day (or current moment for today)
    var resolvedInterval: (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let endOfToday = cal.date(byAdding: DateComponents(day: 1, second: -1), to: startOfToday) ?? now

        switch preset {
        case .today:
            return (startOfToday, endOfToday)
        case .last7Days:
            let start = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return (start, endOfToday)
        case .last30Days:
            let start = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return (start, endOfToday)
        case .custom:
            let s = cal.startOfDay(for: min(customStart, customEnd))
            let endDayStart = cal.startOfDay(for: max(customStart, customEnd))
            let e = cal.date(byAdding: DateComponents(day: 1, second: -1), to: endDayStart) ?? max(customStart, customEnd)
            return (s, e)
        }
    }

    var isSingleDay: Bool {
        let interval = resolvedInterval
        return Calendar.current.isDate(interval.start, inSameDayAs: interval.end)
    }

    var granularity: String {
        isSingleDay ? "hour" : "day"
    }

    var dayCount: Int {
        let interval = resolvedInterval
        let comps = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: interval.start), to: Calendar.current.startOfDay(for: interval.end))
        return max(1, (comps.day ?? 0) + 1)
    }

    var formattedSubtitle: String {
        let interval = resolvedInterval
        if isSingleDay {
            return DateFormatters.monthDay.string(from: interval.start) + " · 按小时统计"
        }
        return "\(DateFormatters.monthDay.string(from: interval.start)) - \(DateFormatters.monthDay.string(from: interval.end)) · 共 \(dayCount) 天"
    }
}

enum DisplayCurrency: String, CaseIterable, Identifiable, Codable {
    case cny = "CNY"
    case usd = "USD"
    case hkd = "HKD"
    case eur = "EUR"
    case jpy = "JPY"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cny: return "¥"
        case .usd: return "$"
        case .hkd: return "HK$"
        case .eur: return "€"
        case .jpy: return "¥"
        }
    }

    var displayName: String {
        switch self {
        case .cny: return "人民币 (¥ CNY)"
        case .usd: return "美元 ($ USD)"
        case .hkd: return "港币 (HK$ HKD)"
        case .eur: return "欧元 (€ EUR)"
        case .jpy: return "日元 (¥ JPY)"
        }
    }

    var defaultRate: Double {
        switch self {
        case .cny: return 7.2
        case .usd: return 1.0
        case .hkd: return 7.8
        case .eur: return 0.92
        case .jpy: return 150.0
        }
    }
}

struct UsageBucketPoint: Identifiable, Codable, Hashable {
    var id: String { bucketKey }
    /// Bucket key such as "2026-11-22" or "2026-11-22 14:00"
    var bucketKey: String
    var date: Date
    var requests: Int64
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheTokens: Int64
    var totalTokens: Int64
    /// Raw cost in USD as reported by the station
    var costUSD: Double
    /// Converted cost in user's display currency using station exchange rate
    var convertedCost: Double
}

struct ModelUsageStat: Identifiable, Codable, Hashable {
    var id: String { modelName }
    var modelName: String
    var requests: Int64
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheTokens: Int64
    var totalTokens: Int64
    var costUSD: Double
    var convertedCost: Double
}

struct StationUsageSnapshot: Identifiable, Codable {
    var id: UUID { stationID }
    var stationID: UUID
    var accountLabel: String
    /// Remaining balance in USD (nil if API doesn't expose it)
    var balanceUSD: Double?
    /// Historical total used in USD if provided by profile
    var lifetimeUsedUSD: Double?
    /// Period metrics for the currently selected time range
    var periodCostUSD: Double
    var periodConvertedCost: Double
    var periodRequests: Int64
    var periodTokens: Int64
    var periodInputTokens: Int64
    var periodOutputTokens: Int64
    var periodCacheTokens: Int64
    var dailyPoints: [UsageBucketPoint]
    var modelStats: [ModelUsageStat]
    var updatedAt: Date
    var errorMessage: String?

    var isHealthy: Bool {
        errorMessage == nil
    }
}

struct StationBreakdownItem: Identifiable {
    let station: RelayStation
    let snapshot: StationUsageSnapshot?
    let convertedCost: Double
    let costUSD: Double
    let share: Double
    let requests: Int64
    let tokens: Int64
    let balanceConverted: Double?
    let balanceUSD: Double?

    var id: UUID { station.id }
}

struct OverviewMetrics {
    var totalConvertedCost: Double
    var totalCostUSD: Double
    var totalRemainingConverted: Double
    var totalRemainingUSD: Double
    var totalRequests: Int64
    var totalTokens: Int64
    var combinedSeries: [UsageBucketPoint]
    var stationBreakdowns: [StationBreakdownItem]
    var topModels: [ModelUsageStat]
    var activeStationCount: Int
    var errorStationCount: Int
}
