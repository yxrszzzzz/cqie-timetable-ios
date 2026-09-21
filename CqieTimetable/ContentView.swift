import SwiftUI
import UIKit

/// Stage 2：课表网格。登录拿 token → 拉课表 → 画周视图。
struct ContentView: View {

    @StateObject private var model = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    /// 分享、提醒、查询、导入共用一个 sheet 位——同一个视图上挂多个 sheet
    /// 在 SwiftUI 里并不总是都生效，统一成一个入口最稳
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusRow
                    if model.showLoginWebView {
                        loginWebView
                    }
                    if model.data != nil {
                        loadedSection
                    } else if model.loggedIn {
                        // 已登录但还没拿到课表：正在拉，或者拉失败了等重试
                        pendingSection
                    } else {
                        loginSection
                    }
                    versionFooter
                }
                .padding()
            }
            // 底图铺在整页之上，而不是塞进网格里——网格高度 = 节次数 × 行高，
            // 不同周需要显示的节次数不一样，塞进去的话切周次时背景会跟着伸缩
            .background {
                if let background = model.background {
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .overlay(
                            Color(.systemBackground).opacity(1 - model.backgroundOpacity)
                        )
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("重工课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // 导入的课表没有登录态，但提醒、导出这些照样该能用
                    if model.loggedIn || model.data != nil {
                        Menu {
                            Button("上课提醒", systemImage: "bell") { activeSheet = .reminder }
                            Button("课表底图", systemImage: "photo") { activeSheet = .background }
                            Button("导入课表", systemImage: "square.and.arrow.down") {
                                activeSheet = .importTimetable
                            }
                            if model.loggedIn {
                                Button("课表查询", systemImage: "magnifyingglass") { activeSheet = .query }
                                Divider()
                                Button("重新登录") { model.relogin() }
                                Button("退出登录", role: .destructive) { model.logout() }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let url):
                ShareSheet(url: url)
            case .reminder:
                ReminderSheet(model: model)
            case .background:
                BackgroundSheet(model: model)
            case .importTimetable:
                ImportView { model.applyImported($0) }
            case .query:
                NavigationStack {
                    CourseQueryView(api: model.api, auth: model.auth) { activeSheet = nil }
                }
            }
        }
        .fullScreenCover(item: $model.backgroundEdit) { session in
            if let data = model.data {
                BackgroundEditor(
                    source: session.image,
                    data: data,
                    week: model.week,
                    chromeOpacity: model.chromeOpacity,
                    notes: model.notes,
                    initialOpacity: model.backgroundOpacity,
                    onCancel: { model.cancelBackgroundEdit() },
                    onConfirm: { image, opacity in
                        _ = model.applyBackground(image, opacity: opacity)
                    }
                )
            } else {
                // 没有课表就没有示意层可叠，给个空页兜底（正常走不到）
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .onChange(of: scenePhase) { phase in
            // 提醒只排未来一周，回到前台时把窗口往前续一次
            guard phase == .active, let data = model.data else { return }
            Task { await ClassReminder.reschedule(data) }
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
            }
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 登录过程中把页面显示出来：既能看到进度，自动流程走不通时也能手动接管
    private var loginWebView: some View {
        LoginWebView(account: model.account, password: model.password) { event in
            model.onLoginEvent(event)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3))
        )
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("学号", text: $model.account)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)

            SecureField("密码", text: $model.password)
                .textFieldStyle(.roundedBorder)

            Button {
                model.startLogin()
            } label: {
                Text(model.busy ? "登录中…" : "登录并拉取课表")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.account.isEmpty || model.password.isEmpty)

            Text("账号密码只用于学校自己的登录页面，不保存在本机。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider().padding(.vertical, 2)

            Button {
                activeSheet = .importTimetable
            } label: {
                Label("导入官网导出的 Excel", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("不想登录也行：在教务系统里导出课表后导入，课表只存在本机。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var loadedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    exportXlsx()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            TimetableScreen(model: model)
        }
    }

    /// 导出当前这一周的课表，交给系统分享面板——面板里可以存到文件、发给别人、打印
    private func exportXlsx() {
        guard let data = model.data else { return }
        do {
            let url = try TimetableExport.makeXlsx(
                data,
                week: model.week,
                studentName: model.studentName
            )
            activeSheet = .share(url)
        } catch {
            model.report("导出失败：\(error.localizedDescription)")
        }
    }

    /// 已登录但手上一份课表都没有：要么正在拉，要么拉失败了
    private var pendingSection: some View {
        VStack(spacing: 10) {
            if model.busy {
                ProgressView()
                Text("正在拉取课表…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("还没取到课表")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重试") { model.reload() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var versionFooter: some View {
        Text("v\(AppInfo.version)(\(AppInfo.build))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
    }
}

/// 分享、提醒、底图、查询、导入共用一个 sheet 位
private enum ActiveSheet: Identifiable {
    case share(URL)
    case reminder
    case background
    case importTimetable
    case query

    var id: String {
        switch self {
        case .share(let url): return "share-\(url.absoluteString)"
        case .reminder: return "reminder"
        case .background: return "background"
        case .importTimetable: return "import"
        case .query: return "query"
        }
    }
}

/// 系统分享面板（自带「存储到文件」和「打印」）
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
