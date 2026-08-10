import Foundation

/// 第1层：本机对 TCP 载荷做特征丢弃/轻洗。
/// 调用方按「连接方向 + 端口」喂入应用层字节（SOCKS 拆流后或透明代理缓冲）。
public final class Layer1Filter {
    public struct Stats {
        public var drop4013: Int = 0
        public var dropNj0E: Int = 0
        public var neuterNj: Int = 0
    }

    private let cfg: AppConfig
    public private(set) var stats = Stats()

    public init(config: AppConfig) {
        self.cfg = config
    }

    public enum Direction {
        case uplink   // 客户端 → 服务器
        case downlink // 服务器 → 客户端
    }

    /// - Returns: 过滤后的数据；nil 表示整段丢弃不转发
    public func process(port: Int, direction: Direction, data: Data) -> Data? {
        var buf = data
        if buf.isEmpty { return buf }

        let watch = AceSignatures.isWatchPort(port)

        // 上行 65010：4013 整段丢（对齐 WPE / PC 局内）
        if direction == .uplink, port == 65010, cfg.blockUplink4013,
           AceSignatures.contains4013(buf) {
            stats.drop4013 += 1
            return nil
        }

        // 上行 NJ 举报 0E
        if direction == .uplink, cfg.blockNjReport0E, watch || port == 443 || port == 80,
           AceSignatures.containsNjReport0E(buf) {
            stats.dropNj0E += 1
            return nil
        }

        // 轻洗检测标记（上下行都可；有绿样本精洗仍交给第2层 Engine）
        if cfg.neuterNjMarkers,
           watch || AceSignatures.contains(buf, AceSignatures.nj23)
               || AceSignatures.contains(buf, AceSignatures.nj09) {
            if AceSignatures.neuterNjMarkers(&buf) {
                stats.neuterNj += 1
            }
        }

        return buf
    }
}
