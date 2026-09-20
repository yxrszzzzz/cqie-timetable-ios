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

/// 学校站点在 WebView 里的登录数据（Cookie / localStorage / 缓存）。
///
/// 登录态不止 Keychain 里那一份：CAS 的会话靠 cookie（CASTGC），教务系统的 token
/// 存在 njw.cqie.edu.cn 的 localStorage 里。这两样都躺在 WKWebView 的持久化存储中，
/// 只要不删，下次打开登录页服务端会直接认出上一个会话——「换账号」就永远登回旧账号，
/// 而且轮询会立刻从 localStorage 读到旧 token，WebView 还没加载完就被移出层级。
enum SchoolWebSession {

    private static let domainSuffix = "cqie.edu.cn"

    /// 清空学校站点的 WebView 数据。
    /// 必须在创建登录 WebView **之前** await 完，否则 WebView 已经带着旧 cookie 发请求了。
    static func clear() async {
        let store = WKWebsiteDataStore.default()

        // 按站点清：localStorage / IndexedDB / 缓存都在这
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let targets = records.filter { $0.displayName.contains(domainSuffix) }
        if !targets.isEmpty {
            await store.removeData(ofTypes: types, for: targets)
        }

        // cookie 再单独走一遍：CAS 的会话票据（CASTGC）就在这里，
        // 只靠上面那次 removeData 不保证删干净，删不掉就等于没换账号
        let cookieStore = store.httpCookieStore
        for cookie in await cookieStore.allCookies()
        where cookie.domain.contains(domainSuffix) {
            await cookieStore.deleteCookie(cookie)
        }

        // URLSession 用的是另一份 cookie 存储，顺手一并清掉
        for cookie in (HTTPCookieStorage.shared.cookies ?? [])
        where cookie.domain.contains(domainSuffix) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
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

    /// 登录成功后 WebView 会被移出层级。它当时可能还在加载或执行 JS，
    /// 直接销毁会阻塞主线程（表现就是界面卡住、点一下才动），先停掉再交出去。
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.stopLoading()
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

        // MARK: - 站点推进

        /// 三个导航回调都走这一个入口，靠 enteredPortal / eduNotified 防重。
        ///
        /// 为什么不能只在 didStartProvisionalNavigation 里判：CAS 提交后是 302
        /// 重定向链，这个回调只在链路开头来一次，那一刻 webView.url 还是 CAS 登录页，
        /// 「已经到门户了」这一跳会被整条漏掉——WebView 就此停在门户首页：不跳教务
        /// 系统、不轮询、拿不到 token，整个流程要等用户手动点一下页面才继续。
        /// （Android 的 onPageStarted 每一跳都带着新 url，所以那边没这个坑。）
        private func advance(to host: String?, webView: WKWebView) {
            guard let host else { return }

            if host == LoginWebView.portalHost {
                guard !enteredPortal else { return }
                enteredPortal = true
                parent.onEvent(.portalReached)
                // 不等门户页加载完（它页内的 iframe 可能永远加载不完）；
                // 但也不能在导航决策回调里同步 load——那会把当前这跳掐掉，
                // 扔到下一轮 runloop 再发起
                Task { @MainActor in
                    guard let url = URL(string: LoginWebView.eduWorkspaceURL) else { return }
                    webView.load(URLRequest(url: url))
                }
            } else if host == LoginWebView.eduHost {
                if !eduNotified {
                    eduNotified = true
                    parent.onEvent(.eduReached)
                }
                // 不依赖 didFinish：教务系统是 SPA，只要落在它的域名上就把轮询挂起来，
                // 轮询自己会等 localStorage 里出现 token
                Task { @MainActor in self.startPolling(webView) }
            }
        }

        /// 重定向链走完后 URL 才最终确定，这里是最可靠的时机
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            advance(to: webView.url?.host, webView: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            advance(to: webView.url?.host, webView: webView)
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
            } else {
                advance(to: host, webView: webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // 主动停加载（例如登录完成后销毁 WebView）会报 -999，不是真的失败
            if (error as NSError).code == NSURLErrorCancelled { return }
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
                        // 凭证到手就不用再加载页面了，让 WebView 安静下来，后面移除它才不卡
                        webView.stopLoading()
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
