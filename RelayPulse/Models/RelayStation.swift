import Foundation
import SwiftUI

enum RelayProviderType: String, Codable, CaseIterable, Identifiable {
    case sub2api = "sub2api"
    case newAPI = "newapi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sub2api: return "Sub2API"
        case .newAPI: return "NewAPI"
        }
    }

    var subtitle: String {
        switch self {
        case .sub2api: return "订阅池化中转站 (Wei-Shaw/sub2api)"
        case .newAPI: return "NewAPI / OneAPI 兼容中转站"
        }
    }

    var badgeColor: Color {
        switch self {
        case .sub2api: return Color(hex: "#38BDF8")
        case .newAPI: return Color(hex: "#A855F7")
        }
    }

    var iconName: String {
        switch self {
        case .sub2api: return "sparkles.rectangle.stack.fill"
        case .newAPI: return "cpu.fill"
        }
    }

    var accountPlaceholder: String {
        switch self {
        case .sub2api: return "邮箱 (Email)"
        case .newAPI: return "用户名 (Username)"
        }
    }

    var tokenPlaceholder: String {
        switch self {
        case .sub2api: return "JWT 访问令牌 或 API Key (sk-...)"
        case .newAPI: return "系统访问令牌 (Personal Access Token)"
        }
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

struct RelayStation: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var provider: RelayProviderType
    var baseURL: String
    var authMethod: AuthMethod
    /// Email for Sub2API or Username for NewAPI (non-secret identifier)
    var accountIdentifier: String
    /// Optional numeric User ID for NewAPI (`New-Api-User` header)
    var userID: String
    /// Real-world billing conversion rate: 1 USD quota = `exchangeRate` in user's display currency
    /// Example: Station sells $1 quota for ¥2.0 -> exchangeRate = 2.0
    var exchangeRate: Double
    /// Quota points per 1 USD for NewAPI (default 500,000, auto-detected via /api/status)
    var quotaPerUnit: Double
    /// Accent color hex for station charts & badges
    var accentHex: String
    /// Whether included in Overview totals
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        provider: RelayProviderType,
        baseURL: String,
        authMethod: AuthMethod,
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
        self.accountIdentifier = accountIdentifier
        self.userID = userID
        self.exchangeRate = max(exchangeRate, 0.0001)
        self.quotaPerUnit = max(quotaPerUnit, 1)
        self.accentHex = accentHex
        self.isEnabled = isEnabled
        self.createdAt = createdAt
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
