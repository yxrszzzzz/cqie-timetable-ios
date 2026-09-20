import Foundation

/// 解析 "1-7,10-13,16" 这种「区间 + 离散」混排的文本。
///
/// 学校的写法很随意：逗号有全角有半角，分隔符还有 `~`。逐段判断，
/// 不能先按逗号切完再统一处理——那样会把 `1-7` 当成一段离散值丢掉。
enum WeekUtil {

    static func parse(_ text: String?) -> Set<Int> {
        guard let text, !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "周", with: "")
            .replacingOccurrences(of: "节", with: "")

        var result = Set<Int>()
        for piece in normalized.split(separator: ",") where !piece.isEmpty {
            let segment = String(piece)
            if let separator = segment.firstIndex(where: { $0 == "-" || $0 == "~" || $0 == "—" }) {
                let lower = Int(segment[segment.startIndex..<separator]) ?? 0
                let upper = Int(segment[segment.index(after: separator)...]) ?? 0
                if lower > 0, upper >= lower, upper - lower < 200 {
                    result.formUnion(lower...upper)
                }
            } else if let single = Int(segment), single > 0 {
                result.insert(single)
            }
        }
        return result
    }

    /// 位图：`00001111` 表示第 5~8 位为真。
    ///
    /// 接口的 `teachingWeek` / `period` 就是这个格式，**绝不能当数字解析**——
    /// `00001111` 会变成 111 周，`0011` 会变成 11 节。
    static func parseBitmap(_ text: String?) -> Set<Int> {
        guard let text, !text.isEmpty else { return [] }
        var result = Set<Int>()
        for (index, character) in text.enumerated() where character == "1" {
            result.insert(index + 1)
        }
        return result
    }

    private static let chineseDigits: [Character: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7,
    ]

    /// `三` -> 3，`3` -> 3。
    /// 接口里 `weekDay` 是数字字符串，`weekDayFormat` 却是中文数字，两种都要吃得下。
    static func number(_ text: String?) -> Int? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let value = Int(raw) { return value }
        if let first = raw.first, let value = chineseDigits[first] { return value }
        return nil
    }

    /// 把集合压回 "1-7,10-13,16" 便于显示
    static func describe(_ values: Set<Int>) -> String {
        guard !values.isEmpty else { return "—" }
        let sorted = values.sorted()
        var parts: [String] = []
        var start = sorted[0]
        var previous = sorted[0]
        for value in sorted.dropFirst() {
            if value == previous + 1 {
                previous = value
                continue
            }
            parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            start = value
            previous = value
        }
        parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
        return parts.joined(separator: ",")
    }
}

enum DateUtil {

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 学校在成都，一律按东八区算，避免设备时区不同导致周次错位
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return formatter
    }()

    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    static func parseDay(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return dayFormatter.date(from: text)
    }

    static func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func adding(days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return formatter.string(from: date)
    }
}

/// 组班
struct ClassGroupInfo: Hashable {
    var name: String
    var students: Int?
}

/// 课表里的一门课（已按「同课同时段」合并过的领域模型）
struct Course: Identifiable, Hashable {

    let id: String
    var name: String
    var teacher: String
    var room: String
    var roomLabel: String
    var weekDay: Int?
    var sections: [Int]
    var weeks: Set<Int>
    var nature: String
    var reviewWay: String
    var classes: [ClassGroupInfo]
    var students: String
    var isWholeWeek: Bool

    /// 没排教室的按网课处理（学校自己的约定）
    var isOnline: Bool { room.isEmpty && roomLabel.isEmpty }

    var roomText: String {
        if !room.isEmpty { return room }
        return roomLabel.isEmpty ? "网课" : roomLabel
    }

    var weeksText: String { WeekUtil.describe(weeks) + " 周" }

    var sectionsText: String {
        sections.isEmpty ? "—" : WeekUtil.describe(Set(sections)) + " 节"
    }

    var classesText: String {
        classes.map { group in
            guard let students = group.students else { return group.name }
            return "\(group.name)(\(students))"
        }.joined(separator: ",")
    }
}

/// 视图层用的课表数据
struct TimetableData {

    var session: SessionItem
    var courses: [Course]
    var periodTimes: [PeriodItem]
    var maxSection: Int
    var totalWeeks: Int
    var currentWeek: Int

    var weekStart: Date? { DateUtil.parseDay(session.beginDate) }

    /// 只画实际用到的最深节次，下限 8 行——空着六行很难看
    var visibleSectionCount: Int {
        let deepest = courses.map { $0.sections.max() ?? 0 }.max() ?? 0
        return min(max(deepest, 8), max(maxSection, 1))
    }

    /// 第 N 周的 7 个日期（周一 ~ 周日）
    func dates(of week: Int) -> [Date] {
        guard let start = weekStart else { return [] }
        let monday = DateUtil.adding(days: (week - 1) * 7, to: start)
        return (0..<7).map { DateUtil.adding(days: $0, to: monday) }
    }

    func dateRangeText(of week: Int) -> String {
        let days = dates(of: week)
        guard let first = days.first, let last = days.last else { return "" }
        return "\(DateUtil.monthDay(first)) - \(DateUtil.monthDay(last))"
    }

    /// 某一格上的所有课。返回全部，不能只返回第一门——
    /// 撞课时只取一门会静默丢课。
    func coursesAt(week: Int, weekDay: Int, section: Int) -> [Course] {
        courses.filter { course in
            course.weekDay == weekDay
                && !course.isWholeWeek
                && course.weeks.contains(week)
                && course.sections.contains(section)
        }
    }

