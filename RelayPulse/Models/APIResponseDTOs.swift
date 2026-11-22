import Foundation

// MARK: - Tolerant JSON Primitives

/// Decodes Double even if server returns Int or String number
struct FlexibleDouble: Decodable {
    let value: Double

    init(_ value: Double = 0) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let i = try? container.decode(Int64.self) {
            self.value = Double(i)
        } else if let s = try? container.decode(String.self), let d = Double(s) {
            self.value = d
        } else {
            self.value = 0
        }
    }
}

/// Decodes Int64 even if server returns Double or String
struct FlexibleInt64: Decodable {
    let value: Int64

    init(_ value: Int64 = 0) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int64.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = Int64(d)
        } else if let s = try? container.decode(String.self), let i = Int64(s) {
            self.value = i
        } else {
            self.value = 0
        }
    }
}

// MARK: - Sub2API DTOs (Wei-Shaw/sub2api)

struct Sub2APIEnvelope<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?

    var isSuccess: Bool {
        (code ?? 0) == 0
    }
}

struct Sub2APILoginData: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let user: Sub2APIUserDTO?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case user
    }
}

struct Sub2APIUserDTO: Decodable {
    let id: FlexibleInt64?
    let email: String?
    let username: String?
    let role: String?
    let balance: FlexibleDouble?
    let frozenBalance: FlexibleDouble?
    let totalRecharged: FlexibleDouble?

    enum CodingKeys: String, CodingKey {
        case id, email, username, role, balance
        case frozenBalance = "frozen_balance"
        case totalRecharged = "total_recharged"
    }
}

struct Sub2APITrendResponse: Decodable {
    let trend: [Sub2APITrendPoint]?
    let startDate: String?
    let endDate: String?
    let granularity: String?

    enum CodingKeys: String, CodingKey {
        case trend
        case startDate = "start_date"
        case endDate = "end_date"
        case granularity
    }
}

struct Sub2APITrendPoint: Decodable {
    let date: String
    let requests: FlexibleInt64?
    let inputTokens: FlexibleInt64?
    let outputTokens: FlexibleInt64?
    let cacheCreationTokens: FlexibleInt64?
    let cacheReadTokens: FlexibleInt64?
    let totalTokens: FlexibleInt64?
    let cost: FlexibleDouble?
    let actualCost: FlexibleDouble?

    enum CodingKeys: String, CodingKey {
        case date, requests, cost
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case totalTokens = "total_tokens"
        case actualCost = "actual_cost"
    }

    var effectiveCostUSD: Double {
        if let actual = actualCost?.value, actual > 0 {
            return actual
        }
        return cost?.value ?? 0
    }
}

struct Sub2APIModelsResponse: Decodable {
    let models: [Sub2APIModelStatDTO]?
}

struct Sub2APIModelStatDTO: Decodable {
    let model: String
    let requests: FlexibleInt64?
    let inputTokens: FlexibleInt64?
    let outputTokens: FlexibleInt64?
    let cacheCreationTokens: FlexibleInt64?
    let cacheReadTokens: FlexibleInt64?
    let totalTokens: FlexibleInt64?
    let cost: FlexibleDouble?
    let actualCost: FlexibleDouble?

    enum CodingKeys: String, CodingKey {
        case model, requests, cost
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case totalTokens = "total_tokens"
        case actualCost = "actual_cost"
    }

    var effectiveCostUSD: Double {
        if let actual = actualCost?.value, actual > 0 {
            return actual
        }
        return cost?.value ?? 0
    }
}

struct Sub2APIDashboardStatsDTO: Decodable {
    let totalRequests: FlexibleInt64?
    let totalTokens: FlexibleInt64?
    let totalCost: FlexibleDouble?
    let totalActualCost: FlexibleDouble?
    let todayRequests: FlexibleInt64?
    let todayTokens: FlexibleInt64?
    let todayCost: FlexibleDouble?
    let todayActualCost: FlexibleDouble?

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case totalTokens = "total_tokens"
        case totalCost = "total_cost"
        case totalActualCost = "total_actual_cost"
        case todayRequests = "today_requests"
        case todayTokens = "today_tokens"
        case todayCost = "today_cost"
        case todayActualCost = "today_actual_cost"
    }
}

/// Fallback `/v1/usage` payload for Sub2API API Key mode
struct Sub2APIV1UsageResponse: Decodable {
    let isActive: Bool?
    let balance: FlexibleDouble?
    let remaining: FlexibleDouble?
    let totalUsed: FlexibleDouble?
    let todayCost: FlexibleDouble?
    let totalCost: FlexibleDouble?
    let totalRequests: FlexibleInt64?
    let totalTokens: FlexibleInt64?
    let modelStats: [Sub2APIModelStatDTO]?

    enum CodingKeys: String, CodingKey {
        case isActive = "is_active"
        case balance, remaining
        case totalUsed = "total_used"
        case todayCost = "today_cost"
        case totalCost = "total_cost"
        case totalRequests = "total_requests"
        case totalTokens = "total_tokens"
        case modelStats = "model_stats"
    }
}

// MARK: - NewAPI / OneAPI DTOs (QuantumNous/new-api)

