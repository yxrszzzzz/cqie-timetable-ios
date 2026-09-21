import PhotosUI
import SwiftUI
import UIKit

/// 课表底图设置。
///
/// 选图用 `PhotosPicker`：它由系统托管，只把用户当次选中的那一张交给 App，
/// 所以不需要申请相册权限，也看不到相册里的其他内容。
struct BackgroundSheet: View {

    @ObservedObject var model: AppViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var picked: PhotosPickerItem?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label(
                            model.background == nil ? "选择图片" : "换一张",
                            systemImage: "photo"
                        )
                    }
                    if model.background != nil {
                        Button(role: .destructive) {
                            model.clearBackground()
                        } label: {
                            Label("恢复默认背景", systemImage: "arrow.uturn.backward")
                        }
                    }
                } footer: {
                    Text("选一张图当课表的底。上面会盖一层淡色蒙版，课程块的底色完全不受影响，底图再花也不会把课压得看不清。")
                }

                if failed {
                    Section {
                        Label("这张图读不出来，换一张试试", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("课表底图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: picked) { item in
            guard let item else { return }
            Task { await apply(item) }
        }
    }

    private func apply(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            failed = true
            return
        }
        failed = !model.setBackground(image)
    }
}
