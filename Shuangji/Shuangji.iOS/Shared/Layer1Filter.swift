import Foundation

/// 本机第1层：不依赖 PC 网关，按工作模式拦 65010/NJ。
public final class Layer1Filter {
    public struct Stats {
        public var drop4013: Int = 0
        public var dropDetect: Int = 0
        public var dropNj0E: Int = 0
        public var neuterNj: Int = 0
    }

    private var cfg: AppConfig
    private let up65010 = Port65010UplinkFilter()
    private let down65010 = Port65010DownlinkFilter()
    public private(set) var stats = Stats()

    public init(config: AppConfig) {
        self.cfg = config
    }

    public func reload(_ config: AppConfig) {
        cfg = config
    }

    public enum Direction {
        case uplink
        case downlink
    }

    /// - Returns: 过滤后的数据；nil 表示整段丢弃
    public func process(port: Int, direction: Direction, data: Data) -> Data? {
        guard cfg.localInterceptEnabled else { return data }
        var buf = data
        if buf.isEmpty { return buf }

        let watch = AceSignatures.isWatchPort(port)
        let modify = cfg.isModifyMode

        // 上行 65010：局内丢 4013（有状态切帧）
        if direction == .uplink, port == 65010, modify, cfg.blockUplink4013 {
            let (out, dropped) = up65010.filter(buf)
            if dropped > 0 { stats.drop4013 += 1 }
            if out.isEmpty && dropped > 0 { return nil }
            buf = out
        }

        // 下行 65010：局内丢检测文件
        if direction == .downlink, port == 65010, modify, cfg.blockDownlinkDetect {
            let (out, dropped) = down65010.filter(buf)
            if dropped > 0 { stats.dropDetect += 1 }
            if out.isEmpty && dropped > 0 { return nil }
            buf = out
        }

        // 上行 NJ 0E（修改/大厅都可拦）
        if direction == .uplink, cfg.blockNjReport0E,
           (modify || cfg.workMode == 3),
           watch || port == 443 || port == 80,
           AceSignatures.containsNjReport0E(buf) {
            stats.dropNj0E += 1
            return nil
        }

        // 轻洗检测标记
        if cfg.neuterNjMarkers, cfg.workMode != 0,
           watch || AceSignatures.contains(buf, AceSignatures.nj23)
               || AceSignatures.contains(buf, AceSignatures.nj09) {
            if AceSignatures.neuterNjMarkers(&buf) {
                stats.neuterNj += 1
            }
        }

        return buf
    }

    /// 无端口上下文时的包级快筛（隧道 IP 层）：命中则整包丢弃。
    public func shouldDropPacketPayload(_ payload: Data, srcPort: Int, dstPort: Int) -> Bool {
        guard cfg.localInterceptEnabled else { return false }
        let modify = cfg.isModifyMode
        // 上行：本地→远端，dst=65010
        if modify, cfg.blockUplink4013, dstPort == 65010,
           Port65010UplinkFilter.contains4013(payload) {
            stats.drop4013 += 1
            return true
        }
        // 下行：远端→本地，src=65010
        if modify, cfg.blockDownlinkDetect, srcPort == 65010 {
            let d = [UInt8](payload)
            if d.count >= 20 {
                for i in 0...(d.count - 20) {
                    if Port65010UplinkFilter.is4013At(d, i),
                       d[i + 16] == 0x19, d[i + 17] == 0x00, d[i + 18] == 0x00,
                       Port65010DownlinkFilter.isDetectionFileTlv(d[i + 19]) {
                        stats.dropDetect += 1
                        return true
                    }
                    if Port65010UplinkFilter.is4013At(d, i), d.count - i >= 1500 {
                        stats.dropDetect += 1
                        return true
                    }
                }
            } else if Port65010UplinkFilter.contains4013(payload), payload.count >= 1500 {
                stats.dropDetect += 1
                return true
            }
        }
        if cfg.blockNjReport0E, (modify || cfg.workMode == 3),
           (dstPort == 80 || dstPort == 443 || AceSignatures.isWatchPort(dstPort)
            || AceSignatures.isWatchPort(srcPort)),
           AceSignatures.containsNjReport0E(payload) {
            stats.dropNj0E += 1
            return true
        }
        return false
    }
}
