import SwiftUI

struct StationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StationStore.self) private var store

    let editingStation: RelayStation?
    var defaultRole: StationRole = .costChannel

    @State private var name: String = ""
    @State private var provider: RelayProviderType = .sub2api
    @State private var role: StationRole = .costChannel
    @State private var usageScope: UsageScope = .personalSelf
    @State private var baseURL: String = ""
    @State private var authMethod: AuthMethod = .password
    @State private var accountIdentifier: String = ""
    @State private var password: String = ""
    @State private var accessToken: String = ""
    @State private var userID: String = ""
    @State private var exchangeRateText: String = "7.2"
    @State private var quotaPerUnitText: String = "500000"
    @State private var accentHex: String = "#38BDF8"
    @State private var showSecretText: Bool = false
    @State private var showAdvanced: Bool = false
    @State private var showWebLoginSheet: Bool = false

    @State private var isTesting: Bool = false
    @State private var testStatusMessage: String? = nil
    @State private var testSucceeded: Bool = false
    @State private var verifiedCredentials: StationSecretCredentials? = nil

    private var isEditing: Bool { editingStation != nil }

    private var parsedRate: Double {
        max(0.000001, Double(exchangeRateText.replacingOccurrences(of: ",", with: ".")) ?? store.defaultExchangeRate)
    }

    private var parsedQuotaPerUnit: Double {
        max(1, Double(quotaPerUnitText) ?? 500_000)
    }

    private var canSave: Bool {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return false }
        switch authMethod {
        case .password:
            return !accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        case .accessToken:
            return !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackground(accent: Color(hex: accentHex))

                ScrollView {
                    VStack(spacing: 16) {
                        providerSelectorCard
                        if provider != .remail {
                            stationRoleCard
                        }
                        stationInfoCard
                        authCredentialsCard
                        exchangeRateCard
                        connectionTestCard
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(isEditing ? "编辑中转站" : "登录新中转站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "保存" : "添加") {
                        saveStation()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave || isTesting)
                }
            }
            .onAppear(perform: loadInitialValues)
            .sheet(isPresented: $showWebLoginSheet) {
                WebLoginSheet(
                    baseURL: baseURL,
                    provider: provider
                ) { captured in
                    applyWebLoginCapture(captured)
                }
            }
        }
    }

    // MARK: - Cards

    private var providerSelectorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("站点 / 平台类型")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            AdaptiveGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(RelayProviderType.allCases) { item in
                        let selected = provider == item
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                let previous = provider
                                provider = item
                                if !item.supportsPasswordLogin {
                                    authMethod = .accessToken
                                }
                                if item == .remail {
                                    role = .costChannel
                                    usageScope = .personalSelf
                                }
                                if !isEditing {
                                    accentHex = item == .sub2api ? "#38BDF8" : (item == .newAPI ? "#A855F7" : "#F59E0B")
                                    if item == .remail {
                                        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            baseURL = item.defaultBaseURL
                                        }
                                        if exchangeRateText == ValueFormatter.rate(store.defaultExchangeRate) {
                                            exchangeRateText = "1"
                                        }
                                    } else if previous == .remail {
                                        if baseURL == RelayProviderType.remail.defaultBaseURL {
                                            baseURL = ""
                                        }
                                        if exchangeRateText == "1" {
                                            exchangeRateText = ValueFormatter.rate(store.defaultExchangeRate)
                                        }
                                    }
                                }
                                testStatusMessage = nil
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: item.iconName)
                                        .font(.callout)
                                        .foregroundStyle(selected ? item.badgeColor : .secondary)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(item.badgeColor)
                                    }
                                }
                                Text(item.displayName)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.shortSubtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .liquidGlassCard(
                            cornerRadius: 18,
                            tint: selected ? item.badgeColor.opacity(0.22) : nil,
                            interactive: true
                        )
                    }
                }
            }
        }
    }

    private var stationRoleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("利润核算角色")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("站点角色", selection: $role) {
                ForEach(StationRole.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: role) { _, newRole in
                if newRole == .primarySales && !isEditing {
                    usageScope = .siteWideAdmin
                    accentHex = "#EC4899"
                } else if newRole == .costChannel && !isEditing {
                    usageScope = .personalSelf
                }
            }

            if role == .primarySales {
                VStack(alignment: .leading, spacing: 8) {
                    Text("销售额统计口径")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("统计口径", selection: $usageScope) {
                        ForEach(UsageScope.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(usageScope == .siteWideAdmin
                         ? "全站总消耗：通过管理员接口（NewAPI /api/data/ 或 Sub2API /api/v1/admin/dashboard/trend）获取全站所有客户的每日消费总额作为今日销售额。"
                         : "当前账号消耗：仅统计当前登录账号的当日消耗作为销售额。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(hex: "#EC4899").opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("上游成本渠道：每日消耗额度将按下方汇率折算并计入「上游渠道总成本」。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22)
    }

    private var stationInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("站点信息")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("站点名称（自定义备注）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("例如：主力 Sub2API / 2元特价站", text: $name)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("服务器地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://api.example.com", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            // Accent color picker dots
            VStack(alignment: .leading, spacing: 8) {
                Text("主题标识色（用于图表与卡片区分）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(RelayStation.presetAccentHexes, id: \.self) { hex in
                        let active = accentHex.uppercased() == hex.uppercased()
                        Button {
                            withAnimation(.spring(response: 0.25)) {
                                accentHex = hex
                            }
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white, lineWidth: active ? 2.5 : 0)
                                )
                                .scaleEffect(active ? 1.15 : 1.0)
                                .shadow(color: active ? Color(hex: hex).opacity(0.6) : .clear, radius: 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22)
    }

    private var authCredentialsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("登录认证方式")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showSecretText.toggle()
                } label: {
                    Image(systemName: showSecretText ? "eye.slash.fill" : "eye.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Interactive WebView Login CTA for sites with Cloudflare Turnstile / 2FA / OAuth
            Button {
                showWebLoginSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "safari.fill")
                        .font(.title3)
                        .foregroundStyle(Color(hex: "#38BDF8"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("网页交互登录（支持 CF 人机验证 / 2FA / 第三方登录）")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Text("在内置浏览器中手动点击人机验证完成登录，自动提取凭据")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(hex: "#38BDF8").opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)

            if provider.supportsPasswordLogin {
                Picker("认证方式", selection: $authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal.fill")
                        .foregroundStyle(Color(hex: "#F59E0B"))
                    Text("ReMail 认证：API Key (rk-...) 或 控制台 Cookie")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .padding(10)
                .background(Color(hex: "#F59E0B").opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if authMethod == .password && provider.supportsPasswordLogin {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.accountPlaceholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(provider == .sub2api ? "name@example.com" : "username", text: $accountIdentifier)
                        .keyboardType(provider == .sub2api ? .emailAddress : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("密码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        if showSecretText {
                            TextField("输入登录密码", text: $password)
                        } else {
                            SecureField("输入登录密码", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text("密码仅加密存储在本地 iOS 钥匙串 (Keychain)，用于自动刷新失效会话。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.tokenPlaceholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        if showSecretText {
                            TextField("粘贴访问令牌", text: $accessToken)
                        } else {
                            SecureField("粘贴访问令牌", text: $accessToken)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if provider == .newAPI {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("User ID（NewAPI 必填，用于 New-Api-User 请求头）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("例如：128（个人设置页可查看）", text: $userID)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                Text(provider == .sub2api
                     ? "支持 Sub2API 网页端 JWT Token（完整每日/模型趋势）或 sk- API Key（基础余额统计）。"
                     : (provider == .newAPI
                        ? "推荐在 NewAPI「个人设置 -> 系统访问令牌」生成访问令牌，并填写对应的数字 User ID。"
                        : "支持两种凭据：① 官方开放 API Key（rk-...），不会过期，通过订单与钱包流水统计；② 网页端登录后复制的 Cookie（含 =），可直接调用 /v1/dashboard 一次拉取最长 365 天历史每日消耗与各项目统计。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22)
    }

    private var exchangeRateCard: some View {
        let previewSampleAmount: Double = provider.usesPointsUnit ? 100.0 : 10.0

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("汇率转换比例", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("1 \(provider.unitName) → \(store.displayCurrency.rawValue)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(provider.usesPointsUnit
                 ? "设置 ReMail 每 1 积分折合多少目标货币（例如 1 积分 = ¥1 则填 1；10 积分 = ¥1 则填 0.1），总览将统一折算汇总。"
                 : "不同中转站充值汇率不同（如 1.5元/刀、2元/刀、官价 7.2元/刀），在此独立配置即可让总览精准折算真实花费。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(provider.usesPointsUnit
                     ? "每 1 积分 = \(store.displayCurrency.symbol)"
                     : "每 $1 额度 = \(store.displayCurrency.symbol)")
                    .font(.headline.weight(.semibold))
                TextField(provider.usesPointsUnit ? "1" : "7.2", text: $exchangeRateText)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Quick exchange rate preset pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(provider.quickExchangeRatePresets, id: \.self) { preset in
                        Button("\(store.displayCurrency.symbol)\(ValueFormatter.rate(preset))") {
                            exchangeRateText = ValueFormatter.rate(preset)
                        }
                        .font(.caption.weight(.semibold))
                        .glassButtonStyle()
                    }
                }
            }

            // Live calculation preview
            HStack {
                Image(systemName: "equal.circle.fill")
                    .foregroundStyle(Color(hex: accentHex))
                Text("实时换算预览：\(provider.formatRawAmount(previewSampleAmount)) ≈ \(ValueFormatter.currency(previewSampleAmount * parsedRate, currency: store.displayCurrency))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: accentHex))
                    .monospacedDigit()
                Spacer()
            }
            .padding(10)
            .background(Color(hex: accentHex).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if provider == .newAPI {
                DisclosureGroup("高级：NewAPI 额度换算基数 (quota_per_unit)", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("默认 500000", text: $quotaPerUnitText)
                            .keyboardType(.numberPad)
                            .padding(10)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text("默认 500,000 内部额度 = $1 USD。点击「测试连接」时会自动从站点 /api/status 读取。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22)
    }

    private var connectionTestCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { await runConnectionTest() }
            } label: {
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.shield.fill")
                    }
                    Text(isTesting ? "正在连接并验证登录..." : "测试连接并验证登录")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .glassButtonStyle(prominent: true)
            .tint(Color(hex: accentHex))
            .disabled(!canSave || isTesting)

            if let msg = testStatusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: testSucceeded ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testSucceeded ? Color(hex: "#10B981") : .red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(testSucceeded ? Color(hex: "#10B981") : .red)
                    Spacer()
                }
                .padding(12)
                .background(
                    (testSucceeded ? Color(hex: "#10B981") : Color.red).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
        }
    }

    // MARK: - Actions

    private func loadInitialValues() {
        if let station = editingStation {
            name = station.name
            provider = station.provider
            role = station.role
            usageScope = station.usageScope
            baseURL = station.baseURL
            authMethod = station.authMethod
            accountIdentifier = station.accountIdentifier
            userID = station.userID
            exchangeRateText = ValueFormatter.rate(station.exchangeRate)
            quotaPerUnitText = String(Int(station.quotaPerUnit))
            accentHex = station.accentHex

            let savedCreds = KeychainStore.load(for: station.id)
            password = savedCreds.password ?? ""
            accessToken = savedCreds.accessToken ?? ""
            verifiedCredentials = savedCreds
        } else {
            role = defaultRole
            usageScope = defaultRole == .primarySales ? .siteWideAdmin : .personalSelf
            exchangeRateText = ValueFormatter.rate(store.defaultExchangeRate)
            let nextColorIdx = store.stations.count % RelayStation.presetAccentHexes.count
            accentHex = defaultRole == .primarySales ? "#EC4899" : RelayStation.presetAccentHexes[nextColorIdx]
        }
    }

    private func buildDraftStationAndCreds() -> (RelayStation, StationSecretCredentials) {
        let normalizedURL = RelayStation.normalizeBaseURL(baseURL)
        let resolvedName: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if let host = URL(string: normalizedURL)?.host, !host.isEmpty {
                return host
            }
            return provider.displayName
        }()

        let draft = RelayStation(
            id: editingStation?.id ?? UUID(),
            name: resolvedName,
            provider: provider,
            baseURL: normalizedURL,
            authMethod: authMethod,
            role: provider == .remail ? .costChannel : role,
            usageScope: provider == .remail ? .personalSelf : usageScope,
            accountIdentifier: accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
            userID: userID.trimmingCharacters(in: .whitespacesAndNewlines),
            exchangeRate: parsedRate,
            quotaPerUnit: parsedQuotaPerUnit,
            accentHex: accentHex,
            isEnabled: editingStation?.isEnabled ?? true,
            createdAt: editingStation?.createdAt ?? Date()
        )

        var creds = verifiedCredentials ?? StationSecretCredentials()
        if authMethod == .password {
            creds.password = password
        } else {
            creds.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (draft, creds)
    }

    private func applyWebLoginCapture(_ captured: WebLoginCaptureResult) {
        authMethod = .accessToken
        var creds = verifiedCredentials ?? StationSecretCredentials()

        switch provider {
        case .sub2api:
            if let token = captured.accessToken, !token.isEmpty {
                accessToken = token
                creds.accessToken = token
            }
            if let refresh = captured.refreshToken, !refresh.isEmpty {
                creds.refreshToken = refresh
            }
            if let cookie = captured.cookieHeader, !cookie.isEmpty {
                creds.sessionCookie = cookie
            }
        case .newAPI:
            // Prefer captured session cookie (supports v0.x Cookie AND v1.0 `/api/user/auth/refresh` auto-renewal!)
            if let cookie = captured.cookieHeader, !cookie.isEmpty {
                accessToken = cookie
                creds.accessToken = cookie
                creds.sessionCookie = cookie
            } else if let token = captured.accessToken, !token.isEmpty {
                accessToken = token
                creds.accessToken = token
            }
        case .remail:
            if let cookie = captured.cookieHeader, !cookie.isEmpty {
                accessToken = cookie
                creds.accessToken = cookie
                creds.sessionCookie = cookie
            }
        }

        if let uid = captured.detectedUserID, !uid.isEmpty {
            userID = uid
        }
        if let label = captured.accountLabel, !label.isEmpty, accountIdentifier.isEmpty {
            accountIdentifier = label
        }
        verifiedCredentials = creds

        Task {
            await runConnectionTest()
        }
    }

    private func runConnectionTest() async {
        isTesting = true
        testStatusMessage = nil
        testSucceeded = false
        defer { isTesting = false }

        let (draft, creds) = buildDraftStationAndCreds()
        do {
            let result = try await RelayAPIService.testAndLogin(station: draft, credentials: creds)
            verifiedCredentials = result.updatedCredentials
            if let detectedUID = result.detectedUserID, !detectedUID.isEmpty {
                userID = detectedUID
            }
            if let detectedQPU = result.detectedQuotaPerUnit, detectedQPU > 0 {
                quotaPerUnitText = String(Int(detectedQPU))
            }
            var summary = "登录成功！账号：\(result.accountLabel)"
            if let bal = result.balanceUSD {
                summary += " · 余额 \(provider.formatRawAmount(bal)) (≈ \(ValueFormatter.currency(bal * parsedRate, currency: store.displayCurrency)))"
            }
            testSucceeded = true
            testStatusMessage = summary
        } catch {
            testSucceeded = false
            testStatusMessage = error.localizedDescription
        }
    }

    private func saveStation() {
        let (draft, creds) = buildDraftStationAndCreds()
        if isEditing {
            store.updateStation(draft, credentials: creds)
        } else {
            store.addStation(draft, credentials: creds)
        }
        dismiss()
    }
}
