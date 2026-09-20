import SwiftUI
import UIKit

/// 打样页：这一版只为验证「CI 编译 → 未签名 ipa → 爱思助手签名装机」这条链路是通的。
/// 链路确认没问题之后，再往上搬登录、课表、导入这些真正的功能。
struct ContentView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("重工课表")
                .font(.largeTitle.bold())

            Text("iOS 打样构建")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("如果你能在手机上看到这一页，说明构建、签名、安装这条链路已经跑通了。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Divider().padding(.horizontal, 40)

            VStack(spacing: 8) {
                row("版本", version)
                row("构建号", build)
                row("机型", UIDevice.current.model)
                row("系统", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            }
            .font(.footnote)
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

#Preview {
    ContentView()
}
