import Foundation

/// 智慧教务（njw.cqie.edu.cn）接口封装，与 Android 端 CqieApi.kt 保持一致。
///
/// 实测结论：
///  - 课表类接口只校验 `Authorization: Bearer <JWT>`，不依赖 Cookie；
///  - token 有效期 7 天，可用 refresh_token 续期；
///  - 换 token 的 client_id / client_secret 由前端硬编码。
final class CqieApi {

    static let base = "https://njw.cqie.edu.cn"
    static let clientId = "personal-prod"
    private static let clientSecret = "app-a-1234"

    private static var basicAuth: String {
        "Basic " + Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
    }

    /// 用浏览器同款 UA，减少被学校 WAF/CDN 当成脚本拦掉的概率
    private static let userAgent =
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/124.0.0.0 Mobile Safari/537.36"

    enum ApiError: LocalizedError {
        case notLoggedIn
        case http(Int)
        /// 服务端用 HTTP 200 包了一个业务失败，形如
        /// `{"status":"error","msg":"操作失败","data":null}`；直接把 data 里的 null
        /// 塞给反序列化只会得到一句带类名的天书，所以单独拎出来带上服务端原话。
        case business(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "登录状态已失效，请重新登录"
            case .http(let code):
                if (500...599).contains(code) { return "学校服务器暂时异常（HTTP \(code)），请稍后重试" }
                return "请求失败（HTTP \(code)）"
            case .business(let message):
                return "学校系统返回「\(message)」"
            case .decoding:
                return "学校接口返回的数据看不懂，教务系统可能改版了"
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Referer": "\(Self.base)/workspace/home",
        ]
        session = URLSession(configuration: configuration)
    }

    // MARK: - 认证

    /// refresh_token 续期
    func refreshToken(_ refreshToken: String) async throws -> TokenResponse {
        let body = "grant_type=refresh_token&refresh_token=\(formEncode(refreshToken))"
        let data = try await send(
            url: "\(Self.base)/authserver/oauth/token",
            method: "POST",
            body: Data(body.utf8),
            contentType: "application/x-www-form-urlencoded; charset=utf-8",
            bearer: nil,
            basicAuth: Self.basicAuth
        )
        return try decodePayload(TokenResponse.self, from: data)
    }

    // MARK: - 业务

    /// 当前登录用户信息（姓名 / 院系 / 默认学期），顺带校验 token 是否有效
    func simpleUser(token: String) async throws -> SimpleUser? {
        let data = try await send(url: "\(Self.base)/authserver/simple-user", bearer: token)
        return try decodePayload(SimpleUser.self, from: data)
    }

    /// 学期列表（含起止日期）
    func sessions(token: String) async throws -> [SessionItem] {
        let data = try await send(url: "\(Self.base)/api/resourceapi/session/list", bearer: token)
        return try decodePayload(SessionListData.self, from: data).sessions
    }

    /// 某学期的课表
    func schedule(token: String, studentId: String, sessionId: String) async throws -> ScheduleData {
        let payload = "[\"\(studentId)\"]"
        let data = try await send(
            url: "\(Self.base)/api/timetable/class/timetable/stu/schedule-detail?sessionId=\(sessionId)",
            method: "POST",
            body: Data(payload.utf8),
            contentType: "application/json; charset=utf-8",
            bearer: token
        )
        return try decodePayload(ScheduleData.self, from: data)
    }

    /// 作息时间（12 小节 / 6 大节）
    func timePattern(token: String) async throws -> [PeriodItem] {
        let data = try await send(
            url: "\(Self.base)/api/resourceapi/timePattern/get-large-period",
            bearer: token
        )
        return try decodePayload([TimePatternData].self, from: data).first?.periods ?? []
    }

    /// 单个学期详情（含起止日期），查询他人课表时用来算周次
    func sessionDetail(token: String, sessionId: String) async throws -> SessionItem? {
        let data = try await send(
            url: "\(Self.base)/api/resourceapi/session/detail/\(sessionId)",
            bearer: token
        )
        return try decodePayload(SessionItem.self, from: data)
    }

    // MARK: - 课表查询

    /// 通用下拉选项接口：返回 [{id,name}]
    func options(token: String, path: String, extraQuery: String = "") async throws -> [OptionItem] {
        let suffix = extraQuery.isEmpty ? "" : "?\(extraQuery)"
        let data = try await send(url: "\(Self.base)\(path)\(suffix)", bearer: token)
        return try decodePayload([OptionItem].self, from: data)
    }

