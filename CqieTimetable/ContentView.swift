import SwiftUI

/// Stage 1：先把数据链路跑通——登录拿到 token，再拉回真实课表。
/// 界面上先用文字列表印证数据对不对，课表网格放到下一步。
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
                    if model.loggedIn {
                        loadedSection
                    } else {
                        loginSection
                    }
                }
                .padding()
            }
            .navigationTitle("重工课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("v\(AppInfo.version)(\(AppInfo.build))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.preview.isEmpty {
                Text("这门课表里没有课程").font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.preview.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("重新登录") {
                    model.loggedIn = false
                    model.statusText = "填入学号和密码，登录后自动拉取课表"
                }
                .buttonStyle(.bordered)

                Button("退出登录", role: .destructive) {
                    model.logout()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
