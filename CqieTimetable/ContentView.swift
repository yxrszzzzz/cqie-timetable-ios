import SwiftUI

/// Stage 2：课表网格。登录拿 token → 拉课表 → 画周视图。
struct ContentView: View {

    @StateObject private var model = AppViewModel()

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
            .navigationTitle("重工课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.loggedIn {
                        Menu {
                            Button("重新登录") { model.relogin() }
                            Button("退出登录", role: .destructive) { model.logout() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
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
        }
    }

    private var loadedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimetableScreen(model: model)
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