    /// 培养层次（本科 / 专科 / 专升本）
    func degrees(token: String) async throws -> [OptionItem] {
        let data = try await send(url: "\(Self.base)/api/shunt/degree/get-type", bearer: token)
        return try decodePayload(DegreeData.self, from: data).commonDegreeList ?? []
    }

    /// 实验中心。接口是分组结构，拍平成一层并带上所属中心名
    func laboratoryGroups(token: String) async throws -> [OptionItem] {
        let data = try await send(
            url: "\(Self.base)/api/timetable/optionFinder/laboratory/departmentGroup",
            bearer: token
        )
        let groups = try decodePayload([LaboratoryGroup].self, from: data)
        return groups.flatMap { group in
            (group.optionFinders ?? [])
                .filter { !($0.id ?? "").isEmpty }
                .map { OptionItem(id: $0.id, name: "\($0.name ?? "")（\(group.packName ?? "")）") }
        }
    }

    /// 按姓名 / 工号搜教师
    func searchInstructors(token: String, keyword: String, limit: Int = 30) async throws -> [QueryTarget] {
        let data = try await send(
            url: "\(Self.base)/api/timetable/instructor/filter" +
                "?nameOrCode=\(formEncode(keyword))&limitNum=\(limit)",
            bearer: token
        )
        return try decodePayload([InstructorHit].self, from: data).map {
            QueryTarget(id: $0.id ?? "", label: $0.name ?? "", subtitle: brackets([$0.code]))
        }
    }

    /// 按姓名 / 学号搜学生。
    /// limit 给得比网页端（10）宽，避免常见姓名重名时被截断看不全。
    func searchStudents(token: String, keyword: String, limit: Int = 30) async throws -> [QueryTarget] {
        let data = try await send(
            url: "\(Self.base)/api/timetable/student/filter" +
                "?nameOrCode=\(formEncode(keyword))&limitNum=\(limit)",
            bearer: token
        )
        return try decodePayload([StudentHit].self, from: data).map {
            QueryTarget(
                id: $0.studentId ?? "",
                label: $0.name ?? "",
                subtitle: brackets([$0.studentId, $0.grade, $0.deptName, $0.majorName, $0.adminClassName])
            )
        }
    }

    /// 按教室名搜教室
    func searchRooms(token: String, keyword: String, limit: Int = 15) async throws -> [QueryTarget] {
        let data = try await send(
            url: "\(Self.base)/api/resourceapi/room/roomName-filter" +
                "?roomName=\(formEncode(keyword))&limitNum=\(limit)",
            bearer: token
        )
        return try decodePayload([RoomHit].self, from: data).map {
            QueryTarget(
                id: $0.id ?? "",
                label: $0.name ?? "",
                subtitle: brackets([$0.buildingName, $0.campusName, $0.roomTypeName])
            )
        }
    }

    /// 按课程名 / 课程代码搜课程（选中之后还要再选教学班号）
    func searchCourses(
        token: String,
        keyword: String,
        sessionId: String,
        pageSize: Int = 20
    ) async throws -> [QueryTarget] {
        let data = try await send(
            url: "\(Self.base)/api/timetable/course/info-by-name-or-code" +
                "?nameOrCode=\(formEncode(keyword))&pageSize=\(pageSize)&sessionId=\(sessionId)",
            bearer: token
        )
        return try decodePayload([CourseHit].self, from: data).map { hit in
            let credit = hit.credit ?? ""
            let creditText = (credit.isEmpty || credit == "0.0") ? nil : "\(credit) 学分"
            return QueryTarget(
                id: hit.id ?? "",
                label: hit.name ?? "",
                subtitle: brackets([hit.number, creditText])
            )
        }
    }

    /// 课程下的教学班号
    func classNumbers(token: String, courseId: String, sessionId: String) async throws -> [QueryTarget] {
        let data = try await send(
            url: "\(Self.base)/api/timetable/course/search-class-by-courseId" +
                "?courseId=\(courseId)&&sessionId=\(sessionId)",
            bearer: token
        )
        return try decodePayload([ClassNumberHit].self, from: data)
            .filter { !($0.classNbr ?? "").isEmpty }
            .map { QueryTarget(id: $0.id ?? "", label: $0.classNbr ?? "") }
    }

