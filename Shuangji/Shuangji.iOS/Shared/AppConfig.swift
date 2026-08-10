import Foundation

/// App ↔ Tunnel 共享配置（App Group）。
public struct AppConfig: Codable, Equatable {
    /// 账号中枢主机（开号/鉴权）
    public var accountHost: String
    public var accountPort: Int
    /// 可选：旧 Engine/SOCKS 节点（本机拦截默认不依赖）
    public var host: String
    public var socksPort: Int
    public var enginePort: Int
    public var userName: String
    public var password: String
    /// 工作模式：0待机 1读取 2修改(局内) 3大厅 — 本机拦截按此生效
    public var workMode: Int
    /// 第1层：丢弃 65010 上行 4013（仅修改模式）
    public var blockUplink4013: Bool
    /// 第1层：丢弃 65010 下行检测文件（仅修改模式）
    public var blockDownlinkDetect: Bool
    /// 第1层：丢弃 NJ 上行 0E
    public var blockNjReport0E: Bool
    /// 第1层：轻洗 NJ 23/09
    public var neuterNjMarkers: Bool
    /// 本机拦截总开关（不依赖 PC 网关）
    public var localInterceptEnabled: Bool
    /// 是否把流量送进上游 SOCKS（默认关=纯本机）
    public var useUpstreamSocks: Bool

    public static let appGroupId = "group.com.shuiyong.ports"
    public static let configKey = "shuiyong.config"

    public static let `default` = AppConfig(
        accountHost: "175.27.250.54",
        accountPort: 9100,
        host: "175.27.250.54",
        socksPort: 1080,
        enginePort: 8088,
        userName: "",
        password: "",
        workMode: 2,
        blockUplink4013: true,
        blockDownlinkDetect: true,
        blockNjReport0E: true,
        neuterNjMarkers: true,
        localInterceptEnabled: true,
        useUpstreamSocks: false
    )

    public var accountBaseURL: URL? {
        URL(string: "http://\(accountHost):\(accountPort)")
    }

    public var engineBaseURL: URL? {
        URL(string: "http://\(host):\(enginePort)")
    }

    /// 局内修改模式才硬拦 65010
    public var isModifyMode: Bool { workMode == 2 }

    public init(accountHost: String, accountPort: Int, host: String, socksPort: Int,
                enginePort: Int, userName: String, password: String, workMode: Int,
                blockUplink4013: Bool, blockDownlinkDetect: Bool, blockNjReport0E: Bool,
                neuterNjMarkers: Bool, localInterceptEnabled: Bool, useUpstreamSocks: Bool) {
        self.accountHost = accountHost
        self.accountPort = accountPort
        self.host = host
        self.socksPort = socksPort
        self.enginePort = enginePort
        self.userName = userName
        self.password = password
        self.workMode = workMode
        self.blockUplink4013 = blockUplink4013
        self.blockDownlinkDetect = blockDownlinkDetect
        self.blockNjReport0E = blockNjReport0E
        self.neuterNjMarkers = neuterNjMarkers
        self.localInterceptEnabled = localInterceptEnabled
        self.useUpstreamSocks = useUpstreamSocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        accountHost = try c.decodeIfPresent(String.self, forKey: .accountHost) ?? d.accountHost
        accountPort = try c.decodeIfPresent(Int.self, forKey: .accountPort) ?? d.accountPort
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        socksPort = try c.decodeIfPresent(Int.self, forKey: .socksPort) ?? d.socksPort
        enginePort = try c.decodeIfPresent(Int.self, forKey: .enginePort) ?? d.enginePort
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
        workMode = try c.decodeIfPresent(Int.self, forKey: .workMode) ?? d.workMode
        blockUplink4013 = try c.decodeIfPresent(Bool.self, forKey: .blockUplink4013) ?? d.blockUplink4013
        blockDownlinkDetect = try c.decodeIfPresent(Bool.self, forKey: .blockDownlinkDetect) ?? d.blockDownlinkDetect
        blockNjReport0E = try c.decodeIfPresent(Bool.self, forKey: .blockNjReport0E) ?? d.blockNjReport0E
        neuterNjMarkers = try c.decodeIfPresent(Bool.self, forKey: .neuterNjMarkers) ?? d.neuterNjMarkers
        localInterceptEnabled = try c.decodeIfPresent(Bool.self, forKey: .localInterceptEnabled) ?? d.localInterceptEnabled
        useUpstreamSocks = try c.decodeIfPresent(Bool.self, forKey: .useUpstreamSocks) ?? d.useUpstreamSocks
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
