import Foundation

/// App ↔ Tunnel 共享配置（App Group）。
public struct AppConfig: Codable, Equatable {
    public var host: String
    public var socksPort: Int
    public var enginePort: Int
    public var userName: String
    public var password: String
    /// 第1层：丢弃 65010 上行 4013
    public var blockUplink4013: Bool
    /// 第1层：丢弃 NJ 上行 0E 举报
    public var blockNjReport0E: Bool
    /// 第1层：轻洗 NJ 23/09 标记
    public var neuterNjMarkers: Bool
    /// 是否把流量送进第2层 SOCKS（关则仅本机过滤，一般保持开）
    public var useUpstreamSocks: Bool

    public static let appGroupId = "group.com.shuiyong.ports"
    public static let configKey = "shuiyong.config"

    public static let `default` = AppConfig(
        host: "192.168.1.8",
        socksPort: 1080,
        enginePort: 8088,
        userName: "demo",
        password: "123456",
        blockUplink4013: true,
        blockNjReport0E: true,
        neuterNjMarkers: true,
        useUpstreamSocks: true
    )

    public var engineBaseURL: URL? {
        URL(string: "http://\(host):\(enginePort)")
    }

    public static func load() -> AppConfig {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: configKey),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return .default }
        return cfg
    }

    public func save() {
        guard let defaults = UserDefaults(suiteName: Self.appGroupId),
              let data = try? JSONEncoder().encode(self)
        else { return }
        defaults.set(data, forKey: Self.configKey)
    }
}
