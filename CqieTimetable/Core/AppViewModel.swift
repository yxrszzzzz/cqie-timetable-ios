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
    /// 课表数据。为空表示还没拉到，界面就停在登录页。
    @Published var data: TimetableData?
    /// 当前查看的周次
    @Published var week: Int = 1

    private let api = CqieApi()
    private lazy var auth = AuthRepository(api: api)

    init() {
        if let saved = auth.rememberedAccount, !saved.isEmpty {
            account = saved
        }
        // 上次登录过就直接续用，token 7 天内有效
        if let session = auth.restore() {
            loggedIn = true
            busy = true
            statusText = "已恢复登录（\(session.studentName)），正在刷新课表…"
            Task { await loadTimetable(studentId: session.studentId) }
        }
    }

    // MARK: - 登录

    func startLogin() {
        guard !account.isEmpty, !password.isEmpty else {
            statusText = "请先填学号和密码"
            return
        }
        auth.rememberedAccount = account
        showLoginWebView = true
        busy = true
        statusText = "正在打开学校登录页…"
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

    /// 回到登录页换账号。刻意不清 token——万一登录又失败，重启还能接着用原来的
    func relogin() {
        showLoginWebView = false
        data = nil
        loggedIn = false
        summary = ""
        statusText = "填入学号和密码，登录后自动拉取课表"
    }

    func logout() {
        auth.clear()
        loggedIn = false
        showLoginWebView = false
        data = nil
        summary = ""
        statusText = "已退出登录"
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

            let name = user?.name ?? auth.current?.studentName ?? ""
            summary = "\(name) · \(session.displayName) · \(built.courses.count) 门课"
            statusText = "课表已加载"
        } catch {
            statusText = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