struct NewAPIEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let message: String?
    let data: T?

    var isSuccess: Bool {
        success ?? false
    }
}

struct NewAPIStatusDTO: Decodable {
    let quotaPerUnit: FlexibleDouble?
    let systemName: String?

    enum CodingKeys: String, CodingKey {
        case quotaPerUnit = "quota_per_unit"
        case systemName = "system_name"
    }
}

struct NewAPIUserDTO: Decodable {
    let id: FlexibleInt64?
    let username: String?
    let displayName: String?
    let email: String?
    let quota: FlexibleDouble?
    let usedQuota: FlexibleDouble?
    let requestCount: FlexibleInt64?
    let group: String?

    enum CodingKeys: String, CodingKey {
        case id, username, email, quota, group
        case displayName = "display_name"
        case usedQuota = "used_quota"
        case requestCount = "request_count"
    }
}

struct NewAPIQuotaDataDTO: Decodable {
    let id: FlexibleInt64?
    let modelName: String?
    let createdAt: FlexibleInt64?
    let tokenUsed: FlexibleInt64?
    let count: FlexibleInt64?
    let quota: FlexibleDouble?
    let cacheReadTokens: FlexibleInt64?
    let cacheCreationTokens: FlexibleInt64?

    enum CodingKeys: String, CodingKey {
        case id, count, quota
        case modelName = "model_name"
        case createdAt = "created_at"
        case tokenUsed = "token_used"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
    }
}

struct NewAPILogPageDTO: Decodable {
    let items: [NewAPILogItemDTO]?
    let total: FlexibleInt64?
}

struct NewAPILogItemDTO: Decodable {
    let id: FlexibleInt64?
    let createdAt: FlexibleInt64?
    let type: FlexibleInt64?
    let modelName: String?
    let quota: FlexibleDouble?
    let promptTokens: FlexibleInt64?
    let completionTokens: FlexibleInt64?

    enum CodingKeys: String, CodingKey {
        case id, type, quota
        case createdAt = "created_at"
        case modelName = "model_name"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

/// Fallback `/api/usage/token` payload for `sk-...` API keys on NewAPI
struct NewAPITokenUsageDTO: Decodable {
    let code: Bool?
    let message: String?
    let data: NewAPITokenUsageData?
}

struct NewAPITokenUsageData: Decodable {
    let object: String?
    let name: String?
    let totalGranted: FlexibleDouble?
    let totalUsed: FlexibleDouble?
    let totalAvailable: FlexibleDouble?
    let unlimitedQuota: Bool?

    enum CodingKeys: String, CodingKey {
        case object, name
        case totalGranted = "total_granted"
        case totalUsed = "total_used"
        case totalAvailable = "total_available"
        case unlimitedQuota = "unlimited_quota"
    }
}

// MARK: - ReMail OpenAPI DTOs (https://remail.best/openapi.json)

struct RemailErrorResponse: Decodable {
    let code: String?
    let message: String?
    let requestId: String?
}

struct RemailAPIKeyProfileResponse: Decodable {
    let apiKey: RemailAPIKeyProfileDTO?
}

struct RemailAPIKeyProfileDTO: Decodable {
    let id: FlexibleInt64?
    let name: String?
    let keyPrefix: String?
    let enabled: Bool?
    let quotaLimit: FlexibleInt64?
    let quotaUsed: FlexibleDouble?
    let remainingQuota: FlexibleDouble?
    let balance: FlexibleDouble?
    let requestCount: FlexibleInt64?
    let lastUsedAt: String?
    let expireAt: String?
}

struct RemailWalletDTO: Decodable {
    let userId: FlexibleInt64?
    let consumerBalance: FlexibleDouble?
    let supplierAvailable: FlexibleDouble?
    let supplierFrozen: FlexibleDouble?
    let totalRecharged: FlexibleDouble?
    let historicalSpend: FlexibleDouble?
    let orderCount: FlexibleInt64?
    let updatedAt: String?
}

struct RemailOrderListResponse: Decodable {
    let items: [RemailOrderDTO]?
    let total: FlexibleInt64?
    let offset: FlexibleInt64?
    let nextAfterId: FlexibleInt64?
    let hasNext: Bool?
    let limit: FlexibleInt64?
}

struct RemailOrderDTO: Decodable {
    let id: FlexibleInt64?
    let orderNo: String?
    let projectId: FlexibleInt64?
    let projectName: String?
    let productType: String?
    let serviceMode: String?
    let status: String?
    let payAmount: FlexibleDouble?
    let refundAmount: FlexibleDouble?
    let deliveryEmail: String?
    let createdAt: String?
    let updatedAt: String?
}

struct RemailTransactionListResponse: Decodable {
    let items: [RemailTransactionDTO]?
    let nextAfterId: FlexibleInt64?
    let hasNext: Bool?
    let limit: FlexibleInt64?
}

struct RemailTransactionDTO: Decodable {
    let id: FlexibleInt64?
    let transactionNo: String?
    let transactionType: String?
    let balanceBucket: String?
    let direction: String?
    let amount: FlexibleDouble?
    let balanceBefore: FlexibleDouble?
    let balanceAfter: FlexibleDouble?
    let bizType: String?
    let bizId: String?
    let createdAt: String?
}
