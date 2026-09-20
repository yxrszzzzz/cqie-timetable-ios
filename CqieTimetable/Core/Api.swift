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
