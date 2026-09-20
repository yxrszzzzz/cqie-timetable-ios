import Foundation

// 课表查询（他人 / 教室 / 楼宇等）相关模型。
// 与 Android 端 data/query/QueryModels.kt 一一对应，接口来自智慧教务
// 「课表查询」页（/timetable/AllCourseSchedule）。

/// 查询范围。[path] 用于拼 table-detail 的路径。
enum QueryScope: String, CaseIterable, Identifiable {
    case teacher
    case building
    case classroom
    case laboratory
    case course
    case adminClass
    case student

    var id: String { rawValue }

    var label: String {
        switch self {
        case .teacher: return "教师"
        case .building: return "楼宇"
        case .classroom: return "教室"
        case .laboratory: return "实验室"
        case .course: return "课程"
        case .adminClass: return "行政班"
        case .student: return "学生"
        }
    }

    var path: String {
        switch self {
        case .teacher: return "instructor"
        case .building: return "building"
        case .classroom, .laboratory: return "room"
        case .course: return "course"
        case .adminClass: return "adminClass"
        case .student: return "student"
        }
    }

    var searchHint: String {
        switch self {
        case .teacher: return "教师姓名/工号"
        case .student: return "学生姓名/学号"
        case .classroom: return "教室名称"
        case .laboratory: return "实验室名称"
        case .adminClass: return "行政班名称"
        case .course: return "课程名称/课程代码"
        case .building: return "楼宇"
        }
    }

    /// 楼宇 / 教室需要「校区 → 楼宇」两级级联
    var needsCampus: Bool { self == .building || self == .classroom }

    /// 楼宇是直接选，不给搜索框
    var needsSearch: Bool { self != .building }

    /// 课程范围要先选课程、再选教学班号
    var picksCourseFirst: Bool { self == .course }
}

/// 通用下拉项
struct OptionItem: Decodable, Hashable {
    var id: String?
    var name: String?

    var identity: String { id ?? "" }
    var title: String { name ?? "" }
}

/// 实验中心是分组结构
struct LaboratoryGroup: Decodable {
    var packName: String?
    var packId: String?
    var optionFinders: [OptionItem]?
}

/// 一个可被选中的查询对象
struct QueryTarget: Identifiable, Hashable {
    var id: String
    var label: String
    var subtitle: String = ""

    var display: String { subtitle.isEmpty ? label : "\(label) \(subtitle)" }
}

// MARK: - 接口原始返回

/// /api/shunt/degree/get-type
struct DegreeData: Decodable {
    var commonDegreeList: [OptionItem]?
}

/// /api/timetable/instructor/filter
struct InstructorHit: Decodable {
    var id: String?
    var name: String?
    var code: String?
}

/// /api/timetable/student/filter
struct StudentHit: Decodable {
    var name: String?
    var studentId: String?
    var deptName: String?
    var majorName: String?
    var grade: String?
    var adminClassName: String?
}

/// /api/resourceapi/room/roomName-filter 与 LaboratoryId-filter
struct RoomHit: Decodable {
    var id: String?
    var name: String?
    var buildingName: String?
    var campusName: String?
    var roomTypeName: String?
}

/// /api/timetable/course/info-by-name-or-code
struct CourseHit: Decodable {
    var id: String?
    var number: String?
    var name: String?
    var credit: String?
}

/// /api/timetable/course/search-class-by-courseId
struct ClassNumberHit: Decodable {
    var id: String?
    var classNbr: String?
}

/// /api/timetable/course/adminClassName-filter-with-deptIds
struct AdminClassHit: Decodable {
    var id: String?
    var className: String?
    var deptName: String?
    var grade: String?
    var majorName: String?
}