    /// 按班级名搜行政班（学院为空时接口会拒绝，要带上 deptId）
    func searchAdminClasses(
        token: String,
        keyword: String,
        departmentId: String,
        limit: Int = 15
    ) async throws -> [QueryTarget] {
        var url = "\(Self.base)/api/timetable/course/adminClassName-filter-with-deptIds" +
            "?adminClassName=\(formEncode(keyword))&limitNum=\(limit)"
        if !departmentId.isEmpty { url += "&deptId=\(departmentId)" }
        let data = try await send(url: url, bearer: token)
        return try decodePayload([AdminClassHit].self, from: data).map {
            QueryTarget(
                id: $0.id ?? "",
                label: $0.className ?? "",
                subtitle: brackets([$0.deptName, $0.grade, $0.majorName])
            )
        }
    }

    /// 按名称搜实验室
    func searchLaboratories(
        token: String,
        keyword: String,
        laboratoryId: String,
        limit: Int = 15
    ) async throws -> [QueryTarget] {
        var url = "\(Self.base)/api/timetable/course/LaboratoryId-filter?"
        if !laboratoryId.isEmpty { url += "laboratoryId=\(laboratoryId)&" }
        url += "roomName=\(formEncode(keyword))&limitNum=\(limit)"
        let data = try await send(url: url, bearer: token)
        return try decodePayload([RoomHit].self, from: data).map {
            QueryTarget(
                id: $0.id ?? "",
                label: $0.name ?? "",
                subtitle: brackets([$0.buildingName, $0.campusName])
            )
        }
    }

    /// 查课表。返回结构与「我的课表」完全一致，可以复用同一套解析。
    /// 楼宇的 buildingId 走查询串而不是请求体（与网页端一致）。
    func queryTimetable(
        token: String,
        scope: QueryScope,
        ids: [String],
        sessionId: String,
        buildingId: String = "",
        degree: String = ""
    ) async throws -> ScheduleData {
        var query = "sessionId=\(sessionId)"
        if scope == .building, !buildingId.isEmpty { query += "&buildingId=\(buildingId)" }
        if scope == .adminClass, !degree.isEmpty { query += "&degree=\(formEncode(degree))" }

        let payload = "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let data = try await send(
            url: "\(Self.base)/api/timetable/class/timetable/\(scope.path)/table-detail?\(query)",
            method: "POST",
            body: Data(payload.utf8),
            contentType: "application/json; charset=utf-8",
            bearer: token
        )
        return try decodePayload(ScheduleData.self, from: data)
    }

    /// ["00348", "本科"] -> "[00348][本科]"，空值自动略过
    private func brackets(_ values: [String?]) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "[\($0)]" }
            .joined()
    }

    // MARK: - 传输

    private func send(
        url: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        bearer: String?,
        basicAuth: String? = nil
    ) async throws -> Data {
        guard let target = URL(string: url) else { throw ApiError.http(-1) }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let basicAuth { request.setValue(basicAuth, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ApiError.http(-1) }
        if http.statusCode == 401 { throw ApiError.notLoggedIn }
        guard (200..<300).contains(http.statusCode) else { throw ApiError.http(http.statusCode) }
        return data
    }

    // MARK: - 外壳剥离

    /// 本站接口外壳不统一，实测：
    ///  - /api/resourceapi/session/list、/api/timetable/.../schedule-detail → 直接返回数据本体
    ///  - /api/resourceapi/timePattern/get-large-period                    → {"status","data":[...]}
    ///  - /authserver/simple-user                                          → 直接返回对象
    /// 统一按「有 status 字段就取 data，否则取整体」处理。
    ///
    /// data 可能是 null（服务端失败时就是这样），必须先判掉再反序列化。
    private func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ApiError.decoding("响应不是合法 JSON")
        }

        if let object = json as? [String: Any], object.keys.contains("status") {
            guard let payload = object["data"], !(payload is NSNull) else {
                let message = (object["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ApiError.business(
                    (message?.isEmpty == false) ? message! : "学校接口没有返回内容"
                )
            }
            return try decode(type, from: payload)
        }

        if json is NSNull { throw ApiError.business("学校接口没有返回内容") }
        return try decode(type, from: json)
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: Any) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApiError.decoding(String(describing: error))
        }
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
