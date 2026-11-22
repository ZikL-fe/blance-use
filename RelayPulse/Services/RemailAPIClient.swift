import Foundation

// MARK: - Incremental Local Cache for ReMail OpenAPI (Prevents Repeated High-RPM Pagination)

private struct RemailCachedOrder: Codable {
    let id: Int64
    let projectName: String?
    let productType: String?
    let serviceMode: String?
    let status: String?
    let payAmount: Double
    let refundAmount: Double
    let createdAt: Date
}

private struct RemailOrderCacheFile: Codable {
    var ordersByID: [Int64: RemailCachedOrder]
    var oldestFetchedID: Int64?
    var oldestFetchedDate: Date?
    var hasReachedAccountBeginning: Bool
    var lastSyncAt: Date
}

private actor RemailCacheStore {
    static let shared = RemailCacheStore()
    private var memoryCache: [UUID: RemailOrderCacheFile] = [:]

    private func fileURL(for stationID: UUID) -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("RelayPulse/RemailCache", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("\(stationID.uuidString).json")
    }

    func load(for stationID: UUID) -> RemailOrderCacheFile {
        if let mem = memoryCache[stationID] {
            return mem
        }
        let url = fileURL(for: stationID)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(RemailOrderCacheFile.self, from: data) {
            memoryCache[stationID] = decoded
            return decoded
        }
        return RemailOrderCacheFile(
            ordersByID: [:],
            oldestFetchedID: nil,
            oldestFetchedDate: nil,
            hasReachedAccountBeginning: false,
            lastSyncAt: .distantPast
        )
    }

    func save(_ cache: RemailOrderCacheFile, for stationID: UUID) {
        // Prune orders older than 120 days to keep cache compact
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? .distantPast
        var pruned = cache
        if pruned.ordersByID.count > 20_000 {
            pruned.ordersByID = pruned.ordersByID.filter { $0.value.createdAt >= cutoff }
        }
        memoryCache[stationID] = pruned
        if let data = try? JSONEncoder().encode(pruned) {
            try? data.write(to: fileURL(for: stationID), options: [.atomic])
        }
    }
}

// MARK: - ReMail API Client

enum RemailAPIClient {
    /// Strict per-refresh page cap & pacing to keep OpenAPI RPM gentle (< ~4 req/sec, max 20 pages per pass)
    private static let maxNewSyncPages = 15
    private static let maxBackfillPages = 20
    private static let pageLimit = 100
    private static let pageDelayNanoseconds: UInt64 = 260_000_000 // 260ms gentle pacing (~3.8 req/s)

    private static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1"

