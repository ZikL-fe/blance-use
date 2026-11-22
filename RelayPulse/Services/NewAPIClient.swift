import Foundation
import Security

enum NewAPIClient {
    private static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1"

    private struct SiteStatusInfo {
        var quotaPerUnit: Double
        var maxRangeDays: Int
        var passwordEncryptionEnabled: Bool
    }

    private struct LoginOutcome {
        var user: NewAPIUserDTO
        var accessToken: String?
        var sessionCookie: String?
        var sessionID: String?
    }

    // MARK: - Login & Verification

    static func testAndLogin(
        station: RelayStation,
        credentials: StationSecretCredentials
    ) async throws -> StationConnectionResult {
        let session = RelayAPIService.makeEphemeralSession()
        let baseURL = station.normalizedBaseURL
        var creds = credentials

        let statusInfo = await fetchSiteStatus(baseURL: baseURL, fallbackQuotaPerUnit: station.quotaPerUnit, session: session)
        let quotaPerUnit = statusInfo.quotaPerUnit

        switch station.authMethod {
        case .password:
            let username = station.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty, let password = creds.password, !password.isEmpty else {
                throw RelayAPIError.missingCredentials("请输入用户名和密码")
            }
            let outcome = try await performPasswordLogin(
                baseURL: baseURL,
                username: username,
                password: password,
                statusInfo: statusInfo,
                session: session
            )
            if let token = outcome.accessToken, !token.isEmpty {
                creds.accessToken = token
            }
            if let cookie = outcome.sessionCookie, !cookie.isEmpty {
                creds.sessionCookie = cookie
            }
            if let sid = outcome.sessionID, !sid.isEmpty {
                creds.sessionID = sid
            }

            let userIDStr = outcome.user.id.map { String($0.value) } ?? nonEmpty(station.userID) ?? ""
            // On NewAPI v1.0, login response's embedded user object may omit quota; fetch /api/user/self to get full balance!
            let fullUser: NewAPIUserDTO
            if outcome.user.quota == nil {
                fullUser = (try? await fetchSelfUser(
                    baseURL: baseURL,
                    cookie: creds.sessionCookie,
                    token: creds.accessToken,
                    userID: userIDStr,
                    session: session
                )) ?? outcome.user
            } else {
                fullUser = outcome.user
            }

            let resolvedUID = fullUser.id.map { String($0.value) } ?? nonEmpty(userIDStr)
            let balanceUSD = fullUser.quota.map { $0.value / quotaPerUnit }
            let usedUSD = fullUser.usedQuota.map { $0.value / quotaPerUnit }
            let label = nonEmpty(fullUser.displayName) ?? nonEmpty(fullUser.username) ?? username
            return StationConnectionResult(
                accountLabel: label,
                detectedUserID: resolvedUID,
                balanceUSD: balanceUSD,
                lifetimeUsedUSD: usedUSD,
                detectedQuotaPerUnit: quotaPerUnit,
                updatedCredentials: creds
            )

        case .accessToken:
            guard let rawToken = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !rawToken.isEmpty else {
                throw RelayAPIError.missingCredentials("请输入 NewAPI 系统访问令牌或登录 Cookie")
            }
            let cleaned = stripBearerPrefix(rawToken)
            creds.accessToken = cleaned

            // Support pasting raw Cookie string (`session=...` or `...=...; ...`) in addition to Bearer token
            let looksLikeCookie = cleaned.contains("=") && !cleaned.lowercased().hasPrefix("sk-") && !cleaned.hasPrefix("eyJ")
            let tokenHeader: String? = looksLikeCookie ? nil : cleaned
            let cookieHeader: String? = looksLikeCookie ? cleaned : nil
            let effectiveUID = nonEmpty(station.userID) ?? extractJWTSubject(cleaned) ?? ""

            do {
                let user = try await fetchSelfUser(
                    baseURL: baseURL,
                    cookie: cookieHeader,
                    token: tokenHeader,
                    userID: effectiveUID,
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
                if cleaned.lowercased().hasPrefix("sk-") {
                    let tokenUsage = try await fetchTokenUsageFallback(
                        baseURL: baseURL,
                        apiKey: cleaned,
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

        let statusInfo = await fetchSiteStatus(baseURL: baseURL, fallbackQuotaPerUnit: station.quotaPerUnit, session: session)
        let quotaPerUnit = statusInfo.quotaPerUnit

        // Ensure password-mode auth credentials exist (either accessToken for v1.0 or sessionCookie for v0.x)
        if station.authMethod == .password && nonEmpty(creds.accessToken) == nil && nonEmpty(creds.sessionCookie) == nil {
            if let password = creds.password, !password.isEmpty, !station.accountIdentifier.isEmpty {
                let outcome = try await performPasswordLogin(
                    baseURL: baseURL,
                    username: station.accountIdentifier,
                    password: password,
                    statusInfo: statusInfo,
                    session: session
                )
                creds.accessToken = outcome.accessToken ?? creds.accessToken
                creds.sessionCookie = outcome.sessionCookie ?? creds.sessionCookie
                creds.sessionID = outcome.sessionID ?? creds.sessionID
                if let idVal = outcome.user.id?.value {
                    activeUserID = String(idVal)
                }
            } else {
                throw RelayAPIError.missingCredentials("缺少账号密码凭据")
            }
        }

        let resolvedAuth = resolveAuthPair(method: station.authMethod, creds: creds)
        if activeUserID.isEmpty, let tok = resolvedAuth.token, let sub = extractJWTSubject(tok) {
            activeUserID = sub
        }

        // Fetch profile (supports NewAPI v1.0 `/api/user/auth/refresh` + password auto re-login on 401)
        let user: NewAPIUserDTO
        do {
            user = try await fetchSelfUser(
                baseURL: baseURL,
                cookie: resolvedAuth.cookie,
                token: resolvedAuth.token,
                userID: activeUserID,
                session: session
            )
        } catch RelayAPIError.unauthorized {
            if station.authMethod == .password {
                // 1) Try NewAPI v1.0 refresh endpoint first using saved refresh cookie + X-Auth-Session
                if let cookie = nonEmpty(creds.sessionCookie),
                   let refreshed = try? await performAuthRefresh(baseURL: baseURL, cookie: cookie, sessionID: creds.sessionID, session: session) {
                    creds.accessToken = refreshed.accessToken ?? creds.accessToken
                    creds.sessionCookie = refreshed.sessionCookie ?? creds.sessionCookie
                    creds.sessionID = refreshed.sessionID ?? creds.sessionID
                    if let idVal = refreshed.user.id?.value {
                        activeUserID = String(idVal)
                    }
                    user = (try? await fetchSelfUser(
                        baseURL: baseURL,
                        cookie: creds.sessionCookie,
                        token: creds.accessToken,
                        userID: activeUserID,
                        session: session
                    )) ?? refreshed.user
                } else if let password = creds.password, !password.isEmpty, !station.accountIdentifier.isEmpty {
                    // 2) Full re-login with saved password
                    let outcome = try await performPasswordLogin(
                        baseURL: baseURL,
                        username: station.accountIdentifier,
                        password: password,
                        statusInfo: statusInfo,
                        session: session
                    )
                    creds.accessToken = outcome.accessToken ?? creds.accessToken
                    creds.sessionCookie = outcome.sessionCookie ?? creds.sessionCookie
                    creds.sessionID = outcome.sessionID ?? creds.sessionID
                    if let idVal = outcome.user.id?.value {
                        activeUserID = String(idVal)
                    }
                    user = (try? await fetchSelfUser(
                        baseURL: baseURL,
                        cookie: creds.sessionCookie,
                        token: creds.accessToken,
                        userID: activeUserID,
                        session: session
                    )) ?? outcome.user
                } else {
                    throw RelayAPIError.unauthorized("登录会话已过期，请在站点编辑页重新登录")
                }
            } else if station.authMethod == .accessToken,
                      let token = creds.accessToken, stripBearerPrefix(token).lowercased().hasPrefix("sk-") {
                let fallback = try await buildTokenUsageFallbackSnapshot(
                    station: station,
                    apiKey: stripBearerPrefix(token),
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

        let finalAuth = resolveAuthPair(method: station.authMethod, creds: creds)

        // Fetch usage data from /api/data/ (site-wide admin) or /api/data/self (personal)
        let isAdminScope = station.usageScope == .siteWideAdmin
        var quotaRecords: [NewAPIQuotaDataDTO] = []
        var dataSelfFailed = false
        do {
            quotaRecords = try await fetchQuotaDataChunked(
                baseURL: baseURL,
                cookie: finalAuth.cookie,
                token: finalAuth.token,
                userID: activeUserID,
                adminScope: isAdminScope,
                maxChunkDays: max(1, min(statusInfo.maxRangeDays, 365)),
                range: range,
                session: session
            )
        } catch {
            if isAdminScope {
                throw error
            }
            dataSelfFailed = true
        }

        // Fallback to full paginated /api/log/self when /api/data/self fails OR returns empty (e.g. DATA_EXPORT_ENABLED=false)
        var exactStatQuotaOverride: Double? = nil
        if !isAdminScope && (dataSelfFailed || quotaRecords.isEmpty) {
            if let logResult = try? await fetchLogsPaginatedFallback(
                baseURL: baseURL,
                cookie: finalAuth.cookie,
                token: finalAuth.token,
                userID: activeUserID,
                range: range,
                session: session
            ), !logResult.records.isEmpty {
                quotaRecords = logResult.records
                if logResult.wasTruncated {
                    exactStatQuotaOverride = try? await fetchLogSelfStatQuota(
                        baseURL: baseURL,
                        cookie: finalAuth.cookie,
                        token: finalAuth.token,
                        userID: activeUserID,
                        range: range,
                        session: session
                    )
                }
            }
        }

        var snapshot = aggregateQuotaRecords(
            records: quotaRecords,
            user: user,
            station: station,
            quotaPerUnit: quotaPerUnit,
            range: range
        )
        if let exactQuota = exactStatQuotaOverride, exactQuota > 0 {
            let exactUSD = exactQuota / quotaPerUnit
            if exactUSD > snapshot.periodCostUSD {
                snapshot.periodCostUSD = exactUSD
                snapshot.periodConvertedCost = station.convertToDisplayCurrency(exactUSD)
            }
        }

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

    private static func fetchSiteStatus(
        baseURL: String,
        fallbackQuotaPerUnit: Double,
        session: URLSession
    ) async -> SiteStatusInfo {
        let fallback = SiteStatusInfo(quotaPerUnit: fallbackQuotaPerUnit, maxRangeDays: 28, passwordEncryptionEnabled: false)
        guard let url = URL(string: "\(baseURL)/api/status") else { return fallback }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBrowserHeaders(to: &req, baseURL: baseURL)

        guard let (data, _) = try? await execute(req, session: session),
              let envelope = try? JSONDecoder().decode(NewAPIEnvelope<NewAPIStatusDTO>.self, from: data),
              let dto = envelope.data else {
            return fallback
        }
        let qpu = (dto.quotaPerUnit?.value ?? 0) > 0 ? (dto.quotaPerUnit?.value ?? fallbackQuotaPerUnit) : fallbackQuotaPerUnit
        let rawMaxDays = Int(dto.logMaxRangeDays?.value ?? 28)
        let safeMaxDays = rawMaxDays > 1 ? min(rawMaxDays - 1, 360) : 28
        return SiteStatusInfo(
            quotaPerUnit: qpu,
            maxRangeDays: safeMaxDays,
            passwordEncryptionEnabled: dto.passwordEncryptionEnabled ?? false
        )
    }

    private static func fetchEncryptionKey(baseURL: String, session: URLSession) async -> NewAPIEncryptionKeyDTO? {
        guard let url = URL(string: "\(baseURL)/api/user/login/encryption-key") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBrowserHeaders(to: &req, baseURL: baseURL)

        guard let (data, httpResp) = try? await execute(req, session: session),
              httpResp.statusCode == 200,
              let envelope = try? JSONDecoder().decode(NewAPIEnvelope<NewAPIEncryptionKeyDTO>.self, from: data),
              envelope.isSuccess else {
            return nil
        }
        return envelope.data
    }

    private static func performPasswordLogin(
        baseURL: String,
        username: String,
        password: String,
        statusInfo: SiteStatusInfo,
        session: URLSession
    ) async throws -> LoginOutcome {
        guard let url = URL(string: "\(baseURL)/api/user/login") else {
            throw RelayAPIError.invalidURL(baseURL)
        }

        var payload: [String: Any] = ["username": username]

        // Support NewAPI v1.0 RSA-OAEP-SHA256 password encryption if enabled on the server
        if statusInfo.passwordEncryptionEnabled,
           let keyDTO = await fetchEncryptionKey(baseURL: baseURL, session: session),
           keyDTO.enabled != false,
           let kid = nonEmpty(keyDTO.kid),
           let pem = nonEmpty(keyDTO.publicKey),
           let encrypted = rsaOAEPEncrypt(plaintext: password, spkiPEM: pem) {
            payload["password_encrypted"] = encrypted
            payload["encryption_key_id"] = kid
        } else {
            payload["password"] = password
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyBrowserHeaders(to: &request, baseURL: baseURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(NewAPIEnvelope<NewAPILoginBundleDTO>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess, let bundle = envelope.data, let user = bundle.resolvedUser else {
            let msg = nonEmpty(envelope.message) ?? "用户名或密码错误（若站点开启 Turnstile/2FA，请使用系统访问令牌登录）"
            throw httpResp.statusCode == 401 ? RelayAPIError.unauthorized(msg) : RelayAPIError.serverError(msg)
        }

        let cookieHeader = extractCookieHeader(from: httpResp, url: url)
        return LoginOutcome(
            user: user,
            accessToken: nonEmpty(bundle.accessToken),
            sessionCookie: nonEmpty(cookieHeader),
            sessionID: nonEmpty(bundle.session?.sid)
        )
    }

    private static func performAuthRefresh(
        baseURL: String,
        cookie: String,
        sessionID: String?,
        session: URLSession
    ) async throws -> LoginOutcome {
        guard let url = URL(string: "\(baseURL)/api/user/auth/refresh") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyBrowserHeaders(to: &request, baseURL: baseURL)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let sid = nonEmpty(sessionID) {
            request.setValue(sid, forHTTPHeaderField: "X-Auth-Session")
        }

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(NewAPIEnvelope<NewAPILoginBundleDTO>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess, let bundle = envelope.data, let user = bundle.resolvedUser else {
            throw RelayAPIError.unauthorized(envelope.message ?? "刷新会话失败")
        }

        let newCookie = nonEmpty(extractCookieHeader(from: httpResp, url: url)) ?? cookie
        return LoginOutcome(
            user: user,
            accessToken: nonEmpty(bundle.accessToken),
            sessionCookie: newCookie,
            sessionID: nonEmpty(bundle.session?.sid) ?? sessionID
        )
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
        applyAuthHeaders(to: &request, baseURL: baseURL, cookie: cookie, token: token, userID: userID)

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
        adminScope: Bool,
        maxChunkDays: Int,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> [NewAPIQuotaDataDTO] {
        let interval = range.resolvedInterval
        let startSec = Int64(interval.start.timeIntervalSince1970)
        let endSec = Int64(interval.end.timeIntervalSince1970)
        let maxChunkSeconds: Int64 = Int64(max(1, maxChunkDays)) * 24 * 3600

        if endSec - startSec <= maxChunkSeconds {
            return try await fetchQuotaDataSingle(
                baseURL: baseURL,
                cookie: cookie,
                token: token,
                userID: userID,
                adminScope: adminScope,
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
                adminScope: adminScope,
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
        adminScope: Bool,
        startTimestamp: Int64,
        endTimestamp: Int64,
        session: URLSession
    ) async throws -> [NewAPIQuotaDataDTO] {
        let path = adminScope ? "/api/data/" : "/api/data/self"
        var comps = URLComponents(string: "\(baseURL)\(path)")
        comps?.queryItems = [
            URLQueryItem(name: "start_timestamp", value: String(startTimestamp)),
            URLQueryItem(name: "end_timestamp", value: String(endTimestamp))
        ]
        guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, baseURL: baseURL, cookie: cookie, token: token, userID: userID)

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(NewAPIEnvelope<[NewAPIQuotaDataDTO]>.self, from: data, statusCode: httpResp.statusCode)
        guard envelope.isSuccess else {
            throw RelayAPIError.serverError(envelope.message ?? (adminScope ? "获取全站数据失败（请确认该账号具备管理员权限）" : "获取用量数据失败"))
        }
        return envelope.data ?? []
    }

    private static func fetchLogsPaginatedFallback(
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> (records: [NewAPIQuotaDataDTO], wasTruncated: Bool) {
        let interval = range.resolvedInterval
        let startSec = Int64(interval.start.timeIntervalSince1970)
        let endSec = Int64(interval.end.timeIntervalSince1970)
        let pageSize = 100
        let maxPages = 50 // up to 5,000 logs (with /api/log/self/stat exact-sum safety net if exceeded)

        let firstPage = try await fetchSingleLogPage(
            baseURL: baseURL,
            cookie: cookie,
            token: token,
            userID: userID,
            page: 1,
            pageSize: pageSize,
            startTimestamp: startSec,
            endTimestamp: endSec,
            session: session
        )

        var allItems = firstPage.items
        let total = firstPage.total
        let totalPages = max(1, Int(ceil(Double(total) / Double(pageSize))))
        let targetPages = min(totalPages, maxPages)
        let wasTruncated = totalPages > maxPages

        if targetPages > 1 {
            // Fetch remaining pages in gentle 2-way paced batches with cancellation support
            var pageCursor = 2
            while pageCursor <= targetPages {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 120_000_000)
                let batchEnd = min(targetPages, pageCursor + 1)
                let pages = Array(pageCursor...batchEnd)
                let batchItems: [[NewAPILogItemDTO]] = await withTaskGroup(of: [NewAPILogItemDTO].self) { group in
                    for p in pages {
                        group.addTask {
                            let res = try? await fetchSingleLogPage(
                                baseURL: baseURL,
                                cookie: cookie,
                                token: token,
                                userID: userID,
                                page: p,
                                pageSize: pageSize,
                                startTimestamp: startSec,
                                endTimestamp: endSec,
                                session: session
                            )
                            return res?.items ?? []
                        }
                    }
                    var collected: [[NewAPILogItemDTO]] = []
                    for await list in group {
                        collected.append(list)
                    }
                    return collected
                }
                for list in batchItems {
                    allItems.append(contentsOf: list)
                }
                pageCursor = batchEnd + 1
            }
        }

        let converted = allItems.compactMap { item -> NewAPIQuotaDataDTO? in
            // Only count consumption logs (type == 2) when type is present
            if let t = item.type?.value, t != 2 { return nil }
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
        return (converted, wasTruncated)
    }

    private static func fetchSingleLogPage(
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String,
        page: Int,
        pageSize: Int,
        startTimestamp: Int64,
        endTimestamp: Int64,
        session: URLSession
    ) async throws -> (items: [NewAPILogItemDTO], total: Int64) {
        var comps = URLComponents(string: "\(baseURL)/api/log/self")
        comps?.queryItems = [
            URLQueryItem(name: "p", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "start_timestamp", value: String(startTimestamp)),
            URLQueryItem(name: "end_timestamp", value: String(endTimestamp))
        ]
        guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, baseURL: baseURL, cookie: cookie, token: token, userID: userID)

        let (data, httpResp) = try await execute(request, session: session)
        if let paged = try? decodeEnvelope(NewAPIEnvelope<NewAPILogPageDTO>.self, from: data, statusCode: httpResp.statusCode),
           let pageData = paged.data {
            let items = pageData.items ?? []
            return (items, pageData.total?.value ?? Int64(items.count))
        }
        if let direct = try? decodeEnvelope(NewAPIEnvelope<[NewAPILogItemDTO]>.self, from: data, statusCode: httpResp.statusCode),
           let directItems = direct.data {
            return (directItems, Int64(directItems.count))
        }
        return ([], 0)
    }

    private static func fetchLogSelfStatQuota(
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> Double? {
        let interval = range.resolvedInterval
        var comps = URLComponents(string: "\(baseURL)/api/log/self/stat")
        comps?.queryItems = [
            URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "start_timestamp", value: String(Int64(interval.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_timestamp", value: String(Int64(interval.end.timeIntervalSince1970)))
        ]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, baseURL: baseURL, cookie: cookie, token: token, userID: userID)

        let (data, httpResp) = try await execute(request, session: session)
        let envelope = try decodeEnvelope(NewAPIEnvelope<NewAPILogStatDTO>.self, from: data, statusCode: httpResp.statusCode)
        return envelope.data?.quota?.value
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
        applyBrowserHeaders(to: &request, baseURL: baseURL)
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

    // MARK: - Auth, Crypto & HTTP Helpers

    private static func resolveAuthPair(method: AuthMethod, creds: StationSecretCredentials) -> (cookie: String?, token: String?) {
        switch method {
        case .password:
            // NewAPI v1.0 uses Bearer access_token + Cookie; v0.x uses Cookie
            return (nonEmpty(creds.sessionCookie), nonEmpty(creds.accessToken))
        case .accessToken:
            guard let raw = nonEmpty(creds.accessToken) else { return (nil, nil) }
            let cleaned = stripBearerPrefix(raw)
            let looksLikeCookie = cleaned.contains("=") && !cleaned.lowercased().hasPrefix("sk-") && !cleaned.hasPrefix("eyJ")
            if looksLikeCookie {
                return (cleaned, nil)
            }
            return (nil, cleaned)
        }
    }

    private static func applyBrowserHeaders(to request: inout URLRequest, baseURL: String) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("\(baseURL)/dashboard/overview", forHTTPHeaderField: "Referer")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
    }

    private static func applyAuthHeaders(
        to request: inout URLRequest,
        baseURL: String,
        cookie: String?,
        token: String?,
        userID: String
    ) {
        applyBrowserHeaders(to: &request, baseURL: baseURL)
        if let cookie = nonEmpty(cookie) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let token = nonEmpty(token) {
            request.setValue("Bearer \(stripBearerPrefix(token))", forHTTPHeaderField: "Authorization")
        }
        let cleanedUID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedUID.isEmpty {
            request.setValue(cleanedUID, forHTTPHeaderField: "New-Api-User")
            request.setValue(cleanedUID, forHTTPHeaderField: "Rix-Api-User")
            request.setValue(cleanedUID, forHTTPHeaderField: "Veloera-User")
        }
    }

    /// Encrypts plaintext using RSA-OAEP-SHA256 matching NewAPI v1.0 `/api/user/login/encryption-key` SPKI PEM format.
    private static func rsaOAEPEncrypt(plaintext: String, spkiPEM: String) -> String? {
        let stripped = spkiPEM
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let derData = Data(base64Encoded: stripped),
              let plainData = plaintext.data(using: .utf8) else {
            return nil
        }

        // Strip standard ASN.1 SubjectPublicKeyInfo (SPKI) RSA header to extract PKCS#1 RSAPublicKey bytes if needed,
        // or let SecKeyCreateWithData parse SPKI directly (supported natively on iOS 10+!).
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, &error) else {
            return nil
        }
        guard SecKeyIsAlgorithmSupported(secKey, .encrypt, .rsaEncryptionOAEPSHA256) else {
            return nil
        }
        guard let cipherData = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionOAEPSHA256,
            plainData as CFData,
            &error
        ) as Data? else {
            return nil
        }
        return cipherData.base64EncodedString()
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

    /// Extracts `sub` (User ID) from a NewAPI v1.0 dashboard JWT if User ID wasn't manually provided.
    private static func extractJWTSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let payloadData = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        if let subStr = json["sub"] as? String, !subStr.isEmpty {
            return subStr
        }
        if let subNum = json["sub"] as? Int {
            return String(subNum)
        }
        return nil
    }

    private static func stripBearerPrefix(_ raw: String) -> String {
        if raw.lowercased().hasPrefix("bearer ") {
            return String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
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
