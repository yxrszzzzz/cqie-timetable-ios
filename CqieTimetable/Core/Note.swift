import Foundation
import SwiftUI
import UIKit

/// 课表备注：贴在某一天某一列上、跨若干连续节次的一张便签，只在选定的周次里露出来。
///
/// 和课程刻意分开存：课程是学校发下来的，每次刷新都可能变；备注是自己写的，
/// 不该被课表刷新冲掉——所以它既不进课表缓存，也不参与课表的内容指纹。
struct TimetableNote: Codable, Identifiable, Equatable {

    let id: String
    var text: String
    /// 1..7
    var weekDay: Int
    /// 起止节次，闭区间，从 1 数起
    var sectionStart: Int
    var sectionEnd: Int
    /// 生效的周次，由小到大
    var weeks: [Int]
    /// 便签底色，ARGB。nil = 默认的琥珀色，这样以前存的便签不用迁移
    var fillColor: Int?
    /// 正文颜色，ARGB。nil = 跟随主题（浅色模式深字、深色模式浅字）
    var textColor: Int?

    private static let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// 这张便签在第 week 周要不要出现
    func visibleIn(week: Int) -> Bool { weeks.contains(week) }

    /// 第 week 周、第 section 节要不要显示这张便签
    func visibleAt(week: Int, section: Int) -> Bool {
        visibleIn(week: week) && (sectionStart...sectionEnd).contains(section)
    }

    var sectionsText: String {
        sectionStart == sectionEnd ? "\(sectionStart)" : "\(sectionStart)-\(sectionEnd)"
    }

    var weekDayText: String {
        (1...7).contains(weekDay) ? Self.dayNames[weekDay - 1] : ""
    }
}

extension Array where Element == TimetableNote {

    /// 某一格上的备注。
    ///
    /// 便签是允许重叠的，但一格只画得下一张，所以取列表里的第一张。列表按
    /// （星期、起始节次）排好序，因此重叠时恒定取靠前的那张，不会今天画这张明天画那张。
    func noteAt(week: Int, weekDay: Int, section: Int) -> TimetableNote? {
        first { $0.weekDay == weekDay && $0.visibleAt(week: week, section: section) }
    }
}

/// 课表备注的本地存储。
///
/// 单独一个文件：备注是用户自己写的东西，和课表缓存没有关系——刷新课表、切换学期，
/// 甚至清掉课表缓存，都不该把它一起带走。
enum NoteStore {

    private static let fileName = "timetable_notes.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static func load() -> [TimetableNote] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // 文件坏了或者格式对不上就当没有，不值得为一张便签把界面拦下来
        return (try? JSONDecoder().decode([TimetableNote].self, from: data)) ?? []
    }

    static func save(_ notes: [TimetableNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 便签长相上几个两端共用的常量
enum NoteStyle {

    /// 默认底色，琥珀
    static let defaultFill = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)

    /// 底色透明度。半透明是便签和实色课程块区分开的标志，也不挡住底图
    static let fillAlpha: Double = 0.50
}

extension Color {

    /// 从 0xAARRGGBB 建色，读便签里存的颜色用
    init(argb: Int) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }

    /// 存进便签前压成 0xAARRGGBB
    var argb: Int {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return 0xFF000000
        }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return (channel(alpha) << 24) | (channel(red) << 16) | (channel(green) << 8) | channel(blue)
    }
}
