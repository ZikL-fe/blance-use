import SwiftUI

struct SettingsView: View {
    @Environment(StationStore.self) private var store
    @Environment(ProfitLedgerStore.self) private var ledger
    @State private var defaultRateInput: String = ""
    @State private var showClearAlert: Bool = false
    @State private var showScheduleSheet: Bool = false
    @State private var showFixedCostSheet: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: "#10B981"))

                ScrollView {
                    VStack(spacing: 16) {
                        currencySettingsCard
                        profitAccountingCard
                        demoModeCard
                        protocolTipsCard
                        aboutCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("偏好设置")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                defaultRateInput = ValueFormatter.rate(store.defaultExchangeRate)
            }
            .sheet(isPresented: $showScheduleSheet) {
                ScheduleSettingsSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFixedCostSheet) {
                FixedCostEditorSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert("清除所有本地中转站？", isPresented: $showClearAlert) {
                Button("取消", role: .cancel) {}
                Button("全部清除", role: .destructive) {
                    for s in store.stations {
                        store.deleteStation(s)
                    }
                }
            } message: {
                Text("将清空所有已保存的中转站配置与钥匙串凭据，此操作不可撤销。")
            }
        }
    }

    private var currencySettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("货币与默认汇率", systemImage: "yensign.circle.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 8) {
                Text("全局显示货币")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 98))], spacing: 8) {
                    ForEach(DisplayCurrency.allCases) { curr in
                        let selected = store.displayCurrency == curr
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                store.displayCurrency = curr
                                store.defaultExchangeRate = curr.defaultRate
                                defaultRateInput = ValueFormatter.rate(curr.defaultRate)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(curr.symbol)
                                    .fontWeight(.bold)
                                Text(curr.rawValue)
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(
                                selected ? Color(hex: "#10B981") : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().opacity(0.25)

            VStack(alignment: .leading, spacing: 8) {
                Text("新增中转站默认汇率（1 USD → \(store.displayCurrency.rawValue)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text("$1 = \(store.displayCurrency.symbol)")
                        .font(.subheadline.weight(.semibold))
                    TextField("7.2", text: $defaultRateInput)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                        .padding(10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChange(of: defaultRateInput) { _, newValue in
                            if let parsed = Double(newValue.replacingOccurrences(of: ",", with: ".")), parsed > 0 {
                                store.defaultExchangeRate = parsed
                            }
                        }
                }

                Text("每个中转站均可独立覆盖汇率比例，修改此项仅影响后续新添加的站点默认值。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var profitAccountingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("每日利润核算与定时任务", systemImage: "clock.badge.checkmark.fill")
                .font(.headline.weight(.semibold))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动结算定时任务")
                        .font(.subheadline.weight(.medium))
                    Text(ledger.scheduleConfig.isEnabled
                         ? "每晚 \(ledger.scheduleConfig.formattedTime) 自动拉取各渠道成本与主站点销售额"
                         : "已暂停自动结算")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("配置") { showScheduleSheet = true }
                    .font(.caption.weight(.semibold))
                    .glassButtonStyle()
            }

            Divider().opacity(0.25)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每日固定成本（服务器等）")
                        .font(.subheadline.weight(.medium))
                    Text("当前合计 \(ValueFormatter.currency(ledger.totalDailyFixedCost, currency: store.displayCurrency))/天")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("编辑") { showFixedCostSheet = true }
                    .font(.caption.weight(.semibold))
                    .glassButtonStyle()
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var demoModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("演示数据体验模式", systemImage: "sparkles")
                        .font(.headline.weight(.semibold))
                    Text("使用 3 个不同汇率的中转站模拟数据预览 Liquid Glass 统计界面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.isDemoMode },
                    set: { enabled in
                        withAnimation {
                            if enabled {
                                store.enableDemoMode()
                            } else {
                                store.disableDemoMode()
                            }
                        }
                    }
                ))
                .labelsHidden()
                .tint(Color(hex: "#38BDF8"))
            }

            if !store.stations.isEmpty {
                Divider().opacity(0.25)
                HStack {
                    Text("已保存 \(store.stations.count) 个真实中转站")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空所有站点", role: .destructive) {
                        showClearAlert = true
                    }
                    .font(.caption.weight(.semibold))
                    .glassButtonStyle()
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var protocolTipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("接入与计费说明", systemImage: "book.closed.fill")
                .font(.headline.weight(.semibold))

            tipRow(
                title: "Sub2API 登录提示",
                detail: "账号密码模式直接调用 /api/v1/auth/login 并自动续期 Refresh Token；若站点开启验证码或 2FA，请使用网页端 JWT 访问令牌登录以获取完整趋势与模型统计。"
            )
            tipRow(
                title: "NewAPI / OneAPI 登录提示",
                detail: "支持用户名密码（独立隔离 Cookie 会话）与系统访问令牌（需同时填写个人设置中的数字 User ID 作为 New-Api-User 请求头）。超 28 天自定义查询自动分段拉取合并。"
            )
            tipRow(
                title: "ReMail (remail.best) 接入提示",
                detail: "ReMail 网页登录受 Cloudflare Turnstile 人机验证保护，官方开放 API 使用 Bearer rk-... 鉴权。请在 remail.best 个人中心生成 rk- API Key 填入，应用通过 /v1/open/wallet 与 /v1/open/orders 自动统计净消费积分（扣除退款）与项目明细。"
            )
            tipRow(
                title: "多平台独立汇率折算",
                detail: "针对不同中转站汇率差异（如 1.5元/刀、2元/刀、原价 7.2元/刀）以及 ReMail 积分折算比例，每个站点均可单独设置汇率并统一汇总到总览。"
            )
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }

    private func tipRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var aboutCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("RelayPulse")
                    .font(.headline.weight(.bold))
                Text("原生 SwiftUI · iOS 26 / iOS 27 Liquid Glass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1")")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .liquidGlassPill(interactive: false)
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 24)
    }
}
