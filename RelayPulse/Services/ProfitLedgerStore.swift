import Foundation
import Observation

@MainActor
@Observable
final class ProfitLedgerStore {
    // MARK: - Persisted State

    var records: [DailyProfitRecord] = [] {
        didSet { saveLedgerToDisk() }
    }

    var fixedCostItems: [FixedCostItem] = [] {
        didSet { saveFixedCosts() }
    }

    var scheduleConfig: AutoSettlementConfig = AutoSettlementConfig() {
        didSet { saveScheduleConfig() }
    }

    // MARK: - Live Runtime State

    var isSettling: Bool = false
    var settlingProgressText: String? = nil
    var lastAutoCheckMessage: String? = nil

    private enum Keys {
        static let fixedCosts = "relaypulse.fixedCosts.v1"
        static let scheduleConfig = "relaypulse.settlementSchedule.v1"
        static let lastAutoSettledDate = "relaypulse.lastAutoSettledDate.v1"
    }

    init() {
        loadFixedCosts()
        loadScheduleConfig()
        loadLedgerFromDisk()
    }

    // MARK: - Computed Helpers

    var totalDailyFixedCost: Double {
        fixedCostItems.filter(\.isEnabled).reduce(0) { $0 + $1.dailyAmount }
    }

    var sortedRecords: [DailyProfitRecord] {
        records.sorted { $0.dateKey > $1.dateKey }
    }

    func effectiveRecords(isDemoMode: Bool) -> [DailyProfitRecord] {
        if isDemoMode {
            return Self.demoProfitRecords
        }
        return sortedRecords
    }

    func record(for date: Date) -> DailyProfitRecord? {
        let key = DateFormatters.apiDay.string(from: date)
        return records.first(where: { $0.dateKey == key })
    }

    var todayKey: String {
        DateFormatters.apiDay.string(from: Date())
    }

