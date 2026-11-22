import Foundation
import SwiftUI

enum RelayProviderType: String, Codable, CaseIterable, Identifiable {
    case sub2api = "sub2api"
    case newAPI = "newapi"
    case remail = "remail"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sub2api: return "Sub2API"
        case .newAPI: return "NewAPI"
        case .remail: return "ReMail"
        }
    }

    var shortSubtitle: String {
        switch self {
        case .sub2api: return "订阅池化网关"
        case .newAPI: return "NewAPI / OneAPI"
        case .remail: return "轻松收码 API"
        }
    }

    var subtitle: String {
        switch self {
        case .sub2api: return "订阅池化中转站 (Wei-Shaw/sub2api)"
        case .newAPI: return "NewAPI / OneAPI 兼容中转站"
        case .remail: return "ReMail 轻松收码平台 (remail.best)"
        }
    }

    var badgeColor: Color {
        switch self {
        case .sub2api: return Color(hex: "#38BDF8")
        case .newAPI: return Color(hex: "#A855F7")
        case .remail: return Color(hex: "#F59E0B")
        }
    }

    var iconName: String {
        switch self {
        case .sub2api: return "sparkles.rectangle.stack.fill"
        case .newAPI: return "cpu.fill"
        case .remail: return "envelope.badge.shield.half.filled.fill"
        }
    }

    var supportsPasswordLogin: Bool {
        switch self {
        case .sub2api, .newAPI: return true
        case .remail: return false
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .sub2api: return ""
        case .newAPI: return ""
        case .remail: return "https://remail.best"
        }
    }

    var usesPointsUnit: Bool {
        self == .remail
    }

    var unitName: String {
        usesPointsUnit ? "积分" : "USD"
    }

    var unitShortPrefix: String {
        usesPointsUnit ? "1积分" : "1$"
    }

    var requestMetricName: String {
        usesPointsUnit ? "订单数" : "请求次数"
    }

    var requestUnitLabel: String {
        usesPointsUnit ? "单" : "次"
    }

    var breakdownTitle: String {
        usesPointsUnit ? "项目 / 邮箱类型消耗明细" : "站点模型消耗明细"
    }

    var breakdownItemUnit: String {
        usesPointsUnit ? "个项目" : "个模型"
    }

    var accountPlaceholder: String {
        switch self {
        case .sub2api: return "邮箱 (Email)"
        case .newAPI: return "用户名 (Username)"
        case .remail: return "邮箱 (Email)"
        }
    }

    var tokenPlaceholder: String {
        switch self {
        case .sub2api: return "JWT 访问令牌 或 API Key (sk-...)"
        case .newAPI: return "系统访问令牌 (Personal Access Token)"
        case .remail: return "ReMail API Key (rk-...)"
        }
    }

    var quickExchangeRatePresets: [Double] {
        switch self {
        case .sub2api, .newAPI:
            return [1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 7.2]
        case .remail:
            return [0.01, 0.1, 0.5, 1.0, 2.0, 7.2]
        }
    }

    func formatRawAmount(_ amount: Double) -> String {
        if usesPointsUnit {
            let safe = amount.isFinite ? amount : 0
            if abs(safe) > 0 && abs(safe) < 0.01 {
                return "\(String(format: "%.4f", safe)) 积分"
            }
            return "\(String(format: "%.2f", safe)) 积分"
        }
        return ValueFormatter.usd(amount)
    }
}

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password = "password"
    case accessToken = "access_token"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return "账号密码登录"
        case .accessToken: return "访问令牌登录"
        }
    }

    var shortName: String {
        switch self {
        case .password: return "账号密码"
        case .accessToken: return "访问令牌"
        }
    }

    var iconName: String {
        switch self {
        case .password: return "person.badge.key.fill"
        case .accessToken: return "key.horizontal.fill"
        }
    }
}

enum StationRole: String, Codable, CaseIterable, Identifiable {
    case costChannel = "cost_channel"
    case primarySales = "primary_sales"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .costChannel: return "上游成本渠道"
        case .primarySales: return "主站点（销售额）"
        }
    }

    var shortBadge: String {
        switch self {
        case .costChannel: return "成本渠道"
        case .primarySales: return "主站点·销售"
        }
    }

    var iconName: String {
        switch self {
        case .costChannel: return "arrow.down.left.circle.fill"
        case .primarySales: return "crown.fill"
        }
    }
}

