import Foundation

/// 课表导出。
///
/// 只负责生成文件，分享交给系统的分享面板——面板里自带「存储到文件」和「打印」，
/// 不用自己再做两套入口。
@MainActor
enum TimetableExport {

    private static let directoryName = "shared"

    static func makeXlsx(_ data: TimetableData, week: Int, studentName: String) throws -> URL {
        let bytes = XlsxWriter.timetable(data, week: week, studentName: studentName)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 学期名来自服务端，别让它把路径撑破
        let term = data.session.displayName.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("课表_\(term)_第\(week)周.xlsx")
        try bytes.write(to: url, options: .atomic)
        return url
    }
}