    private static func normalizeConsoleCookie(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cookie:") {
            s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private static func isConsoleCookie(_ raw: String) -> Bool {
        let trimmed = normalizeConsoleCookie(raw)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("rk-") || lower.hasPrefix("bearer ") {
            return false
        }
        return trimmed.contains("=")
    }

    // MARK: - Verify API Key or Console Cookie

    static func testAndLogin(
        station: RelayStation,
        credentials: StationSecretCredentials
    ) async throws -> StationConnectionResult {
        let session = RelayAPIService.makeEphemeralSession()
        let baseURL = station.normalizedBaseURL
        var creds = credentials

        let rawCredential = (creds.accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCredential.isEmpty else {
            throw RelayAPIError.missingCredentials("请输入 ReMail API Key (rk-...) 或网页控制台 Cookie")
        }

        // Mode 1: Console Session Cookie -> 1 single request for 365-day history via /v1/dashboard!
        if isConsoleCookie(rawCredential) {
            let cleanCookie = normalizeConsoleCookie(rawCredential)
            creds.accessToken = cleanCookie
            let me = try await fetchConsoleMe(baseURL: baseURL, cookie: cleanCookie, session: session)
            let wallet = try? await fetchConsoleWallet(baseURL: baseURL, cookie: cleanCookie, session: session)
            let label = nonEmpty(me.nickname) ?? nonEmpty(me.name) ?? nonEmpty(me.username) ?? nonEmpty(me.email) ?? "ReMail 控制台"
            return StationConnectionResult(
                accountLabel: "\(label) (Cookie 模式)",
                detectedUserID: me.id.map { String($0.value) } ?? wallet?.userId.map { String($0.value) },
                balanceUSD: wallet?.consumerBalance?.value,
                lifetimeUsedUSD: wallet?.historicalSpend?.value,
                detectedQuotaPerUnit: nil,
                updatedCredentials: creds
            )
        }

        // Mode 2: Official OpenAPI Key (`Bearer rk-...`)
        let token = stripBearerPrefix(rawCredential)
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

        let rawCredential = (creds.accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCredential.isEmpty else {
            throw RelayAPIError.missingCredentials("缺少 ReMail API Key 或控制台 Cookie")
        }

        // Mode 1: Console Cookie -> /v1/dashboard?createdFrom=...&createdTo=... (Literally 1 request, RPM = 1!)
        if isConsoleCookie(rawCredential) {
            let cleanCookie = normalizeConsoleCookie(rawCredential)
            creds.accessToken = cleanCookie
            let (snapshot, uid) = try await fetchViaConsoleDashboard(
                station: station,
                cookie: cleanCookie,
                range: range,
                session: session
            )
            return (snapshot, creds, uid, nil)
        }

        // Mode 2: Official OpenAPI Key (`Bearer rk-...`) with Incremental Local Order Cache & Pacing
        let token = stripBearerPrefix(rawCredential)
        creds.accessToken = token

        async let profileTask = fetchAPIKeyProfile(baseURL: baseURL, apiKey: token, session: session)
        async let walletTask = fetchWallet(baseURL: baseURL, apiKey: token, session: session)

        let profile = try await profileTask
        let wallet = try? await walletTask

        try Task.checkCancellation()

        let interval = range.resolvedInterval

        // Incrementally sync orders into local cache (dramatically reduces RPM on repeated switches/refreshes!)
        do {
            let cachedOrders = try await syncOrdersIncrementally(
                stationID: station.id,
                baseURL: baseURL,
                apiKey: token,
                targetStartDate: interval.start,
                session: session
            )

            let filtered = cachedOrders.filter { $0.createdAt >= interval.start && $0.createdAt <= interval.end }
            let snapshot = aggregateCachedOrders(
                orders: filtered,
                profile: profile,
                wallet: wallet,
                station: station,
                range: range
            )
            return (snapshot, creds, wallet?.userId.map { String($0.value) }, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fallback to wallet transactions ONLY if /v1/open/orders itself failed
            let txs = (try? await fetchTransactionsPaced(
                baseURL: baseURL,
                apiKey: token,
                startDate: interval.start,
                endDate: interval.end,
                session: session
            )) ?? []
            let snapshot = aggregateTransactions(
                transactions: txs,
                profile: profile,
                wallet: wallet,
                station: station,
                range: range
            )
            return (snapshot, creds, wallet?.userId.map { String($0.value) }, nil)
        }
    }

    // MARK: - Incremental Order Sync Engine (Low RPM)

    private static func syncOrdersIncrementally(
        stationID: UUID,
        baseURL: String,
        apiKey: String,
        targetStartDate: Date,
        session: URLSession
    ) async throws -> [RemailCachedOrder] {
        var cache = await RemailCacheStore.shared.load(for: stationID)
        let previouslyCachedIDs = Set(cache.ordersByID.keys)
        // Re-check recent 2 hours of orders so pending/refunded status transitions stay accurate
        let recentCutoff = Date().addingTimeInterval(-7200)

        // Phase A: Top incremental sync (newest -> stop as soon as we hit cached orders older than 2 hours)
        var afterId: Int64? = nil
        var reachedBeginning = false

        for pageIndex in 0..<maxNewSyncPages {
            try Task.checkCancellation()
            if pageIndex > 0 {
                try await Task.sleep(nanoseconds: pageDelayNanoseconds)
            }

            let page = try await fetchOrdersPage(baseURL: baseURL, apiKey: apiKey, afterId: afterId, session: session)
            let items = page.items ?? []
            if items.isEmpty {
                reachedBeginning = true
                break
            }

            var allAlreadyCachedAndSettled = !previouslyCachedIDs.isEmpty
            for dto in items {
                guard let id = dto.id?.value, let createdAt = parseISO8601(dto.createdAt) else { continue }
                let cached = RemailCachedOrder(
                    id: id,
                    projectName: dto.projectName,
                    productType: dto.productType,
                    serviceMode: dto.serviceMode,
                    status: dto.status,
                    payAmount: max(0, dto.payAmount?.value ?? 0),
                    refundAmount: max(0, dto.refundAmount?.value ?? 0),
                    createdAt: createdAt
                )
                cache.ordersByID[id] = cached
                if cache.oldestFetchedID == nil || id < (cache.oldestFetchedID ?? Int64.max) {
                    cache.oldestFetchedID = id
                }
                if cache.oldestFetchedDate == nil || createdAt < (cache.oldestFetchedDate ?? .distantFuture) {
                    cache.oldestFetchedDate = createdAt
                }

                if !previouslyCachedIDs.contains(id) || createdAt >= recentCutoff {
                    allAlreadyCachedAndSettled = false
                }
            }

            if page.hasNext != true {
                reachedBeginning = true
                break
            }

            // Early exit: we caught up to our local cache! (Saves 95%+ of API requests!)
            if allAlreadyCachedAndSettled {
                break
            }

            // Also stop top sync if this is a brand-new cache and we already passed targetStartDate
            if previouslyCachedIDs.isEmpty,
               let lastDate = items.last.flatMap({ parseISO8601($0.createdAt) }),
               lastDate < targetStartDate {
                break
            }

            if let next = page.nextAfterId?.value {
                afterId = next
            } else if let lastID = items.last?.id?.value {
                afterId = lastID
            } else {
                break
            }
        }

        if reachedBeginning {
            cache.hasReachedAccountBeginning = true
        }

        // Phase B: Historical backfill (ONLY if local cache doesn't yet reach back to targetStartDate!)
        // Resumes from `oldestFetchedID` so we NEVER re-fetch pages we already have!
        if !cache.hasReachedAccountBeginning,
           let oldestDate = cache.oldestFetchedDate,
           oldestDate > targetStartDate,
           var cursorID = cache.oldestFetchedID {
            for _ in 0..<maxBackfillPages {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: pageDelayNanoseconds)

                let page = try await fetchOrdersPage(baseURL: baseURL, apiKey: apiKey, afterId: cursorID, session: session)
                let items = page.items ?? []
                if items.isEmpty {
                    cache.hasReachedAccountBeginning = true
                    break
                }

                var reachedTarget = false
                for dto in items {
                    guard let id = dto.id?.value, let createdAt = parseISO8601(dto.createdAt) else { continue }
                    cache.ordersByID[id] = RemailCachedOrder(
                        id: id,
                        projectName: dto.projectName,
                        productType: dto.productType,
                        serviceMode: dto.serviceMode,
                        status: dto.status,
                        payAmount: max(0, dto.payAmount?.value ?? 0),
                        refundAmount: max(0, dto.refundAmount?.value ?? 0),
                        createdAt: createdAt
                    )
                    if id < (cache.oldestFetchedID ?? Int64.max) {
                        cache.oldestFetchedID = id
                    }
                    if createdAt < (cache.oldestFetchedDate ?? .distantFuture) {
                        cache.oldestFetchedDate = createdAt
                    }
                    if createdAt < targetStartDate {
                        reachedTarget = true
                    }
                }

                if page.hasNext != true {
                    cache.hasReachedAccountBeginning = true
                    break
                }
                if reachedTarget {
                    break
                }

                if let next = page.nextAfterId?.value, next < cursorID {
                    cursorID = next
                } else if let lastID = items.last?.id?.value, lastID < cursorID {
                    cursorID = lastID
                } else {
                    break
                }
            }
        }

        cache.lastSyncAt = Date()
        await RemailCacheStore.shared.save(cache, for: stationID)
        return Array(cache.ordersByID.values)
    }

    // MARK: - Console Dashboard Mode (`/v1/dashboard` — 1 Request, Full 365-Day History)

    private static func fetchViaConsoleDashboard(
        station: RelayStation,
        cookie: String,
        range: DateRangeSelection,
        session: URLSession
    ) async throws -> (StationUsageSnapshot, String?) {
        let baseURL = station.normalizedBaseURL
        let interval = range.resolvedInterval

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdFrom = iso.string(from: interval.start)
        let createdTo = iso.string(from: interval.end)

        async let dashTask = fetchConsoleDashboard(
            baseURL: baseURL,
            cookie: cookie,
            createdFrom: createdFrom,
            createdTo: createdTo,
            session: session
        )
        async let meTask = fetchConsoleMe(baseURL: baseURL, cookie: cookie, session: session)

        let dash = try await dashTask
        let me = try? await meTask

        let cal = Calendar.current
        let rawTrend = dash.trend ?? []
        var parsedPoints: [UsageBucketPoint] = []

        for pt in rawTrend {
            guard let date = parseDashboardLabel(pt.label, referenceStart: interval.start, isSingleDay: range.isSingleDay) else {
                continue
            }
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

            let spend = max(0, pt.spend?.value ?? 0)
            let orders = max(0, (pt.codeOrders?.value ?? 0) + (pt.purchaseOrders?.value ?? 0))

            parsedPoints.append(UsageBucketPoint(
                bucketKey: bucketKey,
                date: normalizedDate,
                requests: orders,
                inputTokens: 0,
                outputTokens: 0,
                cacheTokens: 0,
                totalTokens: 0,
                costUSD: spend,
                convertedCost: station.convertToDisplayCurrency(spend)
            ))
        }

        let filledPoints = RelayAPIService.fillMissingBuckets(
            points: parsedPoints,
            range: range,
            exchangeRate: station.exchangeRate
        )

        let rankMap = Dictionary(
            uniqueKeysWithValues: (dash.projectCodeRanking ?? []).map { ($0.name, $0.count?.value ?? 0) }
        )
        let projectStats: [ModelUsageStat] = (dash.projectSeries ?? []).compactMap { series in
            let sumSpend = (series.spend ?? []).reduce(0) { $0 + max(0, $1.value) }
            let count = rankMap[series.name] ?? 0
            guard sumSpend > 0 || count > 0 else { return nil }
            return ModelUsageStat(
                modelName: series.name,
                requests: count,
                inputTokens: 0,
                outputTokens: 0,
                cacheTokens: 0,
                totalTokens: 0,
                costUSD: sumSpend,
                convertedCost: station.convertToDisplayCurrency(sumSpend)
            )
        }
        .sorted { $0.convertedCost > $1.convertedCost }

        let totalSpend = filledPoints.reduce(0) { $0 + $1.costUSD }
        let totalOrders = filledPoints.reduce(Int64(0)) { $0 + $1.requests }
        let label = nonEmpty(me?.nickname) ?? nonEmpty(me?.name) ?? nonEmpty(me?.username) ?? station.name

        let snapshot = StationUsageSnapshot(
            stationID: station.id,
            accountLabel: label,
            balanceUSD: dash.stats?.walletBalance?.value,
            lifetimeUsedUSD: dash.stats?.historicalSpend?.value,
            periodCostUSD: totalSpend,
            periodConvertedCost: station.convertToDisplayCurrency(totalSpend),
            periodRequests: totalOrders,
            periodTokens: 0,
            periodInputTokens: 0,
            periodOutputTokens: 0,
            periodCacheTokens: 0,
            dailyPoints: filledPoints,
            modelStats: projectStats,
            updatedAt: Date(),
            errorMessage: nil
        )
        return (snapshot, me?.id.map { String($0.value) })
    }

    private static func parseDashboardLabel(_ rawLabel: String, referenceStart: Date, isSingleDay: Bool) -> Date? {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = DateFormatters.parseTrendDate(trimmed) {
            return d
        }
        let cal = Calendar.current
        if isSingleDay {
            let parts = trimmed.split(separator: ":")
            if let hour = parts.first.flatMap({ Int($0) }), (0...23).contains(hour) {
                return cal.date(bySettingHour: hour, minute: 0, second: 0, of: referenceStart)
            }
        }
        let sep: Character = trimmed.contains("-") ? "-" : "/"
        let comps = trimmed.split(separator: sep)
        if comps.count == 2, let m = Int(comps[0]), let day = Int(comps[1]) {
            let baseYear = cal.component(.year, from: referenceStart)
            let startMonth = cal.component(.month, from: referenceStart)
            let year = (m < startMonth && startMonth - m > 6) ? baseYear + 1 : baseYear
            return cal.date(from: DateComponents(year: year, month: m, day: day))
        }
        return nil
    }

    // MARK: - Aggregation (Cached Orders & Transactions)

    private static func aggregateCachedOrders(
        orders: [RemailCachedOrder],
        profile: RemailAPIKeyProfileDTO,
        wallet: RemailWalletDTO?,
        station: RelayStation,
        range: DateRangeSelection
    ) -> StationUsageSnapshot {
        let cal = Calendar.current
        var bucketMap: [String: UsageBucketPoint] = [:]
        var projectMap: [String: ModelUsageStat] = [:]

        for order in orders {
            let netSpend = max(0, order.payAmount - order.refundAmount)

            let normalizedDate: Date
            let bucketKey: String
            if range.isSingleDay {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: order.createdAt)
                normalizedDate = cal.date(from: comps) ?? order.createdAt
                bucketKey = DateFormatters.apiHour.string(from: normalizedDate)
            } else {
                normalizedDate = cal.startOfDay(for: order.createdAt)
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

            let projectLabel = buildProjectLabel(
                projectName: order.projectName,
                productType: order.productType,
                serviceMode: order.serviceMode
            )
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

    // MARK: - HTTP Requests (Console Cookie)

    private static func fetchConsoleMe(
        baseURL: String,
        cookie: String,
        session: URLSession
    ) async throws -> RemailMeDTO {
        guard let url = URL(string: "\(baseURL)/v1/me") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(baseURL)/console", forHTTPHeaderField: "Referer")
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, httpResp) = try await execute(req, session: session)
        try validateHTTP(data: data, statusCode: httpResp.statusCode)
        if let wrapped = try? JSONDecoder().decode(RemailMeResponse.self, from: data),
           let user = wrapped.user {
            return user
        }
        return try JSONDecoder().decode(RemailMeDTO.self, from: data)
    }

    private static func fetchConsoleWallet(
        baseURL: String,
        cookie: String,
        session: URLSession
    ) async throws -> RemailWalletDTO {
        guard let url = URL(string: "\(baseURL)/v1/wallet") else {
            throw RelayAPIError.invalidURL(baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(baseURL)/console", forHTTPHeaderField: "Referer")
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, httpResp) = try await execute(req, session: session)
        try validateHTTP(data: data, statusCode: httpResp.statusCode)
        return try JSONDecoder().decode(RemailWalletDTO.self, from: data)
    }

    private static func fetchConsoleDashboard(
        baseURL: String,
        cookie: String,
        createdFrom: String,
        createdTo: String,
        session: URLSession
    ) async throws -> RemailDashboardDTO {
        var comps = URLComponents(string: "\(baseURL)/v1/dashboard")
        comps?.queryItems = [
            URLQueryItem(name: "createdFrom", value: createdFrom),
            URLQueryItem(name: "createdTo", value: createdTo)
        ]
        guard let url = comps?.url else { throw RelayAPIError.invalidURL(baseURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(baseURL)/console", forHTTPHeaderField: "Referer")
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, httpResp) = try await execute(req, session: session)
        try validateHTTP(data: data, statusCode: httpResp.statusCode)
        do {
            return try JSONDecoder().decode(RemailDashboardDTO.self, from: data)
        } catch {
            throw RelayAPIError.decodingError("无法解析 ReMail /v1/dashboard 响应")
        }
    }

    // MARK: - HTTP Requests (OpenAPI Key)

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

    private static func fetchOrdersPage(
        baseURL: String,
        apiKey: String,
        afterId: Int64?,
        session: URLSession
    ) async throws -> RemailOrderListResponse {
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
        return try JSONDecoder().decode(RemailOrderListResponse.self, from: data)
    }

    private static func fetchTransactionsPaced(
        baseURL: String,
        apiKey: String,
        startDate: Date,
        endDate: Date,
        session: URLSession
    ) async throws -> [RemailTransactionDTO] {
        var collected: [RemailTransactionDTO] = []
        var afterId: Int64? = nil

        for pageIndex in 0..<maxBackfillPages {
            try Task.checkCancellation()
            if pageIndex > 0 {
                try await Task.sleep(nanoseconds: pageDelayNanoseconds)
            }

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
                if created > endDate { continue }
                if created < startDate {
                    reachedBeforeStart = true
                    break
                }
                collected.append(tx)
            }

            if reachedBeforeStart || page.hasNext != true { break }
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

    private static func buildProjectLabel(projectName: String?, productType: String?, serviceMode: String?) -> String {
        let project = nonEmpty(projectName)
        let product = localizedProductType(productType)
        let mode = serviceMode == "purchase" ? "购买" : "接码"
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
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                throw RelayAPIError.networkError("无效的服务器响应")
            }
            return (data, httpResp)
        } catch is CancellationError {
            throw CancellationError()
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
