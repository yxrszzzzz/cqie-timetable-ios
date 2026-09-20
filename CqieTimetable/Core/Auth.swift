import Foundation
import Security

/// 极简 Keychain 读写。
/// 登录凭证（JWT）属于敏感数据，不能像普通配置那样丢进 UserDefaults。
enum Keychain {

    private static let service = "com.tcd.cqietable.ios"

    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ value: String?, for key: String) {
        guard let value else {
            remove(key)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        var lookup = query(key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func remove(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

struct AuthSession {
    var studentId: String
    var studentName: String
    var accessToken: String
    var refreshToken: String?
    var expireAt: Date
}

/// token 生命周期管理：7 天有效期，到期前自动用 refresh_token 续期。
final class AuthRepository {

    private enum Keys {
        static let studentId = "student_id"
        static let studentName = "student_name"
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let expireAt = "expire_at"
        static let account = "account"
    }

    /// 到期前 10 分钟就提前续期
    private static let refreshAhead: TimeInterval = 10 * 60
    private static let defaultExpire: TimeInterval = 604800

    private let api: CqieApi
    private var session: AuthSession?

    init(api: CqieApi) {
        self.api = api
    }

    var current: AuthSession? { session }

    @discardableResult
    func restore() -> AuthSession? {
        guard let studentId = Keychain.get(Keys.studentId),
              let token = Keychain.get(Keys.accessToken) else { return nil }
        let restored = AuthSession(
            studentId: studentId,
            studentName: Keychain.get(Keys.studentName) ?? "",
            accessToken: token,
            refreshToken: Keychain.get(Keys.refreshToken),
            expireAt: Date(timeIntervalSince1970: Double(Keychain.get(Keys.expireAt) ?? "") ?? 0)
        )
        session = restored
        return restored
    }

    func save(_ auth: AuthSession) {
        session = auth
        Keychain.set(auth.studentId, for: Keys.studentId)
        Keychain.set(auth.studentName, for: Keys.studentName)
        Keychain.set(auth.accessToken, for: Keys.accessToken)
        Keychain.set(auth.refreshToken, for: Keys.refreshToken)
        Keychain.set(String(auth.expireAt.timeIntervalSince1970), for: Keys.expireAt)
    }

    func clear() {
        session = nil
        [Keys.studentId, Keys.studentName, Keys.accessToken, Keys.refreshToken, Keys.expireAt]
            .forEach(Keychain.remove)
    }

    // MARK: - 账号记忆（密码不入库）

    var rememberedAccount: String? {
        get { UserDefaults.standard.string(forKey: Keys.account) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.account) }
    }

    /// 返回可用 token，必要时自动续期
    func validToken() async throws -> String {
        guard let current = session else { throw CqieApi.ApiError.notLoggedIn }

        if Date() < current.expireAt.addingTimeInterval(-Self.refreshAhead) {
            return current.accessToken
        }
        guard let refresh = current.refreshToken else { throw CqieApi.ApiError.notLoggedIn }

        let response: TokenResponse
        do {
            response = try await api.refreshToken(refresh)
        } catch {
            // 续期失败说明登录态真的没了，清掉让界面回到登录页
            clear()
            throw CqieApi.ApiError.notLoggedIn
        }
        guard let newToken = response.access_token else {
            clear()
            throw CqieApi.ApiError.notLoggedIn
        }

        let seconds = (response.expires_in ?? 0) > 0 ? TimeInterval(response.expires_in!) : Self.defaultExpire
        var updated = current
        updated.accessToken = newToken
        updated.refreshToken = response.refresh_token ?? refresh
        updated.expireAt = Date().addingTimeInterval(seconds)
        save(updated)
        return newToken
    }
}
