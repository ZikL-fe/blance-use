import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class StationStore {
    // MARK: - Persisted State

    var stations: [RelayStation] = [] {
        didSet { saveStations() }
    }

    var displayCurrency: DisplayCurrency = .cny {
        didSet {
            UserDefaults.standard.set(displayCurrency.rawValue, forKey: Keys.displayCurrency)
        }
    }

    var defaultExchangeRate: Double = 7.2 {
        didSet {
            UserDefaults.standard.set(defaultExchangeRate, forKey: Keys.defaultExchangeRate)
        }
    }

    var isDemoMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isDemoMode, forKey: Keys.isDemoMode)
        }
    }

    // MARK: - Live Runtime State

    var selectedRange: DateRangeSelection = DateRangeSelection(preset: .last7Days)
    var snapshots: [UUID: StationUsageSnapshot] = [:]
    var refreshingStationIDs: Set<UUID> = []
    var isRefreshingAll: Bool = false
    var lastUpdatedAt: Date? = nil
    /// Dismissible notice shown to the user when one or more stations timed out (>30s) or fell back to cached data
    var fallbackNoticeBanner: String? = nil

    /// Tracks per-range cached snapshots in memory so switching ranges renders instantly while refreshing
    private var rangeSnapshotCache: [String: [UUID: StationUsageSnapshot]] = [:]
    /// Last known healthy snapshot per station across all refreshes (used as fallback if a 30s timeout occurs)
    private var lastHealthySnapshots: [UUID: StationUsageSnapshot] = [:]
    /// Active full-refresh task handle (cancelled automatically on new range selection to prevent duplicate RPM spikes)
    private var activeRefreshTask: Task<Void, Never>? = nil
    private var refreshGeneration: Int = 0

    private enum Keys {
        static let stations = "relaypulse.stations.v1"
        static let displayCurrency = "relaypulse.currency.v1"
        static let defaultExchangeRate = "relaypulse.defaultRate.v1"
        static let isDemoMode = "relaypulse.demoMode.v1"
        static let cachedSnapshots = "relaypulse.snapshots.cache.v1"
    }

    init() {
        loadPersistedState()
        if isDemoMode {
            generateDemoSnapshots()
        }
    }

    // MARK: - Effective Collections (Real or Demo)

    var effectiveStations: [RelayStation] {
        isDemoMode ? (Self.demoStations + [Self.demoPrimarySalesStation]) : stations
    }

    var enabledStations: [RelayStation] {
        effectiveStations.filter(\.isEnabled)
    }

    var costChannelStations: [RelayStation] {
        effectiveStations.filter { $0.role == .costChannel }
    }

    var enabledCostChannelStations: [RelayStation] {
        enabledStations.filter { $0.role == .costChannel }
    }

    var primarySalesStation: RelayStation? {
        effectiveStations.first(where: { $0.role == .primarySales && $0.isEnabled })
            ?? effectiveStations.first(where: { $0.role == .primarySales })
    }

    var overviewMetrics: OverviewMetrics {
        let activeStations = enabledCostChannelStations
        var totalConverted: Double = 0
        var totalUSD: Double = 0
        var totalRemConverted: Double = 0
        var totalRemUSD: Double = 0
        var totalReqs: Int64 = 0
        var totalToks: Int64 = 0
        var errorCount = 0

        var bucketAccumulator: [String: UsageBucketPoint] = [:]
        var modelAccumulator: [String: ModelUsageStat] = [:]
        var rawBreakdowns: [(RelayStation, StationUsageSnapshot?, Double, Double, Int64, Int64, Double?, Double?)] = []

        for station in activeStations {
            let snap = snapshots[station.id]
            if snap?.errorMessage != nil {
                errorCount += 1
            }

            let costUSD = snap?.periodCostUSD ?? 0
            let converted = station.convertToDisplayCurrency(costUSD)
            let reqs = snap?.periodRequests ?? 0
            let toks = snap?.periodTokens ?? 0
            let balUSD = snap?.balanceUSD
            let balConv = balUSD.map { station.convertToDisplayCurrency($0) }

            if !station.provider.usesPointsUnit {
                totalUSD += costUSD
            }
            totalConverted += converted
            totalReqs += reqs
            totalToks += toks
            if let bUSD = balUSD {
                if !station.provider.usesPointsUnit {
                    totalRemUSD += bUSD
                }
                totalRemConverted += station.convertToDisplayCurrency(bUSD)
            }

            rawBreakdowns.append((station, snap, converted, costUSD, reqs, toks, balConv, balUSD))

            if let points = snap?.dailyPoints {
                for p in points {
                    let pointConv = station.convertToDisplayCurrency(p.costUSD)
                    if let existing = bucketAccumulator[p.bucketKey] {
                        bucketAccumulator[p.bucketKey] = UsageBucketPoint(
                            bucketKey: p.bucketKey,
                            date: existing.date,
                            requests: existing.requests + p.requests,
                            inputTokens: existing.inputTokens + p.inputTokens,
                            outputTokens: existing.outputTokens + p.outputTokens,
                            cacheTokens: existing.cacheTokens + p.cacheTokens,
                            totalTokens: existing.totalTokens + p.totalTokens,
                            costUSD: existing.costUSD + p.costUSD,
                            convertedCost: existing.convertedCost + pointConv
                        )
                    } else {
                        bucketAccumulator[p.bucketKey] = UsageBucketPoint(
                            bucketKey: p.bucketKey,
                            date: p.date,
                            requests: p.requests,
                            inputTokens: p.inputTokens,
                            outputTokens: p.outputTokens,
                            cacheTokens: p.cacheTokens,
                            totalTokens: p.totalTokens,
                            costUSD: p.costUSD,
                            convertedCost: pointConv
                        )
                    }
                }
            }

            if let models = snap?.modelStats {
                for m in models {
                    let modelConv = station.convertToDisplayCurrency(m.costUSD)
                    if let existing = modelAccumulator[m.modelName] {
                        modelAccumulator[m.modelName] = ModelUsageStat(
                            modelName: m.modelName,
                            requests: existing.requests + m.requests,
                            inputTokens: existing.inputTokens + m.inputTokens,
                            outputTokens: existing.outputTokens + m.outputTokens,
                            cacheTokens: existing.cacheTokens + m.cacheTokens,
                            totalTokens: existing.totalTokens + m.totalTokens,
                            costUSD: existing.costUSD + m.costUSD,
                            convertedCost: existing.convertedCost + modelConv
                        )
                    } else {
                        modelAccumulator[m.modelName] = ModelUsageStat(
                            modelName: m.modelName,
                            requests: m.requests,
                            inputTokens: m.inputTokens,
                            outputTokens: m.outputTokens,
                            cacheTokens: m.cacheTokens,
                            totalTokens: m.totalTokens,
                            costUSD: m.costUSD,
                            convertedCost: modelConv
                        )
                    }
                }
            }
        }

        let breakdowns: [StationBreakdownItem] = rawBreakdowns.map { item in
            let share = totalConverted > 0 ? (item.2 / totalConverted) : 0
            return StationBreakdownItem(
                station: item.0,
                snapshot: item.1,
                convertedCost: item.2,
                costUSD: item.3,
                share: share,
                requests: item.4,
                tokens: item.5,
                balanceConverted: item.6,
                balanceUSD: item.7
            )
        }
        .sorted { $0.convertedCost > $1.convertedCost }

        let series: [UsageBucketPoint]
        if bucketAccumulator.isEmpty {
            series = RelayAPIService.fillMissingBuckets(points: [], range: selectedRange, exchangeRate: 1)
        } else {
            series = bucketAccumulator.values.sorted { $0.date < $1.date }
        }

        let topModels = modelAccumulator.values
            .sorted { $0.convertedCost > $1.convertedCost }

        return OverviewMetrics(
            totalConvertedCost: totalConverted,
            totalCostUSD: totalUSD,
            totalRemainingConverted: totalRemConverted,
            totalRemainingUSD: totalRemUSD,
            totalRequests: totalReqs,
            totalTokens: totalToks,
            combinedSeries: series,
            stationBreakdowns: breakdowns,
            topModels: topModels,
            activeStationCount: activeStations.count,
            errorStationCount: errorCount
        )
    }

    // MARK: - CRUD Operations

    func addStation(_ station: RelayStation, credentials: StationSecretCredentials) {
        if isDemoMode {
            isDemoMode = false
            snapshots.removeAll()
        }
        if station.role == .primarySales {
            demoteOtherPrimarySales(except: station.id)
        }
        KeychainStore.save(credentials, for: station.id)
        stations.append(station)
        Task {
            await refreshStation(station)
        }
    }

    func updateStation(_ station: RelayStation, credentials: StationSecretCredentials?) {
        guard let idx = stations.firstIndex(where: { $0.id == station.id }) else { return }
        if station.role == .primarySales {
            demoteOtherPrimarySales(except: station.id)
        }
        stations[idx] = station
        if let credentials {
            KeychainStore.save(credentials, for: station.id)
        }
        rangeSnapshotCache.removeAll()
        // Re-apply exchange rate immediately to cached snapshot for snappy UX
        if var existing = snapshots[station.id] {
            existing.periodConvertedCost = station.convertToDisplayCurrency(existing.periodCostUSD)
            existing.dailyPoints = existing.dailyPoints.map { pt in
                var copy = pt
                copy.convertedCost = station.convertToDisplayCurrency(pt.costUSD)
                return copy
            }
            existing.modelStats = existing.modelStats.map { m in
                var copy = m
                copy.convertedCost = station.convertToDisplayCurrency(m.costUSD)
                return copy
            }
            snapshots[station.id] = existing
        }
        Task {
            await refreshStation(station)
        }
    }

    func updateExchangeRate(for stationID: UUID, newRate: Double) {
        guard newRate > 0 else { return }
        if isDemoMode { return }
        guard let idx = stations.firstIndex(where: { $0.id == stationID }) else { return }
        var updated = stations[idx]
        updated.exchangeRate = newRate
        updateStation(updated, credentials: nil)
    }

    func deleteStation(_ station: RelayStation) {
        stations.removeAll { $0.id == station.id }
        snapshots.removeValue(forKey: station.id)
        rangeSnapshotCache.removeAll()
        KeychainStore.delete(for: station.id)
        saveCachedSnapshots()
    }

    func toggleStationEnabled(_ station: RelayStation) {
        guard !isDemoMode, let idx = stations.firstIndex(where: { $0.id == station.id }) else { return }
        stations[idx].isEnabled.toggle()
        let toggled = stations[idx]
        if toggled.isEnabled && snapshots[toggled.id] == nil {
            Task {
                await refreshStation(toggled)
            }
        }
    }

    func setPrimarySalesStation(_ station: RelayStation) {
        guard !isDemoMode, station.provider != .remail else { return }
        for i in stations.indices {
            if stations[i].id == station.id {
                stations[i].role = .primarySales
            } else if stations[i].role == .primarySales {
                stations[i].role = .costChannel
            }
        }
        Task {
            await refreshAll()
        }
    }

    private func demoteOtherPrimarySales(except keepID: UUID) {
        for i in stations.indices where stations[i].id != keepID && stations[i].role == .primarySales {
            stations[i].role = .costChannel
        }
    }

    // MARK: - Refreshing

    private func rangeCacheKey(for range: DateRangeSelection) -> String {
        let interval = range.resolvedInterval
        return "\(range.preset.rawValue)|\(DateFormatters.apiDay.string(from: interval.start))|\(DateFormatters.apiDay.string(from: interval.end))"
    }

    func updateRange(_ newRange: DateRangeSelection) {
        selectedRange = newRange
        let key = rangeCacheKey(for: newRange)

        // Show cached snapshot for this range immediately if available (zero flicker!)
        if let cachedForRange = rangeSnapshotCache[key] {
            snapshots = cachedForRange
        }

        // Cancel any in-flight refresh for the previous range so requests never pile up or overwrite new data
        activeRefreshTask?.cancel()
        refreshGeneration += 1
        let gen = refreshGeneration

        activeRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll(generation: gen, targetRange: newRange)
        }
    }

    func refreshAll() async {
        activeRefreshTask?.cancel()
        refreshGeneration += 1
        let gen = refreshGeneration
        let range = selectedRange

        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll(generation: gen, targetRange: range)
        }
        activeRefreshTask = task
        await task.value
    }

    private func refreshAll(generation: Int, targetRange: DateRangeSelection) async {
        if isDemoMode {
            isRefreshingAll = true
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            generateDemoSnapshots()
            isRefreshingAll = false
            lastUpdatedAt = Date()
            return
        }

        let targetStations = stations.filter(\.isEnabled)
        guard !targetStations.isEmpty else {
            isRefreshingAll = false
            return
        }

        isRefreshingAll = true

        await withTaskGroup(of: Void.self) { group in
            for station in targetStations {
                group.addTask { [weak self] in
                    await self?.refreshStation(station, rangeOverride: targetRange, expectedGeneration: generation)
                }
            }
        }

        guard !Task.isCancelled, generation == refreshGeneration else { return }
        isRefreshingAll = false
        lastUpdatedAt = Date()
        rangeSnapshotCache[rangeCacheKey(for: targetRange)] = snapshots
        saveCachedSnapshots()
    }

    func refreshStation(
        _ station: RelayStation,
        rangeOverride: DateRangeSelection? = nil,
        expectedGeneration: Int? = nil
    ) async {
        if isDemoMode {
            generateDemoSnapshots()
            return
        }

        let range = rangeOverride ?? selectedRange
        refreshingStationIDs.insert(station.id)
        defer { refreshingStationIDs.remove(station.id) }

        let creds = KeychainStore.load(for: station.id)
        let startedAt = Date()
        let rangeKey = rangeCacheKey(for: range)

        AuditLogStore.shared.log(
            .debug,
            category: .sync,
            station: station.name,
            message: "开始同步数据（\(range.preset.title)）",
            detail: "\(station.provider.displayName) · \(station.hostLabel)"
        )

        do {
            let result = try await RelayAPIService.fetchUsage(
                station: station,
                credentials: creds,
                range: range,
                timeoutSeconds: RelayAPIService.defaultTimeoutSeconds
            )

            // Ignore stale results if user already switched to another time range
            if Task.isCancelled { return }
            if let expected = expectedGeneration, expected != refreshGeneration { return }

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            KeychainStore.save(result.updatedCredentials, for: station.id)

            // Persist any newly discovered userID or quotaPerUnit quietly
            if let idx = stations.firstIndex(where: { $0.id == station.id }) {
                var mutable = stations[idx]
                var changed = false
                if let uid = result.detectedUserID, !uid.isEmpty, mutable.userID != uid {
                    mutable.userID = uid
                    changed = true
                }
                if let qpu = result.detectedQuotaPerUnit, qpu > 0, abs(mutable.quotaPerUnit - qpu) > 1 {
                    mutable.quotaPerUnit = qpu
                    changed = true
                }
                if changed {
                    stations[idx] = mutable
                }
            }

            var freshSnapshot = result.snapshot
            freshSnapshot.isUsingFallbackCache = false
            snapshots[station.id] = freshSnapshot
            lastHealthySnapshots[station.id] = freshSnapshot
            rangeSnapshotCache[rangeKey, default: [:]][station.id] = freshSnapshot
            lastUpdatedAt = Date()
            saveCachedSnapshots()

            // Clear fallback notice if all enabled stations are healthy now
            if enabledStations.allSatisfy({ snapshots[$0.id]?.isUsingFallbackCache != true }) {
                fallbackNoticeBanner = nil
            }

            AuditLogStore.shared.log(
                .info,
                category: .sync,
                station: station.name,
                message: "同步成功（\(range.preset.title)）",
                detail: "消耗 \(ValueFormatter.currency(freshSnapshot.periodConvertedCost, currency: displayCurrency)) · \(freshSnapshot.periodRequests) \(station.provider.requestUnitLabel)",
                durationMs: elapsedMs
            )
        } catch is CancellationError {
            AuditLogStore.shared.log(
                .debug,
                category: .sync,
                station: station.name,
                message: "已取消旧的同步请求（切换了查询范围）"
            )
            return
        } catch {
            if Task.isCancelled { return }
            if let expected = expectedGeneration, expected != refreshGeneration { return }

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let isTimeout: Bool = {
                if case RelayAPIError.timeout = error { return true }
                return false
            }()

            // Pick the freshest available cached snapshot for fallback: same-range cache -> current snapshot -> last healthy snapshot
            let fallbackSource = rangeSnapshotCache[rangeKey]?[station.id]
                ?? snapshots[station.id]
                ?? lastHealthySnapshots[station.id]

            if var cached = fallbackSource {
                let cacheTimeStr = DateFormatters.shortTime.string(from: cached.updatedAt)
                let notice: String
                if isTimeout {
                    notice = "请求超过 30 秒未返回，已使用 \(cacheTimeStr) 的缓存数据兜底"
                    fallbackNoticeBanner = "「\(station.name)」更新超时（>30s），已使用最近一次缓存数据兜底展示"
                } else {
                    notice = "本次更新失败（\(error.localizedDescription)），已使用 \(cacheTimeStr) 的缓存数据兜底"
                    fallbackNoticeBanner = "「\(station.name)」同步异常，已保留最近一次缓存数据兜底展示"
                }
                cached.errorMessage = notice
                cached.isUsingFallbackCache = true
                snapshots[station.id] = cached

                AuditLogStore.shared.log(
                    .warning,
                    category: .sync,
                    station: station.name,
                    message: isTimeout ? "同步超时 (>30s)，已自动降级使用缓存兜底" : "同步异常，已自动降级使用缓存兜底",
                    detail: "原因: \(error.localizedDescription) | 缓存时间: \(cacheTimeStr)",
                    durationMs: elapsedMs
                )
            } else {
                let errMsg = isTimeout ? "请求超过 30 秒未返回，且暂无可用历史缓存" : error.localizedDescription
                if isTimeout {
                    fallbackNoticeBanner = "「\(station.name)」更新超时（>30s），暂无历史缓存可兜底"
                }
                snapshots[station.id] = StationUsageSnapshot(
                    stationID: station.id,
                    accountLabel: station.accountIdentifier.isEmpty ? station.name : station.accountIdentifier,
                    balanceUSD: nil,
                    lifetimeUsedUSD: nil,
                    periodCostUSD: 0,
                    periodConvertedCost: 0,
                    periodRequests: 0,
                    periodTokens: 0,
                    periodInputTokens: 0,
                    periodOutputTokens: 0,
                    periodCacheTokens: 0,
                    dailyPoints: RelayAPIService.fillMissingBuckets(points: [], range: range, exchangeRate: station.exchangeRate),
                    modelStats: [],
                    updatedAt: Date(),
                    errorMessage: errMsg,
                    isUsingFallbackCache: false
                )

                AuditLogStore.shared.log(
                    .error,
                    category: .sync,
                    station: station.name,
                    message: isTimeout ? "同步超时 (>30s) 且无可用缓存" : "同步失败",
                    detail: error.localizedDescription,
                    durationMs: elapsedMs
                )
            }
        }
    }

    // MARK: - Demo Mode

    func enableDemoMode() {
        isDemoMode = true
        generateDemoSnapshots()
        lastUpdatedAt = Date()
    }

    func disableDemoMode() {
        isDemoMode = false
        snapshots.removeAll()
        loadCachedSnapshots()
    }

    static let demoPrimarySalesStation = RelayStation(
        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        name: "我的对外主站 (销售额)",
        provider: .newAPI,
        baseURL: "https://sales.my-relay.demo",
        authMethod: .accessToken,
        role: .primarySales,
        usageScope: .siteWideAdmin,
        accountIdentifier: "root_admin",
        userID: "1",
        exchangeRate: 7.2,
        accentHex: "#EC4899"
    )

    static let demoStations: [RelayStation] = [
        RelayStation(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Sub2API 主力订阅池",
            provider: .sub2api,
            baseURL: "https://sub.prism-relay.demo",
            authMethod: .password,
            accountIdentifier: "alex@relaypulse.dev",
            exchangeRate: 2.0,
            accentHex: "#38BDF8"
        ),
        RelayStation(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "NewAPI 特惠特价站",
            provider: .newAPI,
            baseURL: "https://api.nebula-hub.demo",
            authMethod: .accessToken,
            accountIdentifier: "coder_pro",
            userID: "1024",
            exchangeRate: 1.5,
            accentHex: "#A855F7"
        ),
        RelayStation(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "NewAPI 官转高稳站",
            provider: .newAPI,
            baseURL: "https://gateway.aurora-ai.demo",
            authMethod: .password,
            accountIdentifier: "enterprise_01",
            userID: "88",
            exchangeRate: 7.2,
            accentHex: "#10B981"
        ),
        RelayStation(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "ReMail 轻松收码",
            provider: .remail,
            baseURL: "https://remail.best",
            authMethod: .accessToken,
            accountIdentifier: "rk-demo-key",
            exchangeRate: 1.0,
            accentHex: "#F59E0B"
        )
    ]

    private func generateDemoSnapshots() {
        let range = selectedRange
        let emptyTemplate = RelayAPIService.fillMissingBuckets(points: [], range: range, exchangeRate: 1)
        let bucketCount = max(1, emptyTemplate.count)

        let configs: [(UUID, Double, Double, Double, [(String, Double)])] = [
            (
                Self.demoStations[0].id,
                42.80, // balance USD
                3.4,   // avg daily USD
                2.0,
                [("claude-sonnet-4-5", 0.54), ("claude-opus-4-1", 0.28), ("gpt-5", 0.18)]
            ),
            (
                Self.demoStations[1].id,
                68.50,
                5.1,
                1.5,
                [("deepseek-v3.2", 0.42), ("gemini-2.5-pro", 0.35), ("gpt-4.1", 0.23)]
            ),
            (
                Self.demoStations[2].id,
                18.20,
                1.6,
                7.2,
                [("gpt-5-codex", 0.62), ("o3", 0.38)]
            ),
            (
                Self.demoStations[3].id,
                168.50, // balance points
                12.4,   // avg daily points
                1.0,
                [("Microsoft 账号验证码 · Microsoft", 0.52), ("Gmail 接码 · Gmail", 0.31), ("iCloud 接码 · iCloud", 0.17)]
            )
        ]

        var generated: [UUID: StationUsageSnapshot] = [:]

        for (stationIdx, cfg) in configs.enumerated() {
            let station = Self.demoStations[stationIdx]
            let isRemail = station.provider == .remail
            let scalePerBucket = range.isSingleDay ? (cfg.2 / Double(bucketCount) * 1.1) : cfg.2
            var points: [UsageBucketPoint] = []
            for (i, basePt) in emptyTemplate.enumerated() {
                let wave = 0.55 + 0.45 * sin(Double(i + stationIdx * 2) * 0.85) + 0.2 * cos(Double(i * 3 + stationIdx))
                let costRaw = max(0.05, scalePerBucket * max(0.25, wave))
                let reqs = Int64(max(isRemail ? 2 : 4, Int(costRaw * (isRemail ? 1.8 : 48))))
                let inputT: Int64 = isRemail ? 0 : Int64(costRaw * 210_000)
                let outputT: Int64 = isRemail ? 0 : Int64(costRaw * 72_000)
                let cacheT: Int64 = isRemail ? 0 : Int64(costRaw * 165_000)
                points.append(UsageBucketPoint(
                    bucketKey: basePt.bucketKey,
                    date: basePt.date,
                    requests: reqs,
                    inputTokens: inputT,
                    outputTokens: outputT,
                    cacheTokens: cacheT,
                    totalTokens: inputT + outputT + cacheT,
                    costUSD: costRaw,
                    convertedCost: station.convertToDisplayCurrency(costRaw)
                ))
            }

            let sumUSD = points.reduce(0) { $0 + $1.costUSD }
            let sumReqs = points.reduce(Int64(0)) { $0 + $1.requests }
            let sumInput = points.reduce(Int64(0)) { $0 + $1.inputTokens }
            let sumOutput = points.reduce(Int64(0)) { $0 + $1.outputTokens }
            let sumCache = points.reduce(Int64(0)) { $0 + $1.cacheTokens }
            let sumTokens = sumInput + sumOutput + sumCache

            let models = cfg.4.map { (name, weight) in
                let mUSD = sumUSD * weight
                return ModelUsageStat(
                    modelName: name,
                    requests: Int64(Double(sumReqs) * weight),
                    inputTokens: Int64(Double(sumInput) * weight),
                    outputTokens: Int64(Double(sumOutput) * weight),
                    cacheTokens: Int64(Double(sumCache) * weight),
                    totalTokens: Int64(Double(sumTokens) * weight),
                    costUSD: mUSD,
                    convertedCost: station.convertToDisplayCurrency(mUSD)
                )
            }

            generated[station.id] = StationUsageSnapshot(
                stationID: station.id,
                accountLabel: station.accountIdentifier,
                balanceUSD: cfg.1,
                lifetimeUsedUSD: sumUSD * 4.2,
                periodCostUSD: sumUSD,
                periodConvertedCost: station.convertToDisplayCurrency(sumUSD),
                periodRequests: sumReqs,
                periodTokens: sumTokens,
                periodInputTokens: sumInput,
                periodOutputTokens: sumOutput,
                periodCacheTokens: sumCache,
                dailyPoints: points,
                modelStats: models,
                updatedAt: Date(),
                errorMessage: nil
            )
        }

        // Also generate demo snapshot for Primary Sales station
        let salesStation = Self.demoPrimarySalesStation
        let salesScale = range.isSingleDay ? (56.0 / Double(bucketCount)) : 56.0
        var salesPoints: [UsageBucketPoint] = []
        for (i, basePt) in emptyTemplate.enumerated() {
            let wave = 0.72 + 0.34 * sin(Double(i) * 0.78) + 0.16 * cos(Double(i * 2))
            let usd = max(0.5, salesScale * max(0.3, wave))
            let reqs = Int64(max(12, Int(usd * 85)))
            let toks = Int64(usd * 950_000)
            salesPoints.append(UsageBucketPoint(
                bucketKey: basePt.bucketKey,
                date: basePt.date,
                requests: reqs,
                inputTokens: toks / 2,
                outputTokens: toks / 5,
                cacheTokens: toks * 3 / 10,
                totalTokens: toks,
                costUSD: usd,
                convertedCost: salesStation.convertToDisplayCurrency(usd)
            ))
        }
        let totalSalesUSD = salesPoints.reduce(0) { $0 + $1.costUSD }
        generated[salesStation.id] = StationUsageSnapshot(
            stationID: salesStation.id,
            accountLabel: "全站销售额汇总",
            balanceUSD: nil,
            lifetimeUsedUSD: totalSalesUSD * 5.0,
            periodCostUSD: totalSalesUSD,
            periodConvertedCost: salesStation.convertToDisplayCurrency(totalSalesUSD),
            periodRequests: salesPoints.reduce(0) { $0 + $1.requests },
            periodTokens: salesPoints.reduce(0) { $0 + $1.totalTokens },
            periodInputTokens: salesPoints.reduce(0) { $0 + $1.inputTokens },
            periodOutputTokens: salesPoints.reduce(0) { $0 + $1.outputTokens },
            periodCacheTokens: salesPoints.reduce(0) { $0 + $1.cacheTokens },
            dailyPoints: salesPoints,
            modelStats: [
                ModelUsageStat(modelName: "claude-sonnet-4-5", requests: 1840, inputTokens: 0, outputTokens: 0, cacheTokens: 0, totalTokens: 19_200_000, costUSD: totalSalesUSD * 0.48, convertedCost: salesStation.convertToDisplayCurrency(totalSalesUSD * 0.48)),
                ModelUsageStat(modelName: "gpt-5", requests: 1120, inputTokens: 0, outputTokens: 0, cacheTokens: 0, totalTokens: 11_800_000, costUSD: totalSalesUSD * 0.32, convertedCost: salesStation.convertToDisplayCurrency(totalSalesUSD * 0.32)),
                ModelUsageStat(modelName: "deepseek-v3.2", requests: 980, inputTokens: 0, outputTokens: 0, cacheTokens: 0, totalTokens: 9_600_000, costUSD: totalSalesUSD * 0.20, convertedCost: salesStation.convertToDisplayCurrency(totalSalesUSD * 0.20))
            ],
            updatedAt: Date(),
            errorMessage: nil
        )

        snapshots = generated
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        if let rawCurrency = UserDefaults.standard.string(forKey: Keys.displayCurrency),
           let parsed = DisplayCurrency(rawValue: rawCurrency) {
            displayCurrency = parsed
        }
        let storedRate = UserDefaults.standard.double(forKey: Keys.defaultExchangeRate)
        if storedRate > 0 {
            defaultExchangeRate = storedRate
        }
        isDemoMode = UserDefaults.standard.bool(forKey: Keys.isDemoMode)

        if let data = UserDefaults.standard.data(forKey: Keys.stations),
           let decoded = try? JSONDecoder().decode([RelayStation].self, from: data) {
            stations = decoded
        }

        if !isDemoMode {
            loadCachedSnapshots()
        }
    }

    private func saveStations() {
        if let encoded = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(encoded, forKey: Keys.stations)
        }
    }

    private func saveCachedSnapshots() {
        guard !isDemoMode else { return }
        if let encoded = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(encoded, forKey: Keys.cachedSnapshots)
        }
    }

    private func loadCachedSnapshots() {
        if let data = UserDefaults.standard.data(forKey: Keys.cachedSnapshots),
           let decoded = try? JSONDecoder().decode([UUID: StationUsageSnapshot].self, from: data) {
            snapshots = decoded
            for (id, snap) in decoded where snap.errorMessage == nil {
                lastHealthySnapshots[id] = snap
            }
        }
    }
}
