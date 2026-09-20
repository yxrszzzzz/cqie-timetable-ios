import Foundation

/// 课表查询（查看他人课表 / 教室课表 / 楼宇课表）。
///
/// 字段显隐严格对齐网页端：不同「查询范围」出现的筛选项不同。
@MainActor
final class CourseQueryModel: ObservableObject {

    /// 各下拉数据源（路径取自网页端实测）
    private enum Paths {
        static let session = "/api/timetable/optionFinder/session-release-schedule"
        static let campus = "/api/timetable/optionFinder/campusNameFinder"
        static let buildingByCampus = "/api/timetable/optionFinder/campus-building"
        static let department = "/api/resourceapi/optionFinder/departmentFinder"
        static let grade = "/api/timetable/optionFinder/gradeFinder"
        static let major = "/api/timetable/optionFinder/majorFinder"
    }

    @Published var scope: QueryScope = .student
    @Published var keyword = ""
    @Published var targets: [QueryTarget] = []
    @Published var selected: [QueryTarget] = []
    @Published var searching = false

    @Published var sessions: [OptionItem] = []
    @Published var sessionId = ""

    @Published var campuses: [OptionItem] = []
    @Published var campusId = ""
    @Published var buildings: [OptionItem] = []
    @Published var buildingId = ""

    @Published var laboratories: [OptionItem] = []
    @Published var laboratoryId = ""

    @Published var departments: [OptionItem] = []
    @Published var departmentId = ""
    @Published var degrees: [OptionItem] = []
    @Published var degree = ""
    @Published var grades: [OptionItem] = []
    @Published var grade = ""
    @Published var majors: [OptionItem] = []
    @Published var majorId = ""

    /// 课程范围：先选课程，再选教学班号
    @Published var selectedCourse: QueryTarget?
    @Published var classNumbers: [QueryTarget] = []
    @Published var classNumberId = ""

    @Published var result: TimetableData?
    @Published var loading = false
    @Published var message: String?

    private let api: CqieApi
    private let auth: AuthRepository
    private var started = false

    init(api: CqieApi, auth: AuthRepository) {
        self.api = api
        self.auth = auth
    }

    /// 楼宇范围直接用 buildingId 查，不用选具体对象。
    ///
    /// 任何范围都要求学期非空——查询接口拿到非法 sessionId 会直接回
    /// `{"status":"error","msg":"操作失败","data":null}`，白白让用户看一次报错。
    var canQuery: Bool {
        guard !sessionId.isEmpty else { return false }
        switch scope {
        case .building: return !buildingId.isEmpty
        case .course: return !classNumberId.isEmpty
        default: return !selected.isEmpty
        }
    }

    /// 结果页标题
    var resultTitle: String {
        switch scope {
        case .building: return "楼宇课表"
        case .course: return selectedCourse?.label ?? "课程课表"
        default:
            let names = selected.map(\.label).joined(separator: "、")
            return names.isEmpty ? scope.label : names
        }
    }

    // MARK: - 进入页面

    func start() {
        guard !started else { return }
        started = true
        loadSessions()
        loadScopeOptions(scope)
    }

    /// 学期是查询的前提：没有学期，服务端对任何查询都只回「操作失败」。
    /// 所以加载失败必须能重来，而不是让用户带着空学期一路点下去。
    func loadSessions() {
        Task {
            do {
                let token = try await auth.validToken()
                let list = try await api.options(token: token, path: Paths.session)
                sessions = list.filter { !$0.identity.isEmpty }
                if sessionId.isEmpty { sessionId = sessions.first?.identity ?? "" }
                message = nil
            } catch {
                message = "学期列表加载失败：\(describe(error))"
            }
        }
    }

    // MARK: - 表单

    func setScope(_ value: QueryScope) {
        guard value != scope else { return }
        scope = value
        keyword = ""
        targets = []
        selected = []
        selectedCourse = nil
        classNumbers = []
        classNumberId = ""
        buildingId = ""
        message = nil
        // 会话内已经拿到的下拉数据保留，避免来回切换时重复请求
        loadScopeOptions(value)
    }

    private func loadScopeOptions(_ target: QueryScope) {
        Task {
            guard let token = try? await auth.validToken() else { return }
            do {
                switch target {
                case .building, .classroom:
                    if campuses.isEmpty {
                        let list = try await api.options(token: token, path: Paths.campus)
                        campuses = list.filter { !$0.identity.isEmpty }
                    }
                case .laboratory:
                    if laboratories.isEmpty {
                        laboratories = try await api.laboratoryGroups(token: token)
                    }
                case .adminClass:
                    if departments.isEmpty {
                        let list = try await api.options(token: token, path: Paths.department)
                        departments = list.filter { !$0.identity.isEmpty }
                    }
                    if grades.isEmpty {
                        let list = try await api.options(token: token, path: Paths.grade)
                        grades = list.filter { !$0.identity.isEmpty }
                    }
                    if degrees.isEmpty {
                        degrees = try await api.degrees(token: token)
                    }
                default:
                    break
                }
            } catch {
                message = "\(target.label)的筛选项加载失败：\(describe(error))"
            }
        }
    }

    func setSession(_ id: String) {
        sessionId = id
        result = nil
    }

    func setCampus(_ id: String) {
        campusId = id
        buildingId = ""
        buildings = []
        selected = []
        guard !id.isEmpty else { return }
        Task {
            guard let token = try? await auth.validToken() else { return }
            let list = (try? await api.options(
                token: token,
                path: Paths.buildingByCampus,
                extraQuery: "campusId=\(id)"
            )) ?? []
            buildings = list.filter { !$0.identity.isEmpty }
        }
    }

