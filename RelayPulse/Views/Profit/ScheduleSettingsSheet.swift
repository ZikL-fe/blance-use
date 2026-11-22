import SwiftUI

struct ScheduleSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfitLedgerStore.self) private var ledger

    @State private var isEnabled: Bool = true
    @State private var scheduledTime: Date = Date()
    @State private var notifyOnComplete: Bool = true
    @State private var autoCatchUpYesterday: Bool = true

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#10B981"))

                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 14) {
                            Toggle(isOn: $isEnabled) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("开启每日自动利润结算")
                                        .font(.headline.weight(.semibold))
                                    Text("每天定时自动拉取主站点销售额与全部渠道成本并存档")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(Color(hex: "#10B981"))

                            if isEnabled {
                                Divider().opacity(0.25)

                                DatePicker(
                                    "每日结算时间",
                                    selection: $scheduledTime,
                                    displayedComponents: .hourAndMinute
                                )
                                .environment(\.locale, Locale(identifier: "zh_CN"))

                                HStack {
                                    Button("恢复默认 23:59") {
                                        if let d = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) {
                                            scheduledTime = d
                                        }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .glassButtonStyle()
                                    Spacer()
                                }

                                Divider().opacity(0.25)

                                Toggle(isOn: $autoCatchUpYesterday) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("未命中时次日自动补算昨日")
                                            .font(.subheadline.weight(.semibold))
                                        Text("若 iOS 省电策略推迟了 23:59 后台唤醒，下次打开 App 自动拉取昨日精确账单，确保每日不漏账。")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tint(Color(hex: "#38BDF8"))

                                Toggle(isOn: $notifyOnComplete) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("结算完成后发送本地通知")
                                            .font(.subheadline.weight(.semibold))
                                        Text("推送当日销售额、总成本与净利润摘要")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tint(Color(hex: "#10B981"))
                            }
                        }
                        .padding(18)
                        .liquidGlassCard(cornerRadius: 22)

                        VStack(alignment: .leading, spacing: 8) {
                            Label("关于 iOS 定时任务机制", systemImage: "info.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(hex: "#38BDF8"))
                            Text("应用已注册系统 BGAppRefreshTask（com.relaypulse.app.daily-settlement），每天 23:59 触发后台刷新与前台时钟监控；同时配合「次日自动补算」双重保障，无论设备夜间是否锁屏休眠，都能精确保存每一天的各渠道成本、销售额与净利润。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("定时结算设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveConfig()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: loadConfig)
        }
    }

    private func loadConfig() {
        let cfg = ledger.scheduleConfig
        isEnabled = cfg.isEnabled
        notifyOnComplete = cfg.notifyOnComplete
        autoCatchUpYesterday = cfg.autoCatchUpYesterday
        scheduledTime = Calendar.current.date(bySettingHour: cfg.hour, minute: cfg.minute, second: 0, of: Date()) ?? Date()
    }

    private func saveConfig() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        ledger.scheduleConfig = AutoSettlementConfig(
            isEnabled: isEnabled,
            hour: comps.hour ?? 23,
            minute: comps.minute ?? 59,
            notifyOnComplete: notifyOnComplete,
            autoCatchUpYesterday: autoCatchUpYesterday
        )
        if notifyOnComplete {
            DailySettlementScheduler.shared.requestNotificationPermissionIfNeeded()
        }
        DailySettlementScheduler.shared.scheduleNextBackgroundTask()
    }
}
