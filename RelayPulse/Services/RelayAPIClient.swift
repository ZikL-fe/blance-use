import Foundation

enum RelayAPIError: LocalizedError {
    case invalidURL(String)
    case missingCredentials(String)
    case unauthorized(String)
    case httpError(Int, String)
    case serverError(String)
    case decodingError(String)
    case networkError(String)
    case timeout(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "站点地址无效：\(url)"
        case .missingCredentials(let detail):
            return "缺少认证凭据：\(detail)"
        case .unauthorized(let msg):
            return "认证失败或登录已过期：\(msg)"
        case .httpError(let code, let msg):
            return "HTTP \(code)：\(msg)"
        case .serverError(let msg):
            return msg.isEmpty ? "服务端返回错误" : msg
        case .decodingError(let msg):
            return "数据解析失败：\(msg)"
        case .networkError(let msg):
            return "网络连接异常：\(msg)"
        case .timeout(let seconds):
            return "请求超过 \(seconds) 秒未返回数据"
        }
    }
}

struct StationConnectionResult {
    var accountLabel: String
    var detectedUserID: String?
    var balanceUSD: Double?
    var lifetimeUsedUSD: Double?
    var detectedQuotaPerUnit: Double?
    var updatedCredentials: StationSecretCredentials
}

enum RelayAPIService {
    static let defaultTimeoutSeconds: Int = 30

    static func makeEphemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    static func testAndLogin(
        station: RelayStation,
        credentials: StationSecretCredentials
    ) async throws -> StationConnectionResult {
        let start = Date()
        do {
            let result: StationConnectionResult = try await withOperationTimeout(seconds: defaultTimeoutSeconds) {
                switch station.provider {
                case .sub2api:
                    return try await Sub2APIClient.testAndLogin(station: station, credentials: credentials)
                case .newAPI:
                    return try await NewAPIClient.testAndLogin(station: station, credentials: credentials)
                case .remail:
                    return try await RemailAPIClient.testAndLogin(station: station, credentials: credentials)
                }
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            await AuditLogStore.shared.log(
                .info,
                category: .auth,
                station: station.name,
                message: "连接验证成功（\(station.provider.displayName)）",
                detail: "账号: \(result.accountLabel)",
                durationMs: elapsed
            )
            return result
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            await AuditLogStore.shared.log(
                .error,
                category: .auth,
                station: station.name,
                message: "连接验证失败（\(station.provider.displayName)）",
                detail: error.localizedDescription,
                durationMs: elapsed
            )
            throw error
        }
    }

    static func fetchUsage(
        station: RelayStation,
        credentials: StationSecretCredentials,
        range: DateRangeSelection,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) async throws -> (snapshot: StationUsageSnapshot, updatedCredentials: StationSecretCredentials, detectedUserID: String?, detectedQuotaPerUnit: Double?) {
        try await withOperationTimeout(seconds: timeoutSeconds) {
            switch station.provider {
            case .sub2api:
                return try await Sub2APIClient.fetchUsage(station: station, credentials: credentials, range: range)
            case .newAPI:
                return try await NewAPIClient.fetchUsage(station: station, credentials: credentials, range: range)
            case .remail:
                return try await RemailAPIClient.fetchUsage(station: station, credentials: credentials, range: range)
            }
        }
    }

    /// Enforces a strict total wall-clock timeout across multi-request or paginated operations.
    static func withOperationTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clampedSeconds = max(1, seconds)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(clampedSeconds))
                throw RelayAPIError.timeout(clampedSeconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw RelayAPIError.timeout(clampedSeconds)
            }
            return first
        }
    }

    /// Ensures every day or hour in the requested interval has a bucket point so charts are continuous.
    static func fillMissingBuckets(
        points: [UsageBucketPoint],
        range: DateRangeSelection,
        exchangeRate: Double
    ) -> [UsageBucketPoint] {
        let interval = range.resolvedInterval
        let cal = Calendar.current
        var map: [String: UsageBucketPoint] = [:]
        for p in points {
            if let existing = map[p.bucketKey] {
                map[p.bucketKey] = UsageBucketPoint(
                    bucketKey: p.bucketKey,
                    date: existing.date,
                    requests: existing.requests + p.requests,
                    inputTokens: existing.inputTokens + p.inputTokens,
                    outputTokens: existing.outputTokens + p.outputTokens,
                    cacheTokens: existing.cacheTokens + p.cacheTokens,
                    totalTokens: existing.totalTokens + p.totalTokens,
                    costUSD: existing.costUSD + p.costUSD,
                    convertedCost: (existing.costUSD + p.costUSD) * exchangeRate
                )
            } else {
                map[p.bucketKey] = p
            }
        }

        var result: [UsageBucketPoint] = []
        if range.isSingleDay {
            let startOfDay = cal.startOfDay(for: interval.start)
            let maxHour: Int
            if cal.isDateInToday(interval.start) {
                maxHour = max(cal.component(.hour, from: Date()), 1)
            } else {
                maxHour = 23
            }
            for hour in 0...maxHour {
                guard let bucketDate = cal.date(byAdding: .hour, value: hour, to: startOfDay) else { continue }
                let key = DateFormatters.apiHour.string(from: bucketDate)
                if let hit = map[key] {
                    result.append(hit)
                } else {
                    result.append(UsageBucketPoint(
                        bucketKey: key,
                        date: bucketDate,
                        requests: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        cacheTokens: 0,
                        totalTokens: 0,
                        costUSD: 0,
                        convertedCost: 0
                    ))
                }
            }
        } else {
            var cursor = cal.startOfDay(for: interval.start)
            let endDay = cal.startOfDay(for: interval.end)
            var guardCount = 0
            while cursor <= endDay && guardCount < 400 {
                let key = DateFormatters.apiDay.string(from: cursor)
                if let hit = map[key] {
                    result.append(hit)
                } else {
                    result.append(UsageBucketPoint(
                        bucketKey: key,
                        date: cursor,
                        requests: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        cacheTokens: 0,
                        totalTokens: 0,
                        costUSD: 0,
                        convertedCost: 0
                    ))
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                guardCount += 1
            }
        }

        return result.sorted { $0.date < $1.date }
    }
}
