import Foundation

enum RemailAPIClient {
    private static let maxPages = 25
    private static let pageLimit = 100

    // MARK: - Verify API Key & Wallet

    static func testAndLogin(
        station: RelayStation,
        credentials: StationSecretCredentials
    ) async throws -> StationConnectionResult {
        let session = RelayAPIService.makeEphemeralSession()
        let baseURL = station.normalizedBaseURL
        var creds = credentials

        let rawToken = (creds.accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = stripBearerPrefix(rawToken)
        guard !token.isEmpty else {
            throw RelayAPIError.missingCredentials("请输入 ReMail API Key（以 rk- 开头，可在官网个人中心创建）")
        }
        creds.accessToken = token

        async let profileTask = fetchAPIKeyProfile(baseURL: baseURL, apiKey: token, session: session)
        async let walletTask = fetchWallet(baseURL: baseURL, apiKey: token, session: session)

        let profile = try await profileTask
        let wallet = try? await walletTask

        let labelParts = [nonEmpty(profile.name), nonEmpty(profile.keyPrefix)].compactMap { $0 }
        let label = labelParts.isEmpty ? "ReMail Key" : labelParts.joined(separator: " · ")

        let balancePts = wallet?.consumerBalance?.value ?? profile.balance?.value
        let historicalPts = wallet?.historicalSpend?.value ?? profile.quotaUsed?.value
        let uidStr = wallet?.userId.map { String($0.value) }

        return StationConnectionResult(
            accountLabel: label,
            detectedUserID: uidStr,
            balanceUSD: balancePts,
            lifetimeUsedUSD: historicalPts,
            detectedQuotaPerUnit: nil,
            updatedCredentials: creds
        )
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

        let rawToken = (creds.accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = stripBearerPrefix(rawToken)
        guard !token.isEmpty else {
            throw RelayAPIError.missingCredentials("缺少 ReMail API Key（rk-...）")
        }
        creds.accessToken = token

        async let profileTask = fetchAPIKeyProfile(baseURL: baseURL, apiKey: token, session: session)
        async let walletTask = fetchWallet(baseURL: baseURL, apiKey: token, session: session)

        let profile = try await profileTask
        let wallet = try? await walletTask

        let interval = range.resolvedInterval

        // Fetch cursor-paginated orders within [interval.start, interval.end]
        var orders: [RemailOrderDTO] = []
        var usedTransactionsFallback = false
        do {
            orders = try await fetchOrdersInRange(
                baseURL: baseURL,
                apiKey: token,
                startDate: interval.start,
                endDate: interval.end,
                session: session
            )
        } catch {
            usedTransactionsFallback = true
        }

        let snapshot: StationUsageSnapshot
        if !usedTransactionsFallback {
            snapshot = aggregateOrders(
                orders: orders,
                profile: profile,
                wallet: wallet,
                station: station,
                range: range
            )
        } else {
            let txs = (try? await fetchTransactionsInRange(
                baseURL: baseURL,
                apiKey: token,
                startDate: interval.start,
                endDate: interval.end,
                session: session
            )) ?? []
            snapshot = aggregateTransactions(
                transactions: txs,
                profile: profile,
                wallet: wallet,
                station: station,
                range: range
            )
        }

        return (snapshot, creds, wallet?.userId.map { String($0.value) }, nil)
    }

    // MARK: - Aggregation

    private static func aggregateOrders(
        orders: [RemailOrderDTO],
        profile: RemailAPIKeyProfileDTO,
        wallet: RemailWalletDTO?,
        station: RelayStation,
        range: DateRangeSelection
    ) -> StationUsageSnapshot {
        let cal = Calendar.current
        var bucketMap: [String: UsageBucketPoint] = [:]
        var projectMap: [String: ModelUsageStat] = [:]

        for order in orders {
            guard let createdAt = parseISO8601(order.createdAt) else { continue }
            let pay = max(0, order.payAmount?.value ?? 0)
            let refund = max(0, order.refundAmount?.value ?? 0)
            let netSpend = max(0, pay - refund)

            let normalizedDate: Date
            let bucketKey: String
            if range.isSingleDay {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: createdAt)
                normalizedDate = cal.date(from: comps) ?? createdAt
                bucketKey = DateFormatters.apiHour.string(from: normalizedDate)
            } else {
                normalizedDate = cal.startOfDay(for: createdAt)
                bucketKey = DateFormatters.apiDay.string(from: normalizedDate)
            }

            if let existing = bucketMap[bucketKey] {
                let sumRaw = existing.costUSD + netSpend
                bucketMap[bucketKey] = UsageBucketPoint(
                    bucketKey: bucketKey,
                    date: existing.date,
                    requests: existing.requests + 1,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: sumRaw,
                    convertedCost: station.convertToDisplayCurrency(sumRaw)
                )
            } else {
                bucketMap[bucketKey] = UsageBucketPoint(
                    bucketKey: bucketKey,
                    date: normalizedDate,
                    requests: 1,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: netSpend,
                    convertedCost: station.convertToDisplayCurrency(netSpend)
                )
            }

            let projectLabel = buildProjectLabel(order)
            if let existingProj = projectMap[projectLabel] {
                let sumRaw = existingProj.costUSD + netSpend
                projectMap[projectLabel] = ModelUsageStat(
                    modelName: projectLabel,
                    requests: existingProj.requests + 1,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: sumRaw,
                    convertedCost: station.convertToDisplayCurrency(sumRaw)
                )
            } else {
                projectMap[projectLabel] = ModelUsageStat(
                    modelName: projectLabel,
                    requests: 1,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: netSpend,
                    convertedCost: station.convertToDisplayCurrency(netSpend)
                )
            }
        }

        let filledPoints = RelayAPIService.fillMissingBuckets(
            points: Array(bucketMap.values),
            range: range,
            exchangeRate: station.exchangeRate
        )
        let sortedProjects = projectMap.values.sorted { $0.convertedCost > $1.convertedCost }

        let totalRaw = filledPoints.reduce(0) { $0 + $1.costUSD }
        let totalOrders = filledPoints.reduce(Int64(0)) { $0 + $1.requests }

        let label = nonEmpty(profile.name) ?? nonEmpty(profile.keyPrefix) ?? station.name
        let balanceRaw = wallet?.consumerBalance?.value ?? profile.balance?.value
        let lifetimeRaw = wallet?.historicalSpend?.value ?? profile.quotaUsed?.value

        return StationUsageSnapshot(
            stationID: station.id,
            accountLabel: label,
            balanceUSD: balanceRaw,
            lifetimeUsedUSD: lifetimeRaw,
            periodCostUSD: totalRaw,
            periodConvertedCost: station.convertToDisplayCurrency(totalRaw),
            periodRequests: totalOrders,
            periodTokens: 0,
            periodInputTokens: 0,
            periodOutputTokens: 0,
            periodCacheTokens: 0,
            dailyPoints: filledPoints,
            modelStats: sortedProjects,
            updatedAt: Date(),
            errorMessage: nil
        )
    }

    private static func aggregateTransactions(
        transactions: [RemailTransactionDTO],
        profile: RemailAPIKeyProfileDTO,
        wallet: RemailWalletDTO?,
        station: RelayStation,
        range: DateRangeSelection
    ) -> StationUsageSnapshot {
        let cal = Calendar.current
        var bucketMap: [String: UsageBucketPoint] = [:]
        var categoryMap: [String: ModelUsageStat] = [:]

        for tx in transactions {
            guard (tx.balanceBucket ?? "consumer") == "consumer" else { continue }
            guard let createdAt = parseISO8601(tx.createdAt) else { continue }

            let txType = (tx.transactionType ?? "").lowercased()
            let amount = max(0, tx.amount?.value ?? 0)
            let delta: Double
            let reqIncrement: Int64

            if txType == "debit" {
                delta = amount
                reqIncrement = 1
            } else if txType == "refund" {
                delta = -amount
                reqIncrement = 0
            } else {
                continue
            }

            let normalizedDate: Date
            let bucketKey: String
            if range.isSingleDay {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: createdAt)
                normalizedDate = cal.date(from: comps) ?? createdAt
                bucketKey = DateFormatters.apiHour.string(from: normalizedDate)
            } else {
                normalizedDate = cal.startOfDay(for: createdAt)
                bucketKey = DateFormatters.apiDay.string(from: normalizedDate)
            }

            if let existing = bucketMap[bucketKey] {
                let sumRaw = max(0, existing.costUSD + delta)
                bucketMap[bucketKey] = UsageBucketPoint(
                    bucketKey: bucketKey,
                    date: existing.date,
                    requests: existing.requests + reqIncrement,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: sumRaw,
                    convertedCost: station.convertToDisplayCurrency(sumRaw)
                )
            } else {
                let safeRaw = max(0, delta)
                bucketMap[bucketKey] = UsageBucketPoint(
                    bucketKey: bucketKey,
                    date: normalizedDate,
                    requests: reqIncrement,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: safeRaw,
                    convertedCost: station.convertToDisplayCurrency(safeRaw)
                )
            }

            let catName = nonEmpty(tx.bizType) ?? "钱包消费"
            if let existingCat = categoryMap[catName] {
                let sumRaw = max(0, existingCat.costUSD + delta)
                categoryMap[catName] = ModelUsageStat(
                    modelName: catName,
                    requests: existingCat.requests + reqIncrement,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: sumRaw,
                    convertedCost: station.convertToDisplayCurrency(sumRaw)
                )
            } else {
                let safeRaw = max(0, delta)
                categoryMap[catName] = ModelUsageStat(
                    modelName: catName,
                    requests: reqIncrement,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheTokens: 0,
                    totalTokens: 0,
                    costUSD: safeRaw,
                    convertedCost: station.convertToDisplayCurrency(safeRaw)
                )
            }
        }

        let filledPoints = RelayAPIService.fillMissingBuckets(
            points: Array(bucketMap.values),
            range: range,
            exchangeRate: station.exchangeRate
        )
        let sortedCats = categoryMap.values.sorted { $0.convertedCost > $1.convertedCost }
        let totalRaw = filledPoints.reduce(0) { $0 + $1.costUSD }
        let totalReqs = filledPoints.reduce(Int64(0)) { $0 + $1.requests }

        let label = nonEmpty(profile.name) ?? nonEmpty(profile.keyPrefix) ?? station.name
        let balanceRaw = wallet?.consumerBalance?.value ?? profile.balance?.value
        let lifetimeRaw = wallet?.historicalSpend?.value ?? profile.quotaUsed?.value

        return StationUsageSnapshot(
            stationID: station.id,
            accountLabel: label,
            balanceUSD: balanceRaw,
            lifetimeUsedUSD: lifetimeRaw,
            periodCostUSD: totalRaw,
            periodConvertedCost: station.convertToDisplayCurrency(totalRaw),
            periodRequests: totalReqs,
            periodTokens: 0,
            periodInputTokens: 0,
            periodOutputTokens: 0,
            periodCacheTokens: 0,
            dailyPoints: filledPoints,
            modelStats: sortedCats,
            updatedAt: Date(),
            errorMessage: nil
        )
    }

