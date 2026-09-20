import Foundation

// 接口返回的模型。
//
// 与 Android 端 Dto.kt 一一对应。Swift 的 Codable 不像 Kotlin 那样支持「默认值」，
// 缺字段就会直接抛错，所以这里一律用可选类型存，再用计算属性给出默认值——
// 服务端少返回一个字段不该让整个解析失败。

/// POST /api/timetable/class/timetable/stu/schedule-detail?sessionId=xxx
struct ScheduleData: Decodable {
    var classTimetableVOList: [ClassTimetableItem]?
    var maxSection: Int?

    var items: [ClassTimetableItem] { classTimetableVOList ?? [] }
    var sectionCount: Int { maxSection ?? 12 }
}

/// 课表条目：服务端返回约 150 个字段，这里只保留用得上的
struct ClassTimetableItem: Decodable {
    var id: String?
    var teachingWeek: String?
    var weekDay: String?
    var period: String?
    var courseName: String?
    var courseCode: String?
    var roomName: String?
    var roomLabel: String?
    var campusName: String?
    var instructorName: String?
    var courseStudyNature: String?
    var reviewWay: String?
    var teachingWeekFormat: String?
    var periodFormat: String?
    var weekDayFormat: String?
    var wholeWeekOccupy: Bool?
    var selectedStuNum: String?

    /// 星期几，接口可能给 weekDay 也可能给 weekDayFormat
    var dayOfWeek: String? {
        (weekDayFormat ?? weekDay)?.trimmingCharacters(in: .whitespaces)
    }

    /// 节次文本
    var periodText: String? {
        (periodFormat ?? period)?.trimmingCharacters(in: .whitespaces)
    }

    /// 没排教室的按网课处理（学校自己的约定）
    var isOnline: Bool {
        (roomName ?? "").isEmpty && (roomLabel ?? "").isEmpty
    }
}

/// GET /api/resourceapi/session/list
struct SessionListData: Decodable {
    var sessionVOList: [SessionItem]?

    var sessions: [SessionItem] { sessionVOList ?? [] }
}

struct SessionItem: Decodable, Identifiable {
    var id: String
    var year: String?
    var term: String?
    var beginDate: String?
    var endDate: String?
    var active: String?

    /// "2026秋"
    var displayName: String { "\(year ?? "")\(term ?? "")" }
}

/// GET /api/resourceapi/timePattern/get-large-period
struct TimePatternData: Decodable {
    var sizePeriod: Int?
    var smallPeriod: Int?
    var periodList: [PeriodItem]?

    var periods: [PeriodItem] { periodList ?? [] }
}

struct PeriodItem: Decodable {
    var smallPeriod: Int?
    var startTime: String?
    var endTime: String?
}

/// GET /authserver/simple-user
///
/// 注意：服务端还会返回字段 `password`（BCrypt 哈希），属于服务端信息泄露，
/// 这里刻意不映射该字段，且不使用、不保存。
struct SimpleUser: Decodable {
    var name: String?
    var username: String?
    var code: String?
    var deptName: String?
    var type: String?
    var selectedSessionId: String?
}

/// POST /authserver/oauth/token
struct TokenResponse: Decodable {
    var access_token: String?
    var token_type: String?
    var refresh_token: String?
    var expires_in: Double?
    var scope: String?
}
