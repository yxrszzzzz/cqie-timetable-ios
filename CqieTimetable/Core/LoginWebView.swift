import Foundation
import SwiftUI
import WebKit

/// WebView 登录过程中的进度事件
enum LoginEvent {
    /// 学校 CAS 登录页已就绪，正在自动填充并提交
    case casSubmitted
    /// 已通过统一身份认证，进入门户
    case portalReached
    /// 正在进入新教务系统
    case eduReached
    /// 成功取到教务系统 token
    case token(access: String, refresh: String?, expireAt: Date?)
    /// 需要用户手动操作（自动流程走不通时展示页面兜底）
    case manualNeeded(String)
    case failed(String)
}

/// 用隐藏的 WKWebView 跑完学校自己的登录流程：
/// CAS 自动填充提交 → 门户 → SSO 进新教务系统 → 从 localStorage 取 token。
///
/// 关键实现约束（Android 端踩过坑，这里原样保留）：
///  1. 跳转判断必须基于 **host**，不能用 contains——CAS 登录页的 service 参数里
///     就编码着门户域名，含子串会导致误判提前跳转。
///  2. 跳转判断必须放在 **didStartProvisionalNavigation**，不能放 didFinish——门户页
///     嵌了多个校内子系统的 iframe，只要有一个卡住，主文档 load 事件就永不触发，
///     didFinish 也就永远不来，流程会卡死到超时。
struct LoginWebView: UIViewRepresentable {

    let account: String
    let password: String
    let onEvent: (LoginEvent) -> Void

    private static let casHost = "a.cqie.edu.cn"
    private static let portalHost = "i.cqie.edu.cn"
    private static let eduHost = "njw.cqie.edu.cn"
    private static let casLoginPath = "/cas/login"
    private static let casLoginURL =
        "https://a.cqie.edu.cn/cas/login?service=https%3A%2F%2Fi.cqie.edu.cn%2Fportal_main%2FtoPortalPage"
    private static let eduWorkspaceURL = "https://njw.cqie.edu.cn/workspace"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 需要持久化 Cookie 与 localStorage，token 就存在教务系统的 localStorage 里
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: Self.casLoginURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 让协调器始终拿到最新的闭包，避免捕获到过期的状态
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {

        var parent: LoginWebView

        private var submitted = false
        private var enteredPortal = false
        private var eduNotified = false
        private var polling = false
        private var finished = false

        init(_ parent: LoginWebView) {
            self.parent = parent
        }

        // MARK: - 导航开始（相当于 Android 的 onPageStarted）

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let host = webView.url?.host else { return }

            if host == LoginWebView.portalHost, !enteredPortal {
                // 门户一到就立刻带着 CASTGC 去教务系统换票，
                // 不等门户页加载完（它页内的 iframe 可能永远加载不完）
                enteredPortal = true
                parent.onEvent(.portalReached)
                if let url = URL(string: LoginWebView.eduWorkspaceURL) {
                    webView.load(URLRequest(url: url))
                }
            } else if host == LoginWebView.eduHost, !eduNotified {
                eduNotified = true
                parent.onEvent(.eduReached)
            }
        }

        // MARK: - 导航完成（DOM 就绪，注入脚本只能等这里）

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, let host = url.host else { return }

            if host == LoginWebView.casHost,
               url.path.hasPrefix(LoginWebView.casLoginPath),
               !submitted {
                submitted = true
                parent.onEvent(.casSubmitted)
                injectCredentials(into: webView)
            } else if host == LoginWebView.eduHost {
                startPolling(webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onEvent(.failed("网络错误：\(error.localizedDescription)"))
        }

        // MARK: - 自动填充

        /// 账号密码交给页面自己的登录逻辑处理（DES 加密由页面 JS 完成，我们不管）
        private func injectCredentials(into webView: WKWebView) {
            let script = """
            (function(){
              var u = document.getElementById('username');
              var p = document.getElementById('password');
              if (!u || !p) return 'no-form';
              u.value = \(Self.jsString(parent.account));
              p.value = \(Self.jsString(parent.password));
              u.dispatchEvent(new Event('input', {bubbles:true}));
              p.dispatchEvent(new Event('input', {bubbles:true}));
              if (typeof _systemLogin === 'function') { _systemLogin(); return 'submitted'; }
              var form = document.getElementById('loginForm');
              if (form) { form.submit(); return 'form-submitted'; }
              return 'no-submit';
            })()
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                let value = (result as? String) ?? ""
                if value != "submitted" && value != "form-submitted" {
                    self.parent.onEvent(.manualNeeded("未能自动填充登录表单"))
                }
            }
        }

        // MARK: - 取 token

        private static let tokenScript = """
        (function(){
          try {
            var t = localStorage.getItem('cqu_edu_ACCESS_TOKEN');
            var r = localStorage.getItem('cqu_edu_REFRESH_TOKEN');
            var e = localStorage.getItem('cqu_edu_TOKEN_EXPIRE');
            return JSON.stringify({t:t, r:r, e:e});
          } catch (err) { return JSON.stringify({err: String(err)}); }
        })()
        """

        /// 轮询 localStorage，等 SPA 用授权码换到 token。
        /// 换 token 这一步是页面自己做的，我们只能等它写进去。
        private func startPolling(_ webView: WKWebView) {
            guard !polling, !finished else { return }
            polling = true
            Task { @MainActor in
                defer { self.polling = false }
                for _ in 0..<40 {
                    if self.finished { return }
                    if let token = await self.readToken(from: webView) {
                        self.finished = true
                        self.parent.onEvent(
                            .token(access: token.access, refresh: token.refresh, expireAt: token.expireAt)
                        )
                        return
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                if !self.finished {
                    self.parent.onEvent(.manualNeeded("未能自动获取登录凭证，请在上方页面完成登录"))
                }
            }
        }

        private func readToken(
            from webView: WKWebView
        ) async -> (access: String, refresh: String?, expireAt: Date?)? {
            guard let value = try? await webView.evaluateJavaScript(Self.tokenScript),
                  let raw = value as? String,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawToken = object["t"] as? String else { return nil }

            let token = Self.unquote(rawToken)
            // 必须是个 JWT，否则说明还没写进去
            guard !token.isEmpty, token.contains(".") else { return nil }

            let refresh = (object["r"] as? String).map(Self.unquote).flatMap { $0.isEmpty ? nil : $0 }
            let expire = (object["e"] as? String).map(Self.unquote).flatMap(Double.init)
            return (
                access: token,
                refresh: refresh,
                expireAt: expire.map { Date(timeIntervalSince1970: $0) }
            )
        }

        // MARK: - 小工具

        /// 把字符串安全地嵌进 JS 字面量
        private static func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let text = String(data: data, encoding: .utf8) else { return "\"\"" }
            // ["xxx"] 去掉首尾的方括号就是那个字符串字面量
            return String(text.dropFirst().dropLast())
        }

        /// localStorage 里存的可能是带引号的字符串
        private static func unquote(_ value: String) -> String {
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
            return String(value.dropFirst().dropLast())
        }
    }
}