    // MARK: - HTTP Requests

    private static func fetchAPIKeyProfile(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async throws -> RemailAPIKeyProfileDTO {
        guard let url = URL(string: "\(baseURL)/v1/open/apikey/profile") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, httpResp) = try await execute(req, session: session)
        try validateHTTP(data: data, statusCode: httpResp.statusCode)

        if let wrapped = try? JSONDecoder().decode(RemailAPIKeyProfileResponse.self, from: data),
           let profile = wrapped.apiKey {
            return profile
        }
        if let direct = try? JSONDecoder().decode(RemailAPIKeyProfileDTO.self, from: data) {
            return direct
        }
        throw RelayAPIError.decodingError("无法解析 ReMail /v1/open/apikey/profile 响应")
    }

    private static func fetchWallet(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async throws -> RemailWalletDTO {
        guard let url = URL(string: "\(baseURL)/v1/open/wallet") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, httpResp) = try await execute(req, session: session)
        try validateHTTP(data: data, statusCode: httpResp.statusCode)

        do {
            return try JSONDecoder().decode(RemailWalletDTO.self, from: data)
        } catch {
            throw RelayAPIError.decodingError("无法解析 ReMail /v1/open/wallet 响应")
        }
    }

    private static func fetchOrdersInRange(
        baseURL: String,
        apiKey: String,
        startDate: Date,
        endDate: Date,
        session: URLSession
    ) async throws -> [RemailOrderDTO] {
        var collected: [RemailOrderDTO] = []
        var afterId: Int64? = nil

        for _ in 0..<maxPages {
            var comps = URLComponents(string: "\(baseURL)/v1/open/orders")
            var items = [URLQueryItem(name: "limit", value: String(pageLimit))]
            if let afterId {
                items.append(URLQueryItem(name: "afterId", value: String(afterId)))
            }
            comps?.queryItems = items
            guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, httpResp) = try await execute(req, session: session)
            try validateHTTP(data: data, statusCode: httpResp.statusCode)

            let page = try JSONDecoder().decode(RemailOrderListResponse.self, from: data)
            let pageItems = page.items ?? []
            if pageItems.isEmpty { break }

            var reachedBeforeStart = false
            for order in pageItems {
                guard let created = parseISO8601(order.createdAt) else { continue }
                if created > endDate {
                    continue
                }
                if created < startDate {
                    reachedBeforeStart = true
                    break
                }
                collected.append(order)
            }

            if reachedBeforeStart || page.hasNext != true {
                break
            }
            if let next = page.nextAfterId?.value {
                afterId = next
            } else if let lastID = pageItems.last?.id?.value {
                afterId = lastID
            } else {
                break
            }
        }

