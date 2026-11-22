import Foundation

// MARK: - Daily Fixed Cost Items (Server, Proxy, Domain, etc.)

struct FixedCostItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Daily fixed expense in user's display currency
    var dailyAmount: Double
    var isEnabled: Bool
    var note: String

    init(
        id: UUID = UUID(),
        name: String,
        dailyAmount: Double,
        isEnabled: Bool = true,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.dailyAmount = max(0, dailyAmount)
        self.isEnabled = isEnabled
        self.note = note
    }
}

// MARK: - Settlement Trigger & Schedule Config

enum SettlementTrigger: String, Codable, Hashable {
    case scheduledAuto = "scheduled_auto"
    case catchUpAuto = "catch_up_auto"
    case manual = "manual"
    case backfill = "backfill"

    var badgeTitle: String {
        switch self {
        case .scheduledAuto: return "23:59 自动"
        case .catchUpAuto: return "自动补算"
        case .manual: return "手动结算"
        case .backfill: return "历史补录"
        }
    }

    var iconName: String {
        switch self {
        case .scheduledAuto: return "clock.badge.checkmark.fill"
        case .catchUpAuto: return "arrow.clockwise.circle.fill"
        case .manual: return "hand.tap.fill"
        case .backfill: return "calendar.badge.plus"
        }
    }
}

struct AutoSettlementConfig: Codable, Equatable {
    var isEnabled: Bool
    var hour: Int
    var minute: Int
    var notifyOnComplete: Bool
    var autoCatchUpYesterday: Bool

    init(
        isEnabled: Bool = true,
        hour: Int = 23,
        minute: Int = 59,
        notifyOnComplete: Bool = true,
        autoCatchUpYesterday: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
        self.notifyOnComplete = notifyOnComplete
        self.autoCatchUpYesterday = autoCatchUpYesterday
    }

    var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    func nextFireDate(after now: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let todayTarget = cal.date(from: comps) ?? now
        if todayTarget > now {
            return todayTarget
        }
        return cal.date(byAdding: .day, value: 1, to: todayTarget) ?? now.addingTimeInterval(86400)
    }
}

// MARK: - Daily Profit & Loss Audit Records

struct ChannelCostRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var stationName: String
    var provider: RelayProviderType
    var rawAmount: Double
    var exchangeRate: Double
    var convertedCost: Double
    var requests: Int64
    var tokens: Int64
    var errorMessage: String?
}

struct SalesRecord: Codable, Hashable {
    var stationID: UUID?
    var stationName: String
    var provider: RelayProviderType?
    var usageScope: UsageScope?
    var rawAmount: Double
    var exchangeRate: Double
    var convertedRevenue: Double
    var requests: Int64
    var tokens: Int64
    var errorMessage: String?
}

struct DailyProfitRecord: Identifiable, Codable, Hashable {
    /// Canonical calendar date key: "yyyy-MM-dd"
    var id: String { dateKey }
    var dateKey: String
    var date: Date
    var currency: DisplayCurrency
    var sales: SalesRecord?
    var revenue: Double
    var channelCosts: [ChannelCostRecord]
    var totalChannelCost: Double
    var fixedCostItems: [FixedCostItem]
    var fixedCost: Double
    var totalCost: Double
    var netProfit: Double
    var profitMargin: Double
    var settledAt: Date
    var triggerSource: SettlementTrigger
    var note: String

    var hasAnyError: Bool {
        if sales?.errorMessage != nil { return true }
        return channelCosts.contains { $0.errorMessage != nil }
    }
}
