import Foundation

enum NewAPIClient {
    // MARK: - Login & Verification

    static func testAndLogin(
        station: RelayStation,
        credentials: StationSecretCredentials
    ) async throws -> StationConnectionResult {
        let session = RelayAPIService.makeEphemeralSession()
        let baseURL = station.normalizedBaseURL
        var creds = credentials

        // Detect quota_per_unit via /api/status (defaults to station.quotaPerUnit / 500,000)
        let quotaPerUnit = (try? await fetchQuotaPerUnit(baseURL: baseURL, session: session)) ?? station.quotaPerUnit

        switch station.authMethod {
        case .password:
            let username = station.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty, let password = creds.password, !password.isEmpty else {
                throw RelayAPIError.missingCredentials("请输入用户名和密码")
            }
            let (user, cookieHeader) = try await performPasswordLogin(
                baseURL: baseURL,
                username: username,
                password: password,
                session: session
            )
            creds.sessionCookie = cookieHeader
            let userIDStr = user.id.map { String($0.value) }
            let balanceUSD = user.quota.map { $0.value / quotaPerUnit }
            let usedUSD = user.usedQuota.map { $0.value / quotaPerUnit }
            let label = nonEmpty(user.displayName) ?? nonEmpty(user.username) ?? username
            return StationConnectionResult(
                accountLabel: label,
                detectedUserID: userIDStr,
                balanceUSD: balanceUSD,
                lifetimeUsedUSD: usedUSD,
                detectedQuotaPerUnit: quotaPerUnit,
                updatedCredentials: creds
            )

        case .accessToken:
            guard let token = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw RelayAPIError.missingCredentials("请输入 NewAPI 系统访问令牌")
            }
            creds.accessToken = token
            do {
                let user = try await fetchSelfUser(
                    baseURL: baseURL,
                    cookie: nil,
                    token: token,
                    userID: station.userID,
                    session: session
                )
                let userIDStr = user.id.map { String($0.value) } ?? nonEmpty(station.userID)
                let balanceUSD = user.quota.map { $0.value / quotaPerUnit }
                let usedUSD = user.usedQuota.map { $0.value / quotaPerUnit }
                let label = nonEmpty(user.displayName) ?? nonEmpty(user.username) ?? "NewAPI 用户"
                return StationConnectionResult(
                    accountLabel: label,
                    detectedUserID: userIDStr,
                    balanceUSD: balanceUSD,
                    lifetimeUsedUSD: usedUSD,
                    detectedQuotaPerUnit: quotaPerUnit,
                    updatedCredentials: creds
                )
            } catch {
                // Fallback if user pasted an API key (sk-...) instead of System Access Token
                if token.lowercased().hasPrefix("sk-") {
                    let tokenUsage = try await fetchTokenUsageFallback(
                        baseURL: baseURL,
                        apiKey: token,
                        session: session
                    )
                    let avail = tokenUsage.totalAvailable.map { $0.value / quotaPerUnit }
                    let used = tokenUsage.totalUsed.map { $0.value / quotaPerUnit }
                    return StationConnectionResult(
                        accountLabel: nonEmpty(tokenUsage.name) ?? "API Key 令牌",
                        detectedUserID: nil,
                        balanceUSD: avail,
                        lifetimeUsedUSD: used,
                        detectedQuotaPerUnit: quotaPerUnit,
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
        let baseURL = station.normalizedBaseURL
        var creds = credentials
        var activeUserID = station.userID

        let quotaPerUnit = (try? await fetchQuotaPerUnit(baseURL: baseURL, session: session)) ?? station.quotaPerUnit

        // Ensure password-mode session cookie exists
        if station.authMethod == .password && (creds.sessionCookie == nil || creds.sessionCookie?.isEmpty == true) {
            if let password = creds.password, !password.isEmpty, !station.accountIdentifier.isEmpty {
                let (loginUser, cookie) = try await performPasswordLogin(
                    baseURL: baseURL,
                    username: station.accountIdentifier,
                    password: password,
                    session: session
                )
                creds.sessionCookie = cookie
                if let idVal = loginUser.id?.value {
                    activeUserID = String(idVal)
                }
            } else {
                throw RelayAPIError.missingCredentials("缺少账号密码凭据")
            }
        }

        // Fetch profile (auto re-login once if cookie expired)
        let user: NewAPIUserDTO
        do {
            user = try await fetchSelfUser(
                baseURL: baseURL,
                cookie: station.authMethod == .password ? creds.sessionCookie : nil,
                token: station.authMethod == .accessToken ? creds.accessToken : nil,
                userID: activeUserID,
                session: session
            )
        } catch RelayAPIError.unauthorized {
            if station.authMethod == .password,
               let password = creds.password, !password.isEmpty,
               !station.accountIdentifier.isEmpty {
                let (loginUser, cookie) = try await performPasswordLogin(
                    baseURL: baseURL,
                    username: station.accountIdentifier,
                    password: password,
                    session: session
                )
                creds.sessionCookie = cookie
                if let idVal = loginUser.id?.value {
                    activeUserID = String(idVal)
                }
                user = loginUser
            } else if station.authMethod == .accessToken,
                      let token = creds.accessToken, token.lowercased().hasPrefix("sk-") {
                let fallback = try await buildTokenUsageFallbackSnapshot(
                    station: station,
                    apiKey: token,
                    quotaPerUnit: quotaPerUnit,
                    range: range,
                    session: session
                )
                return (fallback, creds, nil, quotaPerUnit)
            } else {
                throw RelayAPIError.unauthorized("NewAPI 访问令牌或 User ID 无效，请检查站点设置")
            }
        }

        if let idVal = user.id?.value {
            activeUserID = String(idVal)
        }

        let cookieToUse = station.authMethod == .password ? creds.sessionCookie : nil
        let tokenToUse = station.authMethod == .accessToken ? creds.accessToken : nil

        // Fetch usage data from /api/data/self (auto-chunking if range > 28 days)
        var quotaRecords: [NewAPIQuotaDataDTO] = []
        do {
            quotaRecords = try await fetchQuotaDataChunked(
                baseURL: baseURL,
                cookie: cookieToUse,
                token: tokenToUse,
                userID: activeUserID,
                range: range,
                session: session
            )
        } catch {
            // Fallback to /api/log/self on older One-API forks where /api/data/self is unavailable
            if let logs = try? await fetchLogsFallback(
                baseURL: baseURL,
                cookie: cookieToUse,
                token: tokenToUse,
                userID: activeUserID,
                range: range,
                session: session
            ) {
                quotaRecords = logs
            }
        }

        let snapshot = aggregateQuotaRecords(
            records: quotaRecords,
            user: user,
            station: station,
            quotaPerUnit: quotaPerUnit,
            range: range
        )

        return (snapshot, creds, nonEmpty(activeUserID), quotaPerUnit)
    }

    // MARK: - Aggregation

    private static func aggregateQuotaRecords(
        records: [NewAPIQuotaDataDTO],
        user: NewAPIUserDTO,
        station: RelayStation,
        quotaPerUnit: Double,
        range: DateRangeSelection
    ) -> StationUsageSnapshot {
        let cal = Calendar.current
        var bucketMap: [String: UsageBucketPoint] = [:]
        var modelMap: [String: ModelUsageStat] = [:]

        for rec in records {
            let ts = TimeInterval(rec.createdAt?.value ?? 0)
            guard ts > 0 else { continue }
            let date = Date(timeIntervalSince1970: ts)
            let costUSD = (rec.quota?.value ?? 0) / quotaPerUnit
            let reqs = max(0, rec.count?.value ?? 0)
            let tokens = max(0, rec.tokenUsed?.value ?? 0)
            let cache = max(0, (rec.cacheReadTokens?.value ?? 0) + (rec.cacheCreationTokens?.value ?? 0))

            let normalizedDate: Date
            let bucketKey: String
            if range.isSingleDay {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
                normalizedDate = cal.date(from: comps) ?? date
                bucketKey = DateFormatters.apiHour.string(from: normalizedDate)
            } else {
                normalizedDate = cal.startOfDay(for: date)
                bucketKey = DateFormatters.apiDay.string(from: normalizedDate)
            }

            if let existing = bucketMap[bucketKey] {
                let sumUSD = existing.costUSD + costUSD
                bucketMap[bucketKey] = UsageBucketPoint(
                    bucketKey: bucketKey,
                    date: existing.date,
                    requests: existing.requests + reqs,
                    inputTokens: existing.inputTokens,
                    outputTokens: existing.outputTokens,
                    cacheTokens: existing.cacheTokens + cache,
                    totalTokens: existing.totalTokens + tokens,
                    costUSD: sumUSD,
                    convertedCost: station.convertToDisplayCurrency(sumUSD)
                )
            } else {
                bucketMap[bucketKey] = UsageBucketPoint(
                    bucketKey: bucketKey,
                    date: normalizedDate,
                    requests: reqs,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: cache,
                    totalTokens: tokens,
                    costUSD: costUSD,
                    convertedCost: station.convertToDisplayCurrency(costUSD)
                )
            }

            let modelName = nonEmpty(rec.modelName) ?? "unknown"
            if let existingModel = modelMap[modelName] {
                let sumUSD = existingModel.costUSD + costUSD
                modelMap[modelName] = ModelUsageStat(
                    modelName: modelName,
                    requests: existingModel.requests + reqs,
                    inputTokens: existingModel.inputTokens,
                    outputTokens: existingModel.outputTokens,
                    cacheTokens: existingModel.cacheTokens + cache,
                    totalTokens: existingModel.totalTokens + tokens,
                    costUSD: sumUSD,
                    convertedCost: station.convertToDisplayCurrency(sumUSD)
                )
            } else {
                modelMap[modelName] = ModelUsageStat(
                    modelName: modelName,
                    requests: reqs,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: cache,
                    totalTokens: tokens,
                    costUSD: costUSD,
                    convertedCost: station.convertToDisplayCurrency(costUSD)
                )
            }
        }

        let filledPoints = RelayAPIService.fillMissingBuckets(
            points: Array(bucketMap.values),
            range: range,
            exchangeRate: station.exchangeRate
        )
        let sortedModels = modelMap.values.sorted { $0.convertedCost > $1.convertedCost }

        let totalCostUSD = filledPoints.reduce(0) { $0 + $1.costUSD }
        let totalRequests = filledPoints.reduce(Int64(0)) { $0 + $1.requests }
        let totalTokens = filledPoints.reduce(Int64(0)) { $0 + $1.totalTokens }
        let totalCache = filledPoints.reduce(Int64(0)) { $0 + $1.cacheTokens }

        let balanceUSD = user.quota.map { $0.value / quotaPerUnit }
        let usedUSD = user.usedQuota.map { $0.value / quotaPerUnit }
        let label = nonEmpty(user.displayName) ?? nonEmpty(user.username) ?? station.accountIdentifier

        return StationUsageSnapshot(
            stationID: station.id,
            accountLabel: label.isEmpty ? station.name : label,
            balanceUSD: balanceUSD,
            lifetimeUsedUSD: usedUSD,
            periodCostUSD: totalCostUSD,
            periodConvertedCost: station.convertToDisplayCurrency(totalCostUSD),
            periodRequests: totalRequests,
            periodTokens: totalTokens,
            periodInputTokens: 0,
            periodOutputTokens: 0,
            periodCacheTokens: totalCache,
            dailyPoints: filledPoints,
            modelStats: sortedModels,
            updatedAt: Date(),
            errorMessage: nil
        )
    }

    // MARK: - Internal HTTP Calls

    private static func fetchQuotaPerUnit(baseURL: String, session: URLSession) async throws -> Double {
        guard let url = URL(string: "\(baseURL)/api/status") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, _) = try await execute(req, session: session)
        let envelope = try JSONDecoder().decode(NewAPIEnvelope<NewAPIStatusDTO>.self, from: data)
        if let qpu = envelope.data?.quotaPerUnit?.value, qpu > 0 {
            return qpu
        }
        return 500_000
    }

    private static func performPasswordLogin(
        baseURL: String,
        username: String,
        password: String,
        session: URLSession
    ) async throws -> (NewAPIUserDTO, String) {
        guard let url = URL(string: "\(baseURL)/api/user/login") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password
        ])

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(NewAPIEnvelope<NewAPIUserDTO>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess, let user = envelope.data else {
            let msg = nonEmpty(envelope.message) ?? "用户名或密码错误（若站点开启 Turnstile/2FA，请使用系统访问令牌登录）"
            throw httpResp.statusCode == 401 ? RelayAPIError.unauthorized(msg) : RelayAPIError.serverError(msg)
        }

        let cookieHeader = extractCookieHeader(from: httpResp, url: url)
        return (user, cookieHeader)
    }

    private static func fetchSelfUser(
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String,
        session: URLSession
    ) async throws -> NewAPIUserDTO {
        guard let url = URL(string: "\(baseURL)/api/user/self") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, cookie: cookie, token: token, userID: userID)

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(NewAPIEnvelope<NewAPIUserDTO>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess, let user = envelope.data else {
            let msg = nonEmpty(envelope.message) ?? "获取 NewAPI 用户信息失败"
            if httpResp.statusCode == 401 || msg.contains("无权") || msg.lowercased().contains("unauth") || msg.contains("New-Api-User") {
                throw RelayAPIError.unauthorized(msg)
            }
            throw RelayAPIError.serverError(msg)
        }
        return user
    }

    private static func fetchQuotaDataChunked(
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> [NewAPIQuotaDataDTO] {
        let interval = range.resolvedInterval
        let startSec = Int64(interval.start.timeIntervalSince1970)
        let endSec = Int64(interval.end.timeIntervalSince1970)
        let maxChunkSeconds: Int64 = 28 * 24 * 3600

        if endSec - startSec <= maxChunkSeconds {
            return try await fetchQuotaDataSingle(
                baseURL: baseURL,
                cookie: cookie,
                token: token,
                userID: userID,
                startTimestamp: startSec,
                endTimestamp: endSec,
                session: session
            )
        }

        var combined: [NewAPIQuotaDataDTO] = []
        var cursor = startSec
        while cursor <= endSec {
            let chunkEnd = min(endSec, cursor + maxChunkSeconds - 1)
            let chunk = try await fetchQuotaDataSingle(
                baseURL: baseURL,
                cookie: cookie,
                token: token,
                userID: userID,
                startTimestamp: cursor,
                endTimestamp: chunkEnd,
                session: session
            )
            combined.append(contentsOf: chunk)
            cursor = chunkEnd + 1
        }
        return combined
    }

    private static func fetchQuotaDataSingle(
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String,
        startTimestamp: Int64,
        endTimestamp: Int64,
        session: URLSession
    ) async throws -> [NewAPIQuotaDataDTO] {
        var comps = URLComponents(string: "\(baseURL)/api/data/self")
        comps?.queryItems = [
            URLQueryItem(name: "start_timestamp", value: String(startTimestamp)),
            URLQueryItem(name: "end_timestamp", value: String(endTimestamp))
        ]
        guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, cookie: cookie, token: token, userID: userID)

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(NewAPIEnvelope<[NewAPIQuotaDataDTO]>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess else {
            throw RelayAPIError.serverError(envelope.message ?? "获取用量数据失败")
        }
        return envelope.data ?? []
    }

    private static func fetchLogsFallback(
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> [NewAPIQuotaDataDTO] {
        let interval = range.resolvedInterval
        var comps = URLComponents(string: "\(baseURL)/api/log/self")
        comps?.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "start_timestamp", value: String(Int64(interval.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_timestamp", value: String(Int64(interval.end.timeIntervalSince1970)))
        ]
        guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, cookie: cookie, token: token, userID: userID)

        let (data, httpResp) = try await execute(request, session: session)
        let items: [NewAPILogItemDTO]
        if let paged = try? decodeEnvelope(NewAPIEnvelope<NewAPILogPageDTO>.self, from: data, statusCode: httpResp.statusCode),
           let pageItems = paged.data?.items {
            items = pageItems
        } else if let direct = try? decodeEnvelope(NewAPIEnvelope<[NewAPILogItemDTO]>.self, from: data, statusCode: httpResp.statusCode),
                  let directItems = direct.data {
            items = directItems
        } else {
            return []
        }

        return items.map { item in
            let tokens = (item.promptTokens?.value ?? 0) + (item.completionTokens?.value ?? 0)
            return NewAPIQuotaDataDTO(
                id: item.id,
                modelName: item.modelName,
                createdAt: item.createdAt,
                tokenUsed: FlexibleInt64(tokens),
                count: FlexibleInt64(1),
                quota: item.quota,
                cacheReadTokens: nil,
                cacheCreationTokens: nil
            )
        }
    }

    private static func fetchTokenUsageFallback(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async throws -> NewAPITokenUsageData {
        guard let url = URL(string: "\(baseURL)/api/usage/token") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResp) = try await execute(request, session: session)
        if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
            throw RelayAPIError.unauthorized("API Key 无效")
        }
        if let decoded = try? JSONDecoder().decode(NewAPITokenUsageDTO.self, from: data),
           let inner = decoded.data {
            return inner
        }
        throw RelayAPIError.decodingError("无法解析 /api/usage/token 响应")
    }

    private static func buildTokenUsageFallbackSnapshot(
        station: RelayStation,
        apiKey: String,
        quotaPerUnit: Double,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> StationUsageSnapshot {
        let usage = try await fetchTokenUsageFallback(baseURL: station.normalizedBaseURL, apiKey: apiKey, session: session)
        let usedUSD = (usage.totalUsed?.value ?? 0) / quotaPerUnit
        let availUSD = usage.totalAvailable.map { $0.value / quotaPerUnit }
        let filled = RelayAPIService.fillMissingBuckets(points: [], range: range, exchangeRate: station.exchangeRate)
        return StationUsageSnapshot(
            stationID: station.id,
            accountLabel: nonEmpty(usage.name) ?? "API Key 模式",
            balanceUSD: availUSD,
            lifetimeUsedUSD: usedUSD,
            periodCostUSD: usedUSD,
            periodConvertedCost: station.convertToDisplayCurrency(usedUSD),
            periodRequests: 0,
            periodTokens: 0,
            periodInputTokens: 0,
            periodOutputTokens: 0,
            periodCacheTokens: 0,
            dailyPoints: filled,
            modelStats: [],
            updatedAt: Date(),
            errorMessage: nil
        )
    }

    // MARK: - Auth & HTTP Helpers

    private static func applyAuthHeaders(
        to request: inout URLRequest,
        cookie: String?,
        token: String?,
        userID: String
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let cleanedUID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedUID.isEmpty {
            request.setValue(cleanedUID, forHTTPHeaderField: "New-Api-User")
            request.setValue(cleanedUID, forHTTPHeaderField: "Rix-Api-User")
            request.setValue(cleanedUID, forHTTPHeaderField: "Veloera-User")
        }
    }

    private static func extractCookieHeader(from response: HTTPURLResponse, url: URL) -> String {
        let allHeaders = response.allHeaderFields
        var stringHeaders: [String: String] = [:]
        for (key, value) in allHeaders {
            if let k = key as? String, let v = value as? String {
                stringHeaders[k] = v
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: url)
        if !cookies.isEmpty {
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        if let raw = stringHeaders["Set-Cookie"] ?? stringHeaders["set-cookie"] {
            return raw.components(separatedBy: ";").first ?? raw
        }
        return ""
    }

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
        _ type: NewAPIEnvelope<T>.Type,
        from data: Data,
        statusCode: Int
    ) throws -> NewAPIEnvelope<T> {
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
        throw RelayAPIError.decodingError("返回内容不是有效的 NewAPI JSON")
    }

    private static func nonEmpty(_ str: String?) -> String? {
        guard let trimmed = str?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
