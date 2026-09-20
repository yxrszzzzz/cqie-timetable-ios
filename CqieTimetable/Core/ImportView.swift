import SwiftUI
import UniformTypeIdentifiers

/// 导入官网导出的课表。
///
/// 三步：选文件 → 看解析结果 → 指定开学第一周的周一（导出文件里没有日期信息）。
struct ImportView: View {

    let onImported: (TimetableData) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showingPicker = false
    @State private var parsed: OfficialTimetableParser.Result?
    @State private var firstMonday = ImportView.defaultMonday
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingPicker = true
                    } label: {
                        Label(
                            parsed == nil ? "选择课表文件" : "重新选择文件",
                            systemImage: "doc.badge.plus"
                        )
                    }
                } footer: {
                    Text("在教务系统的「我的课表」里点导出，拿到的是「课表详情.xlsx」。")
                }

                if let parsed {
                    Section("解析结果") {
                        row("课程", "\(parsed.items.count) 条")
                        row("周次范围", "1 - \(max(parsed.maxWeek, 1)) 周")
                        if parsed.skipped > 0 {
                            row("跳过", "\(parsed.skipped) 处认不出的内容")
                        }
                    }

                    Section {
                        DatePicker(
                            "开学第一周的周一",
                            selection: $firstMonday,
                            displayedComponents: .date
                        )
                    } header: {
                        Text("学期起点")
                    } footer: {
                        Text("导出文件里没有日期，得靠这个日子才能算出「现在第几周」。选错了周次会整体错位。")
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("导入课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importNow() }
                        .disabled(parsed == nil)
                }
            }
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: allowedTypes,
                allowsMultipleSelection: false
            ) { outcome in
                switch outcome {
                case .success(let urls):
                    if let url = urls.first { load(url) }
                case .failure(let failure):
                    error = failure.localizedDescription
                }
            }
        }
    }

    private var allowedTypes: [UTType] {
        // xlsx 一般归在 spreadsheet 下，但个别系统按扩展名认不出来，两个都给
        [.spreadsheet, UTType(filenameExtension: "xlsx") ?? .data]
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    private func load(_ url: URL) {
        // 从「文件」App 选来的文件在沙盒外，必须先申请访问权限
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let sheet = try XlsxReader.read(data)
            let result = OfficialTimetableParser.parse(sheet)
            if result.isEmpty {
                parsed = nil
                error = "没能从这份文件里认出课表。确认导出的是「课表详情.xlsx」"
            } else {
                parsed = result
                error = nil
            }
        } catch {
            parsed = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func importNow() {
        guard let parsed else { return }
        onImported(TimetableImport.store(result: parsed, firstMonday: firstMonday))
        dismiss()
    }

    /// 默认取本周一——多数人是为了补看课表才来导入，不一定正好在开学那周
    private static var defaultMonday: Date {
        let calendar = DateUtil.calendar
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let iso = weekday == 1 ? 7 : weekday - 1
        return calendar.date(byAdding: .day, value: -(iso - 1), to: today) ?? today
    }
}