enum UsageScope: String, Codable, CaseIterable, Identifiable {
    case personalSelf = "personal_self"
    case siteWideAdmin = "site_wide_admin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .personalSelf: return "当前账号消耗（个人接口）"
        case .siteWideAdmin: return "全站总消耗（管理员接口）"
        }
    }

    var shortName: String {
        switch self {
        case .personalSelf: return "个人口径"
        case .siteWideAdmin: return "全站口径"
        }
    }
}

struct RelayStation: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var provider: RelayProviderType
    var baseURL: String
    var authMethod: AuthMethod
    /// Role in profit accounting: cost channel vs primary sales station
    var role: StationRole
    /// Query scope: personal usage vs site-wide admin total (for primary sales NewAPI/Sub2API)
    var usageScope: UsageScope
    /// Email for Sub2API or Username for NewAPI (non-secret identifier)
    var accountIdentifier: String
    /// Optional numeric User ID for NewAPI (`New-Api-User` header)
    var userID: String
    /// Real-world billing conversion rate: 1 USD quota (or 1 ReMail point) = `exchangeRate` in user's display currency
    var exchangeRate: Double
    /// Quota points per 1 USD for NewAPI (default 500,000, auto-detected via /api/status)
    var quotaPerUnit: Double
    /// Accent color hex for station charts & badges
    var accentHex: String
    /// Whether included in Overview / Settlement calculations
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        provider: RelayProviderType,
        baseURL: String,
        authMethod: AuthMethod,
        role: StationRole = .costChannel,
        usageScope: UsageScope = .personalSelf,
        accountIdentifier: String = "",
        userID: String = "",
        exchangeRate: Double = 7.2,
        quotaPerUnit: Double = 500_000,
        accentHex: String = "#38BDF8",
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = RelayStation.normalizeBaseURL(baseURL)
        self.authMethod = authMethod
        self.role = provider == .remail ? .costChannel : role
        self.usageScope = provider == .remail ? .personalSelf : usageScope
        self.accountIdentifier = accountIdentifier
        self.userID = userID
        self.exchangeRate = max(exchangeRate, 0.0001)
        self.quotaPerUnit = max(quotaPerUnit, 1)
        self.accentHex = accentHex
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, baseURL, authMethod, role, usageScope
        case accountIdentifier, userID, exchangeRate, quotaPerUnit, accentHex, isEnabled, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(RelayProviderType.self, forKey: .provider)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
        role = try c.decodeIfPresent(StationRole.self, forKey: .role) ?? .costChannel
        usageScope = try c.decodeIfPresent(UsageScope.self, forKey: .usageScope) ?? .personalSelf
        accountIdentifier = try c.decodeIfPresent(String.self, forKey: .accountIdentifier) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        exchangeRate = try c.decodeIfPresent(Double.self, forKey: .exchangeRate) ?? 7.2
        quotaPerUnit = try c.decodeIfPresent(Double.self, forKey: .quotaPerUnit) ?? 500_000
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? "#38BDF8"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var accentColor: Color {
        Color(hex: accentHex)
    }

    var normalizedBaseURL: String {
        RelayStation.normalizeBaseURL(baseURL)
    }

    var hostLabel: String {
        if let url = URL(string: normalizedBaseURL), let host = url.host {
            return host
        }
        return normalizedBaseURL
    }

    func convertToDisplayCurrency(_ usdAmount: Double) -> Double {
        usdAmount * exchangeRate
    }

    static func normalizeBaseURL(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty && !cleaned.lowercased().hasPrefix("http://") && !cleaned.lowercased().hasPrefix("https://") {
            cleaned = "https://" + cleaned
        }
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        for suffix in ["/api/v1", "/v1", "/api"] {
            if cleaned.lowercased().hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                while cleaned.hasSuffix("/") {
                    cleaned.removeLast()
                }
                break
            }
        }
        return cleaned
    }

    static let presetAccentHexes: [String] = [
        "#38BDF8", // Sky Cyan
        "#6366F1", // Electric Indigo
        "#A855F7", // Prism Violet
        "#EC4899", // Rose Quartz
        "#F59E0B", // Amber Gold
        "#10B981", // Emerald Mint
        "#14B8A6", // Deep Teal
        "#F97316"  // Coral Orange
    ]
}

struct StationSecretCredentials: Codable {
    var password: String?
    var accessToken: String?
    var refreshToken: String?
    var sessionCookie: String?
}
