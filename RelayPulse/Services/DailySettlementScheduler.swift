import BackgroundTasks
import Foundation
import UserNotifications

@MainActor
final class DailySettlementScheduler {
    static let shared = DailySettlementScheduler()
    static let taskIdentifier = "com.relaypulse.app.daily-settlement"

    private var isRegistered = false
    private var foregroundTimerTask: Task<Void, Never>? = nil

    private weak var stationStore: StationStore?
    private weak var ledgerStore: ProfitLedgerStore?

    private init() {}

    // MARK: - Registration & Lifecycle

    func configure(stationStore: StationStore, ledgerStore: ProfitLedgerStore) {
        self.stationStore = stationStore
        self.ledgerStore = ledgerStore

        if !isRegistered {
            isRegistered = true
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.taskIdentifier,
                using: nil
            ) { task in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in
                    await DailySettlementScheduler.shared.handleBackgroundTask(refreshTask)
                }
            }
        }

        scheduleNextBackgroundTask()
        startForegroundClockWatcher()
    }

    /// Submits a BGAppRefreshTaskRequest targeting the next configured HH:mm (default 23:59).
    func scheduleNextBackgroundTask() {
        guard let ledgerStore else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)

        guard ledgerStore.scheduleConfig.isEnabled else { return }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = ledgerStore.scheduleConfig.nextFireDate()
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator or background refresh disabled gracefully ignored
        }
    }

    /// Requests local notification authorization when the user enables settlement alerts.
    func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Called whenever the app becomes active: ensures missed yesterday settlement is caught up
    /// if iOS deferred the 23:59 background task overnight.
    func checkAndCatchUpOnForeground() async {
        guard let stationStore, let ledgerStore else { return }
        guard ledgerStore.scheduleConfig.isEnabled,
              !stationStore.isDemoMode,
              !stationStore.stations.filter(\.isEnabled).isEmpty else {
            return
        }

        scheduleNextBackgroundTask()

        let cal = Calendar.current
        let now = Date()

        // 1. If autoCatchUpYesterday is enabled and yesterday has no record, settle yesterday!
        if ledgerStore.scheduleConfig.autoCatchUpYesterday,
           let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) {
            let yKey = DateFormatters.apiDay.string(from: yesterday)
            if ledgerStore.records.first(where: { $0.dateKey == yKey }) == nil {
                let record = await ledgerStore.settleDate(
                    yesterday,
                    trigger: .catchUpAuto,
                    using: stationStore
                )
                await postSettlementNotificationIfEnabled(record: record)
            }
        }

        // 2. If current time is already at or past today's target HH:mm (e.g. 23:59), settle today!
        if isAtOrPastScheduledTime(now: now, config: ledgerStore.scheduleConfig) {
            let todayKey = DateFormatters.apiDay.string(from: now)
            if ledgerStore.lastAutoSettledDateKey != todayKey {
                let record = await ledgerStore.settleDate(
                    now,
                    trigger: .scheduledAuto,
                    using: stationStore
                )
                await postSettlementNotificationIfEnabled(record: record)
            }
        }
    }

    // MARK: - Foreground 23:59 Clock Watcher

    private func startForegroundClockWatcher() {
        foregroundTimerTask?.cancel()
        foregroundTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { break }
                await self.evaluateForegroundTick()
            }
        }
    }

    private func evaluateForegroundTick() async {
        guard let stationStore, let ledgerStore else { return }
        guard ledgerStore.scheduleConfig.isEnabled,
              !ledgerStore.isSettling,
              !stationStore.isDemoMode,
              !stationStore.stations.filter(\.isEnabled).isEmpty else {
            return
        }

        let now = Date()
        guard isAtOrPastScheduledTime(now: now, config: ledgerStore.scheduleConfig) else { return }
        let todayKey = DateFormatters.apiDay.string(from: now)
        guard ledgerStore.lastAutoSettledDateKey != todayKey else { return }

        let record = await ledgerStore.settleDate(
            now,
            trigger: .scheduledAuto,
            using: stationStore
        )
        await postSettlementNotificationIfEnabled(record: record)
        scheduleNextBackgroundTask()
    }

    // MARK: - Background Task Execution

    private func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        // Always schedule the next night's run first
        scheduleNextBackgroundTask()

        guard let stationStore, let ledgerStore else {
            task.setTaskCompleted(success: false)
            return
        }

        let workTask = Task { @MainActor in
            guard ledgerStore.scheduleConfig.isEnabled,
                  !stationStore.isDemoMode,
                  !stationStore.stations.filter(\.isEnabled).isEmpty else {
                return
            }

            // If iOS woke us shortly after midnight (00:00–06:00), settle yesterday; otherwise settle today!
            let now = Date()
            let cal = Calendar.current
            let hour = cal.component(.hour, from: now)
            let targetDate: Date
            if hour < 6, let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) {
                targetDate = yesterday
            } else {
                targetDate = now
            }

            let record = await ledgerStore.settleDate(
                targetDate,
                trigger: .scheduledAuto,
                using: stationStore
            )
            await self.postSettlementNotificationIfEnabled(record: record)
        }

        task.expirationHandler = {
            workTask.cancel()
        }

        await workTask.value
        task.setTaskCompleted(success: !workTask.isCancelled)
    }

    // MARK: - Local Notification

    private func postSettlementNotificationIfEnabled(record: DailyProfitRecord) async {
        guard let ledgerStore, ledgerStore.scheduleConfig.notifyOnComplete else { return }

        let content = UNMutableNotificationContent()
        content.title = "RelayPulse 每日利润已结算 (\(record.dateKey))"
        let revStr = ValueFormatter.currency(record.revenue, currency: record.currency)
        let costStr = ValueFormatter.currency(record.totalCost, currency: record.currency)
        let sign = record.netProfit >= 0 ? "+" : ""
        let profitStr = "\(sign)\(ValueFormatter.currency(record.netProfit, currency: record.currency))"
        content.body = "销售额 \(revStr) · 总成本 \(costStr) · 净利润 \(profitStr)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "relaypulse.settlement.\(record.dateKey)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func isAtOrPastScheduledTime(now: Date, config: AutoSettlementConfig) -> Bool {
        let cal = Calendar.current
        let currentHour = cal.component(.hour, from: now)
        let currentMinute = cal.component(.minute, from: now)
        return (currentHour > config.hour) || (currentHour == config.hour && currentMinute >= config.minute)
    }
}