        return collected
    }

    private static func fetchTransactionsInRange(
        baseURL: String,
        apiKey: String,
        startDate: Date,
        endDate: Date,
        session: URLSession
    ) async throws -> [RemailTransactionDTO] {
        var collected: [RemailTransactionDTO] = []
        var afterId: Int64? = nil

        for _ in 0..<maxPages {
            var comps = URLComponents(string: "\(baseURL)/v1/open/wallet/transactions")
            var items = [URLQueryItem(name: "limit", value: String(pageLimit))]
            if let afterId {
                items.append(URLQueryItem(name: "afterId", value: String(afterId)))
            }
            comps?.queryItems = items
            guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, httpResp) = try await execute(req, session: session)
            try validateHTTP(data: data, statusCode: httpResp.statusCode)

            let page = try JSONDecoder().decode(RemailTransactionListResponse.self, from: data)
            let pageItems = page.items ?? []
            if pageItems.isEmpty { break }

            var reachedBeforeStart = false
            for tx in pageItems {
                guard let created = parseISO8601(tx.createdAt) else { continue }
                if created > endDate {
                    continue
                }
                if created < startDate {
                    reachedBeforeStart = true
                    break
                }
                collected.append(tx)
            }

            if reachedBeforeStart || page.hasNext != true {
                break
            }
            if let next = page.nextAfterId?.value {
                afterId = next
            } else if let lastID = pageItems.last?.id?.value {
                afterId = lastID
            } else {
                break
            }
        }

        return collected
    }

    // MARK: - Helpers

    private static func buildProjectLabel(_ order: RemailOrderDTO) -> String {
        let project = nonEmpty(order.projectName)
        let product = localizedProductType(order.productType)
        let mode = order.serviceMode == "purchase" ? "购买" : "接码"
        if let project {
            return "\(project) · \(product)"
        }
        return "\(product) (\(mode))"
    }

    private static func localizedProductType(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "microsoft": return "Microsoft"
        case "gmail": return "Gmail"
        case "gmail_variant": return "Gmail 变体"
        case "icloud": return "iCloud"
        case "domain": return "域名邮箱"
        case "proto": return "Proto"
        case "daum": return "Daum"
        case "random": return "随机邮箱"
        default: return raw?.isEmpty == false ? raw! : "其他邮箱"
        }
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let str = nonEmpty(raw) else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: str) { return d }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let d = standard.date(from: str) { return d }
        return DateFormatters.parseTrendDate(str)
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

    private static func validateHTTP(data: Data, statusCode: Int) throws {
        guard statusCode >= 400 else { return }
        let errObj = try? JSONDecoder().decode(RemailErrorResponse.self, from: data)
        let msg = nonEmpty(errObj?.message) ?? "请求失败 (HTTP \(statusCode))"
        if statusCode == 401 || statusCode == 403 {
            throw RelayAPIError.unauthorized(msg)
        }
        throw RelayAPIError.httpError(statusCode, msg)
    }

    private static func nonEmpty(_ str: String?) -> String? {
        guard let trimmed = str?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