    func setBuilding(_ id: String) { buildingId = id }

    func setLaboratory(_ id: String) {
        laboratoryId = id
        selected = []
    }

    func setDepartment(_ id: String) {
        departmentId = id
        majorId = ""
        majors = []
        selected = []
        guard !id.isEmpty else { return }
        Task {
            guard let token = try? await auth.validToken() else { return }
            let list = (try? await api.options(
                token: token,
                path: Paths.major,
                extraQuery: "deptId=\(id)"
            )) ?? []
            majors = list.filter { !$0.identity.isEmpty }
        }
    }

    func setDegree(_ value: String) { degree = value }
    func setGrade(_ value: String) { grade = value }
    func setMajor(_ value: String) { majorId = value }

    // MARK: - 搜索与选择

    func search() {
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            targets = []
            message = "请输入查询关键字"
            return
        }
        searching = true
        message = nil
        targets = []

        Task {
            defer { searching = false }
            guard let token = try? await auth.validToken() else {
                message = "登录状态已失效，请重新登录"
                return
            }
            do {
                let found: [QueryTarget]
                switch scope {
                case .teacher:
                    found = try await api.searchInstructors(token: token, keyword: keyword)
                case .student:
                    found = try await api.searchStudents(token: token, keyword: keyword)
                case .classroom:
                    found = try await api.searchRooms(token: token, keyword: keyword)
                case .laboratory:
                    found = try await api.searchLaboratories(
                        token: token, keyword: keyword, laboratoryId: laboratoryId
                    )
                case .adminClass:
                    found = try await api.searchAdminClasses(
                        token: token, keyword: keyword, departmentId: departmentId
                    )
                case .course:
                    found = try await api.searchCourses(
                        token: token, keyword: keyword, sessionId: sessionId
                    )
                case .building:
                    found = []
                }
                // id 为空的条目就算选中也查不出东西，干脆不给选
                targets = found.filter { !$0.id.isEmpty }
                if targets.isEmpty { message = "没有找到匹配结果" }
            } catch {
                message = describe(error)
            }
        }
    }

    func isSelected(_ target: QueryTarget) -> Bool {
        selected.contains { $0.id == target.id }
    }

    func toggle(_ target: QueryTarget) {
        if let index = selected.firstIndex(where: { $0.id == target.id }) {
            selected.remove(at: index)
        } else {
            selected.append(target)
        }
    }

    func remove(_ target: QueryTarget) {
        selected.removeAll { $0.id == target.id }
        if scope == .course {
            classNumberId = ""
            selectedCourse = nil
        }
    }

    /// 课程范围：选完课程再拉教学班号
    func pickCourse(_ course: QueryTarget) {
        selectedCourse = course
        classNumbers = []
        classNumberId = ""
        targets = []

        Task {
            guard let token = try? await auth.validToken() else { return }
            let list = (try? await api.classNumbers(
                token: token, courseId: course.id, sessionId: sessionId
            )) ?? []
            classNumbers = list
            if list.isEmpty { message = "该课程没有排课的教学班" }
        }
    }

    func setClassNumber(_ id: String) { classNumberId = id }

    func clearResult() { result = nil }

    func dismissMessage() { message = nil }

    // MARK: - 执行查询

    func runQuery() {
        guard !sessionId.isEmpty else {
            message = "没有可用的学期，请先点上面的「重试」加载学期列表"
            return
        }
        guard canQuery else {
            message = "请先选择查询对象"
            return
        }
        loading = true
        message = nil

        Task {
            defer { loading = false }
            guard let token = try? await auth.validToken() else {
                message = "登录状态已失效，请重新登录"
                return
            }
            do {
                let ids: [String]
                switch scope {
                case .building: ids = [buildingId]
                case .course: ids = [classNumberId]
                default: ids = selected.map(\.id)
                }

                // 多人时逐个人查：一次把几个 id 丢过去拿不到归属，合并后就分不清谁是谁的
                var parts: [(owner: String, schedule: ScheduleData)] = []
                switch scope {
                case .building:
                    let name = buildings.first { $0.identity == buildingId }?.title ?? "楼宇"
                    parts = [(
                        name,
                        try await api.queryTimetable(
                            token: token, scope: scope, ids: ids, sessionId: sessionId,
                            buildingId: buildingId, degree: degree
                        )
                    )]
                case .course:
                    let name = classNumbers.first { $0.id == classNumberId }?.label ?? "教学班"
                    parts = [(
                        name,
                        try await api.queryTimetable(
                            token: token, scope: scope, ids: ids, sessionId: sessionId,
                            buildingId: buildingId, degree: degree
                        )
                    )]
                default:
                    for target in selected {
                        let schedule = try await api.queryTimetable(
                            token: token, scope: scope, ids: [target.id], sessionId: sessionId,
                            buildingId: buildingId, degree: degree
                        )
                        parts.append((target.label, schedule))
                    }
                }

                // 学期详情拿不到也要继续：查询结果本身有课，只是周次算不出来。
                // 退回一个只有 id 的学期，总比整个查询失败强
                let detail = try? await api.sessionDetail(token: token, sessionId: sessionId)
                let session = detail ?? SessionItem(id: sessionId)
                let periods = (try? await api.timePattern(token: token)) ?? []

                result = TimetableBuilder.buildMerged(session: session, periods: periods, parts: parts)
                if result == nil { message = "没有查询结果" }
            } catch {
                message = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
