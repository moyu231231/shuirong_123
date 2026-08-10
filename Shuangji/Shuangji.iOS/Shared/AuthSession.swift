import Foundation

/// 登录态（本机持久化；进 App 必须先过账号中枢）。
public enum AuthSession {
    private static let suite = "group.com.shuiyong.ports"
    private static let tokenKey = "sy_auth_token"
    private static let userKey = "sy_auth_user"
    private static let atKey = "sy_auth_at"

    public static var isLoggedIn: Bool {
        guard let d = UserDefaults(suiteName: suite) else { return false }
        let t = d.string(forKey: tokenKey) ?? ""
        return !t.isEmpty
    }

    public static var userName: String {
        UserDefaults(suiteName: suite)?.string(forKey: userKey) ?? ""
    }

    public static var token: String {
        UserDefaults(suiteName: suite)?.string(forKey: tokenKey) ?? ""
    }

    public static func markLoggedIn(user: String, token: String) {
        guard let d = UserDefaults(suiteName: suite) else { return }
        d.set(token, forKey: tokenKey)
        d.set(user, forKey: userKey)
        d.set(Date().timeIntervalSince1970, forKey: atKey)
    }

    public static func logout() {
        guard let d = UserDefaults(suiteName: suite) else { return }
        d.removeObject(forKey: tokenKey)
        d.removeObject(forKey: userKey)
        d.removeObject(forKey: atKey)
    }
}
