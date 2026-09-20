import Foundation
import UserNotifications

/// 某天的一节课，节次已经换算成「当天从 00:00 起的分钟数」。
///
/// 存分钟数而不是 Date：课表本身不含日期，日期是使用时才配上去的，分开表达算起来才不绕。
struct DayLesson {
    var name: String
    var teacher: String
    /// 已经处理过的地点：教室号 / 教室标签 / 网课
    var room: String
    var sections: [Int]
    var startMinutes: Int
    var endMinutes: Int

    var sectionsText: String {
        guard let first = sections.min(), let last = sections.max() else { return "" }
        return first == last ? "\(first)" : "\(first)-\(last)"
    }

    /// "第 3-4 节  08:30-10:10"
    var timeText: String {
        "第 \(sectionsText) 节  \(Self.clock(startMinutes))-\(Self.clock(endMinutes))"
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

// MARK: - 课表上补几个「按天」的口径

extension TimetableData {

    /// 指定日期是否在本学期内（假期里不该提示上课）
    func containsDate(_ date: Date) -> Bool {
        guard let begin = DateUtil.parseDay(session.beginDate),
              let end = DateUtil.parseDay(session.endDate) else { return false }
        let day = DateUtil.calendar.startOfDay(for: date)
        return day >= begin && day <= end
    }

    /// 指定日期落在第几周
    func weekOn(_ date: Date) -> Int {
        guard let begin = DateUtil.parseDay(session.beginDate) else { return 1 }
        let days = DateUtil.days(from: begin, to: date)
        if days < 0 { return 1 }
        return min(days / 7 + 1, max(totalWeeks, 1))
    }

    /// 第 week 周、星期 weekDay(1..7) 的全部课
    func coursesAt(week: Int, weekDay: Int) -> [Course] {
        courses.filter { $0.weekDay == weekDay && $0.weeks.contains(week) }
    }

    /// 当天的课，配好具体起止时刻。
    ///
    /// 查不到作息时刻的课会被跳过——提醒必须知道确切的上课时间，
    /// 宁可不提醒，也不能报一个错时间。
    func dayLessons(week: Int, weekDay: Int) -> [DayLesson] {
        var times: [Int: PeriodItem] = [:]
        for period in periodTimes {
            if let key = period.smallPeriod { times[key] = period }
        }

        return coursesAt(week: week, weekDay: weekDay)
            .sorted { ($0.sections.min() ?? 0) < ($1.sections.min() ?? 0) }
            .compactMap { course in
                let sections = course.sections.sorted()
                guard let first = sections.first, let last = sections.last,
                      let start = Self.minutes(times[first]?.startTime),
                      let end = Self.minutes(times[last]?.endTime) else { return nil }
                return DayLesson(
                    name: course.name,
                    teacher: course.teacher,
                    room: course.roomText,
                    sections: sections,
                    startMinutes: start,
                    endMinutes: end
                )
            }
    }

    /// "08:30" / "8:30:00" -> 从 00:00 起的分钟数，容错解析
    static func minutes(_ text: String?) -> Int? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1].prefix(while: { $0.isNumber })) else { return nil }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - 用户设置

/// 上课提醒的设置。不是敏感信息，用 UserDefaults 存就行
@MainActor
enum ReminderStore {

    /// 界面上可选的提前量
    static let leadOptions = [5, 10, 15, 20, 30]
    private static let defaultLead = 10
    private static let minLead = 5
    private static let maxLead = 30

    private static let enabledKey = "cqie_reminder_enabled"
    private static let leadKey = "cqie_reminder_lead"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var leadMinutes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: leadKey)
            return stored == 0 ? defaultLead : min(max(stored, minLead), maxLead)
        }
        set { UserDefaults.standard.set(min(max(newValue, minLead), maxLead), forKey: leadKey) }
    }
}

// MARK: - 排期

/// 上课提醒。
///
/// 采用「滚动窗口」：每次只排未来 [daysAhead] 天的提醒，App 每次启动、课表刷新、
/// 回到前台时整体重排一次，窗口就往前滚。
///
/// 不一次排满整个学期，是因为 iOS 对每个 App 的待发通知有数量上限——超出的部分
/// 会被系统悄悄丢掉，不如自己排队，把最近的先排上。
///
/// 触发器用 timeInterval 而不是日历匹配：上课时刻是按时区算出来的绝对时间，
/// 再交给日历按设备时区解释一遍，反而会因为设备时区不同而错位。
@MainActor
enum ClassReminder {

    private static let daysAhead = 7
    /// 系统上限是 64 条，留点余量
    private static let maxPending = 60

    /// 重排全部提醒。[data] 为 nil 时只做取消（例如退出登录）
    static func reschedule(_ data: TimetableData?) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        guard ReminderStore.enabled, let data else { return }
        guard await ensureAuthorized() else { return }

        let lead = ReminderStore.leadMinutes
        let calendar = DateUtil.calendar
        let midnight = calendar.startOfDay(for: Date())
        let now = Date()

        var planned: [(fire: Date, lesson: DayLesson)] = []
        for offset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: midnight),
                  data.containsDate(day) else { continue }
            let week = data.weekOn(day)
            for lesson in data.dayLessons(week: week, weekDay: isoWeekDay(day)) {
                guard let fire = calendar.date(
                    byAdding: .minute, value: lesson.startMinutes - lead, to: day
                ), fire > now else { continue }
                planned.append((fire, lesson))
            }
        }

        planned.sort { $0.fire < $1.fire }
        for (index, item) in planned.prefix(maxPending).enumerated() {
            await schedule(item.fire, item.lesson, lead: lead, index: index)
        }
    }

    /// 打开提醒。返回 false 表示用户没给通知权限，界面据此给提示
    static func enable(_ data: TimetableData?) async -> Bool {
        guard await ensureAuthorized() else { return false }
        ReminderStore.enabled = true
        await reschedule(data)
        return true
    }

    static func disable() async {
        ReminderStore.enabled = false
        await reschedule(nil)
    }

    /// 通知权限是否已经被拒（用于界面上提示「去系统设置里打开」）
    static func isDenied() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied
    }

    // MARK: - 内部

    private static func schedule(_ fire: Date, _ lesson: DayLesson, lead: Int, index: Int) async {
        let interval = fire.timeIntervalSinceNow
        guard interval > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(lead) 分钟后上课：\(lesson.name)"
        content.body = [
            lesson.timeText,
            lesson.room,
            lesson.teacher.isEmpty ? "教师待定" : lesson.teacher,
        ].joined(separator: " · ")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "class-\(index)-\(Int(fire.timeIntervalSince1970))",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// 已经拒绝过就不再弹窗，直接返回 false
    private static func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    /// 系统的 weekday 是 1=周日…7=周六，统一成 1=周一…7=周日
    private static func isoWeekDay(_ date: Date) -> Int {
        let value = DateUtil.calendar.component(.weekday, from: date)
        return value == 1 ? 7 : value - 1
    }
}
