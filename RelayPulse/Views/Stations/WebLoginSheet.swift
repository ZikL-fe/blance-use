import SwiftUI
import WebKit

struct WebLoginCaptureResult {
    var accessToken: String?
    var refreshToken: String?
    var cookieHeader: String?
    var detectedUserID: String?
    var accountLabel: String?
}

struct WebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    let baseURL: String
    let provider: RelayProviderType
    var onCaptured: (WebLoginCaptureResult) -> Void

    @State private var currentURLString: String = ""
    @State private var isLoadingPage: Bool = true
    @State private var isExtracting: Bool = false
    @State private var detectedHint: String? = nil
    @State private var errorHint: String? = nil
    @State private var controller = WebLoginController()

    private var initialLoginURL: URL? {
        let normalized = RelayStation.normalizeBaseURL(baseURL)
        return URL(string: "\(normalized)/login") ?? URL(string: normalized)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top compact address & navigation bar
                HStack(spacing: 10) {
                    Button {
                        controller.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(!controller.canGoBack)

                    Button {
                        controller.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }

                    HStack(spacing: 6) {
                        if isLoadingPage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(Color(hex: "#10B981"))
                        }
                        Text(currentURLString.isEmpty ? baseURL : currentURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().opacity(0.3)

                // Visible interactive WKWebView where the user completes CF Turnstile / 2FA / OAuth directly
                if let url = initialLoginURL {
                    InteractiveLoginWebView(
                        initialURL: url,
                        controller: controller,
                        onURLChanged: { newURL in
                            currentURLString = newURL
                            checkLoginHint(urlString: newURL)
                        },
                        onLoadingChanged: { loading in
                            isLoadingPage = loading
                        }
                    )
                } else {
                    ContentUnavailableView("站点地址无效", systemImage: "exclamationmark.triangle")
                }

                Divider().opacity(0.3)

                // Bottom Liquid Glass extraction bar
                VStack(spacing: 8) {
                    if let err = errorHint {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                    } else if let hint = detectedHint {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(hex: "#10B981"))
                            Text(hint)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color(hex: "#10B981"))
                            Spacer()
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .foregroundStyle(Color(hex: "#38BDF8"))
                            Text("请在上方点击完成 CF 人机验证并登录，进入控制台后点下方按钮导入")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    Button {
                        Task { await extractAndFinish() }
                    } label: {
                        HStack(spacing: 8) {
                            if isExtracting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "key.viewfinder")
                            }
                            Text(isExtracting ? "正在读取登录凭据..." : "已完成登录，提取凭据")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .glassButtonStyle(prominent: true)
                    .tint(detectedHint != nil ? Color(hex: "#10B981") : Color(hex: "#38BDF8"))
                    .disabled(isExtracting)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("\(provider.displayName) 网页登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func checkLoginHint(urlString: String) {
        let lower = urlString.lowercased()
        let onDashboard = lower.contains("/console")
            || lower.contains("/dashboard")
            || lower.contains("/panel")
            || lower.contains("/wallet")
            || lower.contains("/usage")
        if onDashboard && !lower.contains("/login") {
            detectedHint = "已进入控制台页面，点击下方按钮即可自动提取登录凭据"
            errorHint = nil
        }
    }

    @MainActor
    private func extractAndFinish() async {
        isExtracting = true
        errorHint = nil
        defer { isExtracting = false }

        let targetHost = URL(string: RelayStation.normalizeBaseURL(baseURL))?.host?.lowercased() ?? ""
        let capture = await controller.captureCredentials(forHost: targetHost, provider: provider)

        let hasUsefulCredential: Bool
        switch provider {
        case .sub2api:
            hasUsefulCredential = !(capture.accessToken ?? "").isEmpty || !(capture.cookieHeader ?? "").isEmpty
        case .newAPI:
            hasUsefulCredential = !(capture.cookieHeader ?? "").isEmpty || !(capture.accessToken ?? "").isEmpty
        case .remail:
            hasUsefulCredential = !(capture.cookieHeader ?? "").isEmpty
        }

        guard hasUsefulCredential else {
            errorHint = "尚未检测到有效登录凭据，请先完成人机验证并登录进入控制台后再试。"
            return
        }

        onCaptured(capture)
        dismiss()
    }
}

// MARK: - WKWebView Controller & Representable

@MainActor
final class WebLoginController {
    weak var webView: WKWebView?
    var canGoBack: Bool { webView?.canGoBack ?? false }

    func goBack() {
        webView?.goBack()
    }

    func reload() {
        webView?.reload()
    }

    func captureCredentials(forHost targetHost: String, provider: RelayProviderType) async -> WebLoginCaptureResult {
        guard let webView else { return WebLoginCaptureResult() }

        // 1. Read all cookies (including HttpOnly session / sid / cf_clearance) from WKHTTPCookieStore
        let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        let matchingCookies = allCookies.filter { cookie in
            guard !targetHost.isEmpty else { return true }
            let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return targetHost == cookieDomain || targetHost.hasSuffix(".\(cookieDomain)")
        }

        // Deduplicate by cookie name (keep latest/most specific)
        var cookieMap: [String: String] = [:]
        for c in matchingCookies {
            cookieMap[c.name] = c.value
        }
        let cookieHeader = cookieMap.isEmpty
            ? nil
            : cookieMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")

        // 2. Read localStorage tokens & user info (Sub2API stores `auth_token` / `refresh_token`, NewAPI stores `user`)
        let js = """
        (function() {
          try {
            var out = {};
            var keys = ['auth_token', 'access_token', 'refresh_token', 'token', 'auth_user', 'user'];
            for (var i = 0; i < keys.length; i++) {
              var v = window.localStorage.getItem(keys[i]);
              if (v) out[keys[i]] = v;
            }
            return JSON.stringify(out);
          } catch (e) {
            return '{}';
          }
        })();
        """

        var storageDict: [String: String] = [:]
        if let rawJSON = try? await webView.evaluateJavaScript(js) as? String,
           let data = rawJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            storageDict = parsed
        }

        let accessToken = nonEmpty(storageDict["auth_token"])
            ?? nonEmpty(storageDict["access_token"])
            ?? nonEmpty(storageDict["token"])
        let refreshToken = nonEmpty(storageDict["refresh_token"])

        var detectedUserID: String? = nil
        var accountLabel: String? = nil
        if let userRaw = nonEmpty(storageDict["auth_user"]) ?? nonEmpty(storageDict["user"]),
           let userData = userRaw.data(using: .utf8),
           let userJSON = try? JSONSerialization.jsonObject(with: userData) as? [String: Any] {
            if let idInt = userJSON["id"] as? Int {
                detectedUserID = String(idInt)
            } else if let idStr = userJSON["id"] as? String {
                detectedUserID = nonEmpty(idStr)
            }
            accountLabel = nonEmpty(userJSON["display_name"] as? String)
                ?? nonEmpty(userJSON["username"] as? String)
                ?? nonEmpty(userJSON["nickname"] as? String)
                ?? nonEmpty(userJSON["email"] as? String)
        }

        // Provider-specific sanity check: avoid treating pre-login CF cookie alone as a logged-in session
        switch provider {
        case .remail:
            // Require `sid` cookie (actual authenticated ReMail session, not just pre-login `sl-session`)
            let hasSid = cookieMap["sid"] != nil
            return WebLoginCaptureResult(
                accessToken: nil,
                refreshToken: nil,
                cookieHeader: hasSid ? cookieHeader : nil,
                detectedUserID: detectedUserID,
                accountLabel: accountLabel
            )
        case .sub2api:
            return WebLoginCaptureResult(
                accessToken: accessToken,
                refreshToken: refreshToken,
                cookieHeader: cookieHeader,
                detectedUserID: detectedUserID,
                accountLabel: accountLabel
            )
        case .newAPI:
            let hasSession = cookieMap["session"] != nil || cookieMap["new_api_has_session"] != nil || accessToken != nil
            return WebLoginCaptureResult(
                accessToken: accessToken,
                refreshToken: refreshToken,
                cookieHeader: hasSession ? cookieHeader : nil,
                detectedUserID: detectedUserID,
                accountLabel: accountLabel
            )
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct InteractiveLoginWebView: UIViewRepresentable {
    let initialURL: URL
    let controller: WebLoginController
    let onURLChanged: (String) -> Void
    let onLoadingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLChanged: onURLChanged, onLoadingChanged: onLoadingChanged)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral isolated data store per login session so multiple accounts on the same domain never collide
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Standard Safari Mobile UA so Cloudflare Turnstile renders cleanly
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1"

        controller.webView = webView
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onURLChanged: (String) -> Void
        let onLoadingChanged: (Bool) -> Void

        init(onURLChanged: @escaping (String) -> Void, onLoadingChanged: @escaping (Bool) -> Void) {
            self.onURLChanged = onURLChanged
            self.onLoadingChanged = onLoadingChanged
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChanged(true)
            if let url = webView.url?.absoluteString {
                onURLChanged(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChanged(false)
            if let url = webView.url?.absoluteString {
                onURLChanged(url)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
        }

        // Allow OAuth popups (e.g. GitHub / LinuxDO) to open cleanly inside the same WebView
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