    var lastAutoSettledDateKey: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastAutoSettledDate) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastAutoSettledDate) }
    }

    // MARK: - Fixed Cost CRUD

    func addFixedCost(name: String, dailyAmount: Double, note: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, dailyAmount >= 0 else { return }
        fixedCostItems.append(FixedCostItem(name: trimmed, dailyAmount: dailyAmount, isEnabled: true, note: note))
    }

    func updateFixedCost(_ item: FixedCostItem) {
        guard let idx = fixedCostItems.firstIndex(where: { $0.id == item.id }) else { return }
        fixedCostItems[idx] = item
    }

    func deleteFixedCost(_ item: FixedCostItem) {
        fixedCostItems.removeAll { $0.id == item.id }
    }

    func toggleFixedCost(_ item: FixedCostItem) {
        guard let idx = fixedCostItems.firstIndex(where: { $0.id == item.id }) else { return }
        fixedCostItems[idx].isEnabled.toggle()
    }

    // MARK: - Ledger Record Mutations

    func upsertRecord(_ record: DailyProfitRecord) {
        if let idx = records.firstIndex(where: { $0.dateKey == record.dateKey }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        records.sort { $0.dateKey > $1.dateKey }
    }

    func updateNote(for dateKey: String, note: String) {
        guard let idx = records.firstIndex(where: { $0.dateKey == dateKey }) else { return }
        records[idx].note = note
    }

    func deleteRecord(_ record: DailyProfitRecord) {
        records.removeAll { $0.dateKey == record.dateKey }
    }

    // MARK: - Daily Settlement Engine

    @discardableResult
    func settleDate(
        _ targetDate: Date,
        trigger: SettlementTrigger,
        using stationStore: StationStore
    ) async -> DailyProfitRecord {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: targetDate)
        let dateKey = DateFormatters.apiDay.string(from: dayStart)

        isSettling = true
        settlingProgressText = "正在拉取 \(dateKey) 各站点数据..."
        defer {
            isSettling = false
            settlingProgressText = nil
        }

        if stationStore.isDemoMode {
            try? await Task.sleep(for: .milliseconds(300))
            if let existing = Self.demoProfitRecords.first(where: { $0.dateKey == dateKey }) {
                return existing
            }
            return Self.makeDemoRecord(for: dayStart, index: 0, trigger: trigger)
        }

        let range = DateRangeSelection(preset: .custom, customStart: dayStart, customEnd: dayStart)
        let enabled = stationStore.stations.filter(\.isEnabled)
        let primaryStation = enabled.first(where: { $0.role == .primarySales })
        let costStations = enabled.filter { $0.role == .costChannel }

        // Fetch primary sales station + all cost channels concurrently
        let results: [(RelayStation, Result<StationUsageSnapshot, Error>)] = await withTaskGroup(
            of: (RelayStation, Result<StationUsageSnapshot, Error>).self
        ) { group in
            let allToFetch = (primaryStation.map { [$0] } ?? []) + costStations
            for station in allToFetch {
                let creds = KeychainStore.load(for: station.id)
                group.addTask {
                    do {
                        let res = try await RelayAPIService.fetchUsage(
                            station: station,
                            credentials: creds,
                            range: range
                        )
                        KeychainStore.save(res.updatedCredentials, for: station.id)
                        return (station, .success(res.snapshot))
                    } catch {
                        return (station, .failure(error))
                    }
                }
            }

            var collected: [(RelayStation, Result<StationUsageSnapshot, Error>)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        let resultMap = Dictionary(uniqueKeysWithValues: results.map { ($0.0.id, $0.1) })

        // Build SalesRecord from primary sales station
        var salesRecord: SalesRecord? = nil
        var revenue: Double = 0
        if let primary = primaryStation {
            switch resultMap[primary.id] {
            case .success(let snap):
                let conv = primary.convertToDisplayCurrency(snap.periodCostUSD)
                revenue = conv
                salesRecord = SalesRecord(
                    stationID: primary.id,
                    stationName: primary.name,
                    provider: primary.provider,
                    usageScope: primary.usageScope,
                    rawAmount: snap.periodCostUSD,
                    exchangeRate: primary.exchangeRate,
                    convertedRevenue: conv,
                    requests: snap.periodRequests,
                    tokens: snap.periodTokens,
                    errorMessage: nil
                )
            case .failure(let err):
                salesRecord = SalesRecord(
                    stationID: primary.id,
                    stationName: primary.name,
                    provider: primary.provider,
                    usageScope: primary.usageScope,
                    rawAmount: 0,
                    exchangeRate: primary.exchangeRate,
                    convertedRevenue: 0,
                    requests: 0,
                    tokens: 0,
                    errorMessage: err.localizedDescription
                )
            case .none:
                break
            }
        }

        // Build per-channel cost breakdown
        var channelCosts: [ChannelCostRecord] = []
        for station in costStations {
            switch resultMap[station.id] {
            case .success(let snap):
                let conv = station.convertToDisplayCurrency(snap.periodCostUSD)
                channelCosts.append(ChannelCostRecord(
                    id: station.id,
                    stationName: station.name,
                    provider: station.provider,
                    rawAmount: snap.periodCostUSD,
                    exchangeRate: station.exchangeRate,
                    convertedCost: conv,
                    requests: snap.periodRequests,
                    tokens: snap.periodTokens,
                    errorMessage: nil
                ))
            case .failure(let err):
                channelCosts.append(ChannelCostRecord(
                    id: station.id,
                    stationName: station.name,
                    provider: station.provider,
                    rawAmount: 0,
                    exchangeRate: station.exchangeRate,
                    convertedCost: 0,
                    requests: 0,
                    tokens: 0,
                    errorMessage: err.localizedDescription
                ))
            case .none:
                break
            }
        }
        channelCosts.sort { $0.convertedCost > $1.convertedCost }

        let totalChannelCost = channelCosts.reduce(0) { $0 + $1.convertedCost }
        let activeFixedItems = fixedCostItems.filter(\.isEnabled)
        let fixedTotal = activeFixedItems.reduce(0) { $0 + $1.dailyAmount }
        let totalCost = totalChannelCost + fixedTotal
        let netProfit = revenue - totalCost
        let margin = revenue > 0 ? (netProfit / revenue) : 0

        let existingNote = records.first(where: { $0.dateKey == dateKey })?.note ?? ""

        let settled = DailyProfitRecord(
            dateKey: dateKey,
            date: dayStart,
            currency: stationStore.displayCurrency,
            sales: salesRecord,
            revenue: revenue,
            channelCosts: channelCosts,
            totalChannelCost: totalChannelCost,
            fixedCostItems: activeFixedItems,
            fixedCost: fixedTotal,
            totalCost: totalCost,
            netProfit: netProfit,
            profitMargin: margin,
            settledAt: Date(),
            triggerSource: trigger,
            note: existingNote
        )

        upsertRecord(settled)
        if trigger == .scheduledAuto || trigger == .catchUpAuto {
            lastAutoSettledDateKey = dateKey
            lastAutoCheckMessage = "\(dateKey) 已自动结算"
        }
        return settled
    }

    func backfillRecentDays(_ days: Int, using stationStore: StationStore) async {
        guard !stationStore.isDemoMode else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for offset in 0..<max(1, min(days, 31)) {
            guard let target = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            _ = await settleDate(target, trigger: .backfill, using: stationStore)
        }
    }

    // MARK: - CSV Export for Financial Audit

    func exportCSV(isDemoMode: Bool) -> String {
        let list = effectiveRecords(isDemoMode: isDemoMode)
        var lines: [String] = []
        lines.append("\u{FEFF}日期,货币,主站点,销售额,上游渠道总成本,固定成本,总成本,净利润,毛利率(%),各渠道成本明细,结算方式,结算时间,备注")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for rec in list {
            let channelSummary = rec.channelCosts.map { ch in
                "\(ch.stationName):\(String(format: "%.2f", ch.convertedCost))(\(ch.provider.formatRawAmount(ch.rawAmount))x\(ValueFormatter.rate(ch.exchangeRate)))"
            }.joined(separator: " | ")

            let row: [String] = [
                rec.dateKey,
                rec.currency.rawValue,
                csvEscape(rec.sales?.stationName ?? "未配置主站点"),
                String(format: "%.2f", rec.revenue),
                String(format: "%.2f", rec.totalChannelCost),
                String(format: "%.2f", rec.fixedCost),
                String(format: "%.2f", rec.totalCost),
                String(format: "%.2f", rec.netProfit),
                String(format: "%.2f", rec.profitMargin * 100),
                csvEscape(channelSummary),
                rec.triggerSource.badgeTitle,
                df.string(from: rec.settledAt),
                csvEscape(rec.note)
            ]
            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - Demo Profit Records (14 days)

    static var demoProfitRecords: [DailyProfitRecord] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return makeDemoRecord(for: day, index: offset, trigger: offset == 0 ? .manual : .scheduledAuto)
        }
    }

    static func makeDemoRecord(for day: Date, index: Int, trigger: SettlementTrigger) -> DailyProfitRecord {
        let key = DateFormatters.apiDay.string(from: day)
        let wave = 0.78 + 0.34 * sin(Double(index) * 0.72) + 0.14 * cos(Double(index) * 1.4)

        let salesUSD = 58.0 * wave
        let salesRate = 7.2
        let revenue = salesUSD * salesRate

        let ch1Raw = 14.5 * wave
        let ch2Raw = 24.0 * (0.9 + 0.2 * cos(Double(index)))
        let ch3Raw = 6.2 * wave
        let ch4Raw = 15.0 * (0.85 + 0.25 * sin(Double(index) + 1))

        let channels: [ChannelCostRecord] = [
            ChannelCostRecord(
                id: StationStore.demoStations[0].id,
                stationName: "Sub2API 主力订阅池",
                provider: .sub2api,
                rawAmount: ch1Raw,
                exchangeRate: 2.0,
                convertedCost: ch1Raw * 2.0,
                requests: Int64(ch1Raw * 52),
                tokens: Int64(ch1Raw * 410_000),
                errorMessage: nil
            ),
            ChannelCostRecord(
                id: StationStore.demoStations[1].id,
                stationName: "NewAPI 特惠特价站",
                provider: .newAPI,
                rawAmount: ch2Raw,
                exchangeRate: 1.5,
                convertedCost: ch2Raw * 1.5,
                requests: Int64(ch2Raw * 46),
                tokens: Int64(ch2Raw * 380_000),
                errorMessage: nil
            ),
            ChannelCostRecord(
                id: StationStore.demoStations[2].id,
                stationName: "NewAPI 官转高稳站",
                provider: .newAPI,
                rawAmount: ch3Raw,
                exchangeRate: 7.2,
                convertedCost: ch3Raw * 7.2,
                requests: Int64(ch3Raw * 35),
                tokens: Int64(ch3Raw * 260_000),
                errorMessage: nil
            ),
            ChannelCostRecord(
                id: StationStore.demoStations[3].id,
                stationName: "ReMail 轻松收码",
                provider: .remail,
                rawAmount: ch4Raw,
                exchangeRate: 1.0,
                convertedCost: ch4Raw * 1.0,
                requests: Int64(max(3, Int(ch4Raw * 1.7))),
                tokens: 0,
                errorMessage: nil
            )
        ].sorted { $0.convertedCost > $1.convertedCost }

        let fixedItems = [
            FixedCostItem(name: "云服务器与数据库", dailyAmount: 35.0, isEnabled: true, note: "按月摊销"),
            FixedCostItem(name: "反代与专线节点", dailyAmount: 15.0, isEnabled: true, note: "CN2/BGP 线路")
        ]
        let channelTotal = channels.reduce(0) { $0 + $1.convertedCost }
        let fixedTotal = fixedItems.reduce(0) { $0 + $1.dailyAmount }
        let totalCost = channelTotal + fixedTotal
        let netProfit = revenue - totalCost
        let margin = revenue > 0 ? netProfit / revenue : 0

        let settledTime = Calendar.current.date(bySettingHour: 23, minute: 59, second: 5, of: day) ?? day

        return DailyProfitRecord(
            dateKey: key,
            date: day,
            currency: .cny,
            sales: SalesRecord(
                stationID: StationStore.demoPrimarySalesStation.id,
                stationName: StationStore.demoPrimarySalesStation.name,
                provider: .newAPI,
                usageScope: .siteWideAdmin,
                rawAmount: salesUSD,
                exchangeRate: salesRate,
                convertedRevenue: revenue,
                requests: Int64(salesUSD * 88),
                tokens: Int64(salesUSD * 980_000),
                errorMessage: nil
            ),
            revenue: revenue,
            channelCosts: channels,
            totalChannelCost: channelTotal,
            fixedCostItems: fixedItems,
            fixedCost: fixedTotal,
            totalCost: totalCost,
            netProfit: netProfit,
            profitMargin: margin,
            settledAt: index == 0 ? Date() : settledTime,
            triggerSource: trigger,
            note: ""
        )
    }

    // MARK: - Persistence (Application Support JSON + UserDefaults)

    private var ledgerFileURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RelayPulse", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("profit_ledger_v1.json")
    }

    private func loadLedgerFromDisk() {
        guard let data = try? Data(contentsOf: ledgerFileURL),
              let decoded = try? JSONDecoder().decode([DailyProfitRecord].self, from: data) else {
            return
        }
        records = decoded.sorted { $0.dateKey > $1.dateKey }
    }

    private func saveLedgerToDisk() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: ledgerFileURL, options: [.atomic])
    }

    private func loadFixedCosts() {
        if let data = UserDefaults.standard.data(forKey: Keys.fixedCosts),
           let decoded = try? JSONDecoder().decode([FixedCostItem].self, from: data) {
            fixedCostItems = decoded
        } else {
            // Default starter item at ¥0 so user sees where to fill server cost immediately
            fixedCostItems = [
                FixedCostItem(name: "服务器费用", dailyAmount: 0, isEnabled: true, note: "每日固定分摊费用")
            ]
        }
    }

    private func saveFixedCosts() {
        if let data = try? JSONEncoder().encode(fixedCostItems) {
            UserDefaults.standard.set(data, forKey: Keys.fixedCosts)
        }
    }

    private func loadScheduleConfig() {
        if let data = UserDefaults.standard.data(forKey: Keys.scheduleConfig),
           let decoded = try? JSONDecoder().decode(AutoSettlementConfig.self, from: data) {
            scheduleConfig = decoded
        }
    }

    private func saveScheduleConfig() {
        if let data = try? JSONEncoder().encode(scheduleConfig) {
            UserDefaults.standard.set(data, forKey: Keys.scheduleConfig)
        }
    }
}
