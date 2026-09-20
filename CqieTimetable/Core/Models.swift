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
    /// 组班信息，如 24财管5班(47)
    var assignTeachingObject: [TeachingObject]?

    /// 星期几（1~7）。
    ///
    /// 注意两个字段长得不一样：`weekDay` 是数字字符串（"3"），
    /// `weekDayFormat` 是中文数字（"三"）。优先用能直接转数字的那个。
    var dayOfWeek: Int? {
        if let raw = weekDay, let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
            return value
        }
        return WeekUtil.number(weekDayFormat)
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

/// 组班的一项。stuNums 实测是数字，但服务端字段类型不稳定，用 Double 兜住再取整。
struct TeachingObject: Decodable {
    var className: String?
    var stuNums: Double?

    var studentCount: Int? { stuNums.map { Int($0) } }
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
