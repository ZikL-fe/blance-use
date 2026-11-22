import Foundation

enum Sub2APIClient {
    // MARK: - Login & Verification

    static func testAndLogin(
        station: RelayStation,
        credentials: StationSecretCredentials
    ) async throws -> StationConnectionResult {
        let session = RelayAPIService.makeEphemeralSession()
        var creds = credentials

        switch station.authMethod {
        case .password:
            let email = station.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty, let password = creds.password, !password.isEmpty else {
                throw RelayAPIError.missingCredentials("请输入邮箱和密码")
            }
            let loginData = try await performPasswordLogin(
                baseURL: station.normalizedBaseURL,
                email: email,
                password: password,
                session: session
            )
            creds.accessToken = loginData.accessToken
            if let refresh = loginData.refreshToken, !refresh.isEmpty {
                creds.refreshToken = refresh
            }
            let user = loginData.user
            let label = nonEmpty(user?.username) ?? nonEmpty(user?.email) ?? email
            return StationConnectionResult(
                accountLabel: label,
                detectedUserID: user?.id.map { String($0.value) },
                balanceUSD: user?.balance?.value,
                lifetimeUsedUSD: nil,
                detectedQuotaPerUnit: nil,
                updatedCredentials: creds
            )

        case .accessToken:
            guard let token = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw RelayAPIError.missingCredentials("请输入 Sub2API 访问令牌或 API Key")
            }
            creds.accessToken = token
            // First try standard JWT user profile endpoint
            do {
                let user = try await fetchProfile(
                    baseURL: station.normalizedBaseURL,
                    token: token,
                    session: session
                )
                let label = nonEmpty(user.username) ?? nonEmpty(user.email) ?? "Token 用户"
                return StationConnectionResult(
                    accountLabel: label,
                    detectedUserID: user.id.map { String($0.value) },
                    balanceUSD: user.balance?.value,
                    lifetimeUsedUSD: nil,
                    detectedQuotaPerUnit: nil,
                    updatedCredentials: creds
                )
            } catch {
                // Fallback for Sub2API API key (`sk-...`) via /v1/usage
                if token.lowercased().hasPrefix("sk-") {
                    let v1Usage = try await fetchV1UsageFallback(
                        baseURL: station.normalizedBaseURL,
                        apiKey: token,
                        session: session
                    )
                    return StationConnectionResult(
                        accountLabel: "API Key (\(token.prefix(10))...)",
                        detectedUserID: nil,
                        balanceUSD: v1Usage.balance?.value ?? v1Usage.remaining?.value,
                        lifetimeUsedUSD: v1Usage.totalUsed?.value,
                        detectedQuotaPerUnit: nil,
                        updatedCredentials: creds
                    )
                }
                throw error
            }
        }
    }

    // MARK: - Fetch Usage Snapshot

    static func fetchUsage(
        station: RelayStation,
        credentials: StationSecretCredentials,
        range: DateRangeSelection
    ) async throws -> (snapshot: StationUsageSnapshot, updatedCredentials: StationSecretCredentials, detectedUserID: String?, detectedQuotaPerUnit: Double?) {
        let session = RelayAPIService.makeEphemeralSession()
        var creds = credentials
        let baseURL = station.normalizedBaseURL

        // Ensure we have a valid access token
        if creds.accessToken == nil || creds.accessToken?.isEmpty == true {
            if station.authMethod == .password,
               let password = creds.password, !password.isEmpty,
               !station.accountIdentifier.isEmpty {
                let login = try await performPasswordLogin(
                    baseURL: baseURL,
                    email: station.accountIdentifier,
                    password: password,
                    session: session
                )
                creds.accessToken = login.accessToken
                if let refresh = login.refreshToken, !refresh.isEmpty {
                    creds.refreshToken = refresh
                }
            } else {
                throw RelayAPIError.missingCredentials("缺少访问令牌，请重新编辑中转站登录信息")
            }
        }

        guard var token = creds.accessToken, !token.isEmpty else {
            throw RelayAPIError.missingCredentials("访问令牌为空")
        }

        // If user logged in with an API Key (sk-...), try dashboard first then fallback to /v1/usage
        do {
            let result = try await fetchDashboardBundle(
                station: station,
                token: token,
                range: range,
                session: session
            )
            return (result.snapshot, creds, result.userID, nil)
        } catch RelayAPIError.unauthorized {
            // Try refresh token, then password re-login
            if let refresh = creds.refreshToken, !refresh.isEmpty,
               let refreshed = try? await performTokenRefresh(baseURL: baseURL, refreshToken: refresh, session: session),
               let newAccess = refreshed.accessToken, !newAccess.isEmpty {
                creds.accessToken = newAccess
                if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                    creds.refreshToken = newRefresh
                }
                token = newAccess
                let result = try await fetchDashboardBundle(
                    station: station,
                    token: token,
                    range: range,
                    session: session
                )
                return (result.snapshot, creds, result.userID, nil)
            }

            if station.authMethod == .password,
               let password = creds.password, !password.isEmpty,
               !station.accountIdentifier.isEmpty {
                let login = try await performPasswordLogin(
                    baseURL: baseURL,
                    email: station.accountIdentifier,
                    password: password,
                    session: session
                )
                if let newAccess = login.accessToken, !newAccess.isEmpty {
                    creds.accessToken = newAccess
                    if let newRefresh = login.refreshToken, !newRefresh.isEmpty {
                        creds.refreshToken = newRefresh
                    }
                    let result = try await fetchDashboardBundle(
                        station: station,
                        token: newAccess,
                        range: range,
                        session: session
                    )
                    return (result.snapshot, creds, result.userID, nil)
                }
            }

            if token.lowercased().hasPrefix("sk-") {
                let fallbackSnapshot = try await buildV1UsageFallbackSnapshot(
                    station: station,
                    apiKey: token,
                    range: range,
                    session: session
                )
                return (fallbackSnapshot, creds, nil, nil)
            }

            throw RelayAPIError.unauthorized("会话已失效，请在站点详情中重新登录")
        }
    }

    // MARK: - Internal Sub2API Requests

    private static func fetchDashboardBundle(
        station: RelayStation,
        token: String,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> (snapshot: StationUsageSnapshot, userID: String?) {
        let baseURL = station.normalizedBaseURL
        let interval = range.resolvedInterval
        let startDateStr = DateFormatters.apiDay.string(from: interval.start)
        let endDateStr = DateFormatters.apiDay.string(from: interval.end)
        let tz = TimeZone.current.identifier
        let granularity = range.granularity

        let isAdminScope = station.usageScope == .siteWideAdmin

        async let profileTask = fetchProfile(baseURL: baseURL, token: token, session: session)
        async let trendTask = fetchTrend(
            baseURL: baseURL,
            token: token,
            startDate: startDateStr,
            endDate: endDateStr,
            granularity: granularity,
            timezone: tz,
            adminScope: isAdminScope,
            session: session
        )
        async let modelsTask = fetchModels(
            baseURL: baseURL,
            token: token,
            startDate: startDateStr,
            endDate: endDateStr,
            timezone: tz,
            adminScope: isAdminScope,
            session: session
        )

        let profile = try await profileTask
        let trendPointsRaw = (try? await trendTask) ?? []
        let modelsRaw = (try? await modelsTask) ?? []

        let cal = Calendar.current
        let parsedPoints: [UsageBucketPoint] = trendPointsRaw.compactMap { pt in
            guard let date = DateFormatters.parseTrendDate(pt.date) else { return nil }
            let bucketKey: String
            let normalizedDate: Date
            if range.isSingleDay {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
                normalizedDate = cal.date(from: comps) ?? date
                bucketKey = DateFormatters.apiHour.string(from: normalizedDate)
            } else {
                normalizedDate = cal.startOfDay(for: date)
                bucketKey = DateFormatters.apiDay.string(from: normalizedDate)
            }
            let costUSD = pt.effectiveCostUSD
            let cacheTokens = (pt.cacheCreationTokens?.value ?? 0) + (pt.cacheReadTokens?.value ?? 0)
            let inputTokens = pt.inputTokens?.value ?? 0
            let outputTokens = pt.outputTokens?.value ?? 0
            let totalTokens = pt.totalTokens?.value ?? (inputTokens + outputTokens + cacheTokens)
            return UsageBucketPoint(
                bucketKey: bucketKey,
                date: normalizedDate,
                requests: pt.requests?.value ?? 0,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheTokens: cacheTokens,
                totalTokens: totalTokens,
                costUSD: costUSD,
                convertedCost: station.convertToDisplayCurrency(costUSD)
            )
        }

        let filledPoints = RelayAPIService.fillMissingBuckets(
            points: parsedPoints,
            range: range,
            exchangeRate: station.exchangeRate
        )

        let modelStats: [ModelUsageStat] = modelsRaw.map { m in
            let costUSD = m.effectiveCostUSD
            let cacheTokens = (m.cacheCreationTokens?.value ?? 0) + (m.cacheReadTokens?.value ?? 0)
            let inputTokens = m.inputTokens?.value ?? 0
            let outputTokens = m.outputTokens?.value ?? 0
            let totalTokens = m.totalTokens?.value ?? (inputTokens + outputTokens + cacheTokens)
            return ModelUsageStat(
                modelName: m.model.isEmpty ? "unknown" : m.model,
                requests: m.requests?.value ?? 0,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheTokens: cacheTokens,
                totalTokens: totalTokens,
                costUSD: costUSD,
                convertedCost: station.convertToDisplayCurrency(costUSD)
            )
        }
        .sorted { $0.convertedCost > $1.convertedCost }

        var totalCostUSD = filledPoints.reduce(0) { $0 + $1.costUSD }
        var totalRequests = filledPoints.reduce(Int64(0)) { $0 + $1.requests }
        var totalTokens = filledPoints.reduce(Int64(0)) { $0 + $1.totalTokens }
        let totalInput = filledPoints.reduce(Int64(0)) { $0 + $1.inputTokens }
        let totalOutput = filledPoints.reduce(Int64(0)) { $0 + $1.outputTokens }
        let totalCache = filledPoints.reduce(Int64(0)) { $0 + $1.cacheTokens }

        // If trend was empty but model stats exist, derive totals from models
        if totalCostUSD == 0 && !modelStats.isEmpty {
            totalCostUSD = modelStats.reduce(0) { $0 + $1.costUSD }
            totalRequests = modelStats.reduce(0) { $0 + $1.requests }
            totalTokens = modelStats.reduce(0) { $0 + $1.totalTokens }
        }

        let label = nonEmpty(profile.username) ?? nonEmpty(profile.email) ?? station.accountIdentifier
        let snapshot = StationUsageSnapshot(
            stationID: station.id,
            accountLabel: label.isEmpty ? station.name : label,
            balanceUSD: profile.balance?.value,
            lifetimeUsedUSD: nil,
            periodCostUSD: totalCostUSD,
            periodConvertedCost: station.convertToDisplayCurrency(totalCostUSD),
            periodRequests: totalRequests,
            periodTokens: totalTokens,
            periodInputTokens: totalInput,
            periodOutputTokens: totalOutput,
            periodCacheTokens: totalCache,
            dailyPoints: filledPoints,
            modelStats: modelStats,
            updatedAt: Date(),
            errorMessage: nil
        )

        return (snapshot, profile.id.map { String($0.value) })
    }

    private static func performPasswordLogin(
        baseURL: String,
        email: String,
        password: String,
        session: URLSession
    ) async throws -> Sub2APILoginData {
        guard let url = URL(string: "\(baseURL)/api/v1/auth/login") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password
        ])

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(Sub2APIEnvelope<Sub2APILoginData>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess, let loginData = envelope.data, let token = loginData.accessToken, !token.isEmpty else {
            let msg = envelope.message ?? "邮箱或密码错误（若站点开启了验证码或 2FA，请改用访问令牌登录）"
            throw httpResp.statusCode == 401 ? RelayAPIError.unauthorized(msg) : RelayAPIError.serverError(msg)
        }
        return loginData
    }

    private static func performTokenRefresh(
        baseURL: String,
        refreshToken: String,
        session: URLSession
    ) async throws -> Sub2APILoginData {
        guard let url = URL(string: "\(baseURL)/api/v1/auth/refresh") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken
        ])

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(Sub2APIEnvelope<Sub2APILoginData>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess, let refreshed = envelope.data else {
            throw RelayAPIError.unauthorized(envelope.message ?? "Refresh Token 已失效")
        }
        return refreshed
    }

    private static func fetchProfile(
        baseURL: String,
        token: String,
        session: URLSession
    ) async throws -> Sub2APIUserDTO {
        guard let url = URL(string: "\(baseURL)/api/v1/user/profile") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(Sub2APIEnvelope<Sub2APIUserDTO>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess, let user = envelope.data else {
            throw httpResp.statusCode == 401
                ? RelayAPIError.unauthorized(envelope.message ?? "Token 无效")
                : RelayAPIError.serverError(envelope.message ?? "获取用户信息失败")
        }
        return user
    }

    private static func fetchTrend(
        baseURL: String,
        token: String,
        startDate: String,
        endDate: String,
        granularity: String,
        timezone: String,
        adminScope: Bool,
        session: URLSession
    ) async throws -> [Sub2APITrendPoint] {
        let path = adminScope ? "/api/v1/admin/dashboard/trend" : "/api/v1/usage/dashboard/trend"
        var comps = URLComponents(string: "\(baseURL)\(path)")
        comps?.queryItems = [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "granularity", value: granularity),
            URLQueryItem(name: "timezone", value: timezone)
        ]
        guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(Sub2APIEnvelope<Sub2APITrendResponse>.self, from: data, statusCode: httpResp.statusCode)
        return envelope.data?.trend ?? []
    }

    private static func fetchModels(
        baseURL: String,
        token: String,
        startDate: String,
        endDate: String,
        timezone: String,
        adminScope: Bool,
        session: URLSession
    ) async throws -> [Sub2APIModelStatDTO] {
        let path = adminScope ? "/api/v1/admin/dashboard/models" : "/api/v1/usage/dashboard/models"
        var comps = URLComponents(string: "\(baseURL)\(path)")
        comps?.queryItems = [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "timezone", value: timezone)
        ]
        guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(Sub2APIEnvelope<Sub2APIModelsResponse>.self, from: data, statusCode: httpResp.statusCode)
        return envelope.data?.models ?? []
    }

    private static func fetchV1UsageFallback(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async throws -> Sub2APIV1UsageResponse {
        guard let url = URL(string: "\(baseURL)/v1/usage") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, httpResp) = try await execute(request, session: session)
        if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
            throw RelayAPIError.unauthorized("API Key 无效或无权访问 /v1/usage")
        }
        if let wrapped = try? JSONDecoder().decode(Sub2APIEnvelope<Sub2APIV1UsageResponse>.self, from: data),
           let inner = wrapped.data {
            return inner
        }
        if let direct = try? JSONDecoder().decode(Sub2APIV1UsageResponse.self, from: data) {
            return direct
        }
        throw RelayAPIError.decodingError("无法解析 Sub2API /v1/usage 响应")
    }

    private static func buildV1UsageFallbackSnapshot(
        station: RelayStation,
        apiKey: String,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> StationUsageSnapshot {
        let usage = try await fetchV1UsageFallback(baseURL: station.normalizedBaseURL, apiKey: apiKey, session: session)
        let costUSD = range.preset == .today
            ? (usage.todayCost?.value ?? usage.totalCost?.value ?? 0)
            : (usage.totalCost?.value ?? usage.totalUsed?.value ?? 0)
        let models = (usage.modelStats ?? []).map { m in
            let mCost = m.effectiveCostUSD
            return ModelUsageStat(
                modelName: m.model,
                requests: m.requests?.value ?? 0,
                inputTokens: m.inputTokens?.value ?? 0,
                outputTokens: m.outputTokens?.value ?? 0,
                cacheTokens: (m.cacheCreationTokens?.value ?? 0) + (m.cacheReadTokens?.value ?? 0),
                totalTokens: m.totalTokens?.value ?? 0,
                costUSD: mCost,
                convertedCost: station.convertToDisplayCurrency(mCost)
            )
        }
        let filled = RelayAPIService.fillMissingBuckets(points: [], range: range, exchangeRate: station.exchangeRate)
        return StationUsageSnapshot(
            stationID: station.id,
            accountLabel: "API Key 模式",
            balanceUSD: usage.balance?.value ?? usage.remaining?.value,
            lifetimeUsedUSD: usage.totalUsed?.value,
            periodCostUSD: costUSD,
            periodConvertedCost: station.convertToDisplayCurrency(costUSD),
            periodRequests: usage.totalRequests?.value ?? 0,
            periodTokens: usage.totalTokens?.value ?? 0,
            periodInputTokens: 0,
            periodOutputTokens: 0,
            periodCacheTokens: 0,
            dailyPoints: filled,
            modelStats: models,
            updatedAt: Date(),
            errorMessage: nil
        )
    }

    // MARK: - Helpers

    private static func execute(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                throw RelayAPIError.networkError("无效的服务器响应")
            }
            return (data, httpResp)
        } catch let error as RelayAPIError {
            throw error
        } catch {
            throw RelayAPIError.networkError(error.localizedDescription)
        }
    }

    private static func decodeEnvelope<T: Decodable>(
        _ type: Sub2APIEnvelope<T>.Type,
        from data: Data,
        statusCode: Int
    ) throws -> Sub2APIEnvelope<T> {
        if let decoded = try? JSONDecoder().decode(type, from: data) {
            if statusCode == 401 {
                throw RelayAPIError.unauthorized(decoded.message ?? "未授权访问")
            }
            if statusCode >= 400 {
                throw RelayAPIError.httpError(statusCode, decoded.message ?? "请求失败")
            }
            return decoded
        }
        if statusCode == 401 {
            throw RelayAPIError.unauthorized("登录凭据无效或已过期")
        }
        if statusCode >= 400 {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw RelayAPIError.httpError(statusCode, body.isEmpty ? "请求失败" : body)
        }
        throw RelayAPIError.decodingError("返回内容不是有效的 Sub2API JSON")
    }

    private static func nonEmpty(_ str: String?) -> String? {
        guard let trimmed = str?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