    /// 整周占用的课（实训那种，没有具体星期节次）
    func wholeWeekCourses(week: Int) -> [Course] {
        courses.filter { $0.isWholeWeek && $0.weeks.contains(week) }
    }

    /// 没排时间的网课
    func onlineCourses(week: Int) -> [Course] {
        courses.filter { !$0.isWholeWeek && $0.weekDay == nil && $0.weeks.contains(week) }
    }

    var weekDayText: String {
        switch currentWeek {
        case 1: return "第 1 周"
        default: return "第 \(currentWeek) 周"
        }
    }
}

enum TimetableBuilder {

    static func build(session: SessionItem, schedule: ScheduleData, periods: [PeriodItem]) -> TimetableData {
        let courses = merge(schedule.items.compactMap(makeCourse))
        let begin = DateUtil.parseDay(session.beginDate)
        let end = DateUtil.parseDay(session.endDate)
        let total = totalWeeks(begin: begin, end: end)
        return TimetableData(
            session: session,
            courses: courses,
            periodTimes: periods.filter { ($0.smallPeriod ?? 0) > 0 },
            maxSection: schedule.sectionCount,
            totalWeeks: total,
            currentWeek: currentWeek(begin: begin, total: total)
        )
    }

    private static func totalWeeks(begin: Date?, end: Date?) -> Int {
        guard let begin, let end else { return 20 }
        return max(DateUtil.days(from: begin, to: end) / 7 + 1, 1)
    }

    private static func currentWeek(begin: Date?, total: Int) -> Int {
        guard let begin else { return 1 }
        let days = DateUtil.days(from: begin, to: Date())
        if days < 0 { return 1 }
        return min(days / 7 + 1, total)
    }

    private static func makeCourse(_ item: ClassTimetableItem) -> Course? {
        guard let name = item.courseName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        let weeks = pick(text: item.teachingWeekFormat, bitmap: item.teachingWeek)
        let sections = pick(text: item.periodFormat, bitmap: item.period).sorted()
        let weekDay = item.dayOfWeek
        // 整周占用：没有星期节次，但服务端标了 wholeWeekOccupy
        let wholeWeek = item.wholeWeekOccupy == true

        let classes = (item.assignTeachingObject ?? []).compactMap { object -> ClassGroupInfo? in
            guard let className = object.className, !className.isEmpty else { return nil }
            return ClassGroupInfo(name: className, students: object.studentCount)
        }

        let course = Course(
            id: item.id ?? "\(name)-\(weekDay ?? 0)-\(sections.first ?? 0)",
            name: name,
            teacher: cleanTeacher(item.instructorName),
            room: (item.roomName ?? "").trimmingCharacters(in: .whitespaces),
            roomLabel: (item.roomLabel ?? "").trimmingCharacters(in: .whitespaces),
            weekDay: wholeWeek ? nil : weekDay,
            sections: wholeWeek ? [] : sections,
            weeks: weeks,
            nature: item.courseStudyNature ?? "",
            reviewWay: item.reviewWay ?? "",
            classes: classes,
            students: item.selectedStuNum ?? "",
            isWholeWeek: wholeWeek
        )
        // 没有星期节次的（整周实训 / 没排时间的网课）一律保留，界面单独列出来。
        // 这里不做丢弃判断——宁可多显示一条，也不能静默丢课。
        return course
    }

    /// 周次和节次都有两个来源：
    ///  - `teachingWeekFormat` / `periodFormat`：给人看的文本（"5-8"、"3-4"）
    ///  - `teachingWeek` / `period`：位图（"00001111"、"0011"）
    /// 优先用文本，没有才退回位图。位图**不能**当数字解析。
    private static func pick(text: String?, bitmap: String?) -> Set<Int> {
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return WeekUtil.parse(text)
        }
        return WeekUtil.parseBitmap(bitmap)
    }

    /// `吴臻-04941[主讲];` → `吴臻`
    private static func cleanTeacher(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return raw
            .split(whereSeparator: { $0 == ";" || $0 == "；" })
            .map { piece -> String in
                let text = piece.trimmingCharacters(in: .whitespaces)
                if let bracket = text.firstIndex(of: "[") {
                    return String(text[text.startIndex..<bracket])
                }
                return text
            }
            .filter { !$0.isEmpty }
            .joined(separator: "、")
    }

    /// 同一门课会按周次拆成多条返回，合并周次，界面上才是一块而不是好几块
    private static func merge(_ courses: [Course]) -> [Course] {
        var merged: [Course] = []
        var indexOf: [String: Int] = [:]

        for course in courses {
            let key = [
                course.name,
                course.teacher,
                course.room,
                course.roomLabel,
                course.weekDay.map(String.init) ?? "-",
                course.sections.map(String.init).joined(separator: ","),
                course.isWholeWeek ? "whole" : "normal",
            ].joined(separator: "|")

            if let existing = indexOf[key] {
                merged[existing].weeks.formUnion(course.weeks)
                if merged[existing].classes.isEmpty { merged[existing].classes = course.classes }
                if merged[existing].students.isEmpty { merged[existing].students = course.students }
            } else {
                indexOf[key] = merged.count
                merged.append(course)
            }
        }
        return merged.sorted { lhs, rhs in
            if lhs.isWholeWeek != rhs.isWholeWeek { return !lhs.isWholeWeek }
            if (lhs.weekDay ?? 0) != (rhs.weekDay ?? 0) { return (lhs.weekDay ?? 0) < (rhs.weekDay ?? 0) }
            return (lhs.sections.first ?? 0) < (rhs.sections.first ?? 0)
        }
    }
}
