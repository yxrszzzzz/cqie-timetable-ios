import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {

    @Published var account: String = ""
    @Published var password: String = ""
    @Published var statusText: String = "填入学号和密码，登录后自动拉取课表"
    @Published var showLoginWebView = false
    @Published var busy = false
    @Published var loggedIn = false
    @Published var summary = ""
    /// 当前账号的姓名，导出课表时写进表格抬头
    @Published var studentName = ""
    /// 课表数据。为空表示还没拉到，界面就停在登录页。
    @Published var data: TimetableData?
    /// 当前查看的周次
    @Published var week: Int = 1

    /// 课表查询那边要复用同一份 api 与登录态，所以不设为 private
    let api: CqieApi
    let auth: AuthRepository

    init() {
        let api = CqieApi()
        self.api = api
        self.auth = AuthRepository(api: api)
        if let saved = auth.rememberedAccount, !saved.isEmpty {
            account = saved
        }
        // 上次登录过就直接续用，token 7 天内有效
        guard let session = auth.restore() else { return }
        loggedIn = true
        studentName = session.studentName

        // 先把本机缓存摆出来：冷启动不用干等网络，断网也看得到课表
        if let cached = TimetableStore.load() {
            data = cached
            week = cached.currentWeek
            let name = session.studentName.isEmpty ? session.studentId : session.studentName
            summary = "\(name) · \(cached.session.displayName) · \(cached.courses.count) 门课"
            statusText = "已显示本机缓存的课表，正在刷新…"
            // 先把提醒窗口按缓存续上，万一这次刷新失败也不至于断档
            Task { await ClassReminder.reschedule(cached) }
        } else {
            statusText = "已恢复登录（\(session.studentName)），正在拉取课表…"
        }

        busy = true
        Task { await loadTimetable(studentId: session.studentId) }
    }

    // MARK: - 登录

    func startLogin() {
        guard !account.isEmpty, !password.isEmpty else {
            statusText = "请先填学号和密码"
            return
        }
        auth.rememberedAccount = account
        busy = true
        statusText = "正在清理上次的登录状态…"
        // 必须先清干净学校站点的 cookie / localStorage 再开 WebView：
        // 否则 CAS 会话还在，服务端会直接认出上一个账号，换号等于没换
        Task {
            await SchoolWebSession.clear()
            statusText = "正在打开学校登录页…"
            showLoginWebView = true
        }
    }

    func onLoginEvent(_ event: LoginEvent) {
        switch event {
        case .casSubmitted:
            statusText = "正在提交账号密码…"
        case .portalReached:
            statusText = "已通过统一身份认证，正在进入新教务系统…"
        case .eduReached:
            statusText = "正在读取登录凭证…"
        case .token(let access, let refresh, let expireAt):
            statusText = "登录成功，正在拉取课表…"
            Task { await completeLogin(access: access, refresh: refresh, expireAt: expireAt) }
        case .manualNeeded(let message):
            busy = false
            statusText = message
        case .failed(let message):
            busy = false
            statusText = message
        }
    }

    private func completeLogin(access: String, refresh: String?, expireAt: Date?) async {
        do {
            let user = try await api.simpleUser(token: access)
            let studentId = user?.username ?? user?.code ?? account
            auth.save(
                AuthSession(
                    studentId: studentId,
                    studentName: user?.name ?? "",
                    accessToken: access,
                    refreshToken: refresh,
                    expireAt: expireAt ?? Date().addingTimeInterval(7 * 24 * 3600)
                )
            )
            showLoginWebView = false
            loggedIn = true
            await loadTimetable(studentId: studentId)
        } catch {
            busy = false
            statusText = describe(error)
        }
    }

    /// 回到登录页换账号。
    ///
    /// 刻意不清 Keychain 里的 token——万一新账号登录失败，重启 App 还能接着用原来的；
    /// 但学校站点的 cookie / localStorage 必须清掉，那才是「换账号」真正的开关。
    func relogin() {
        showLoginWebView = false
        data = nil
        loggedIn = false
        summary = ""
        statusText = "正在清理上次的登录状态…"
        Task {
            await SchoolWebSession.clear()
            statusText = "填入学号和密码，登录后自动拉取课表"
        }
    }

    func logout() {
        auth.clear()
        // 课表缓存也一并清掉：课程信息属于个人数据，不该在登出后还留在设备上
        TimetableStore.clear()
        loggedIn = false
        showLoginWebView = false
        data = nil
        summary = ""
        statusText = "正在清理登录状态…"
        Task {
            await SchoolWebSession.clear()
            // 登出之后不该再提醒上课
            await ClassReminder.reschedule(nil)
            statusText = "已退出登录"
        }
    }

    // MARK: - 拉课表

    private func loadTimetable(studentId: String) async {
        busy = true
        defer { busy = false }
        do {
            let token = try await auth.validToken()
            let user = try? await api.simpleUser(token: token)
            let sessions = try await api.sessions(token: token)
            let preferred = user?.selectedSessionId
            guard let session = sessions.first(where: { $0.id == preferred }) ?? sessions.first else {
                statusText = "没有可用的学期"
                return
            }

            let schedule = try await api.schedule(token: token, studentId: studentId, sessionId: session.id)
            let periods = (try? await api.timePattern(token: token)) ?? []

            let built = TimetableBuilder.build(session: session, schedule: schedule, periods: periods)
            self.data = built
            self.week = built.currentWeek

            // 拉到之后才写缓存：一次失败的响应不该盖掉上一次的好数据
            TimetableStore.save(session: session, schedule: schedule, periods: periods)
            TimetableStore.lastStudentName = user?.name

            let name = user?.name ?? auth.current?.studentName ?? ""
            studentName = name
            summary = "\(name) · \(session.displayName) · \(built.courses.count) 门课"
            statusText = "课表已加载"

            // 课程可能有调整，提醒窗口跟着重排一次
            await ClassReminder.reschedule(built)
        } catch {
            // 手上有缓存时别把已经显示出来的课表抹掉，只说明刷新没成功
            if data != nil {
                statusText = "刷新失败：\(describe(error))　下面显示的是本机缓存"
            } else {
                statusText = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// 手动重试。首次拉课表失败时界面上就只剩这个按钮可用
    func reload() {
        guard let current = auth.current else { return }
        Task { await loadTimetable(studentId: current.studentId) }
    }

    /// 界面自己发起的操作出错时，借状态栏说一声
    func report(_ message: String) {
        statusText = message
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }
}
