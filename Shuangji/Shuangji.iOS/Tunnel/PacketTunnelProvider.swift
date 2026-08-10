import NetworkExtension
import Foundation

/// 本机拦截隧道：不依赖 PC 网关。
/// 从 packetFlow 读 IPv4/TCP，按端口/载荷特征丢弃要拦的包，其余原样写回。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var filter: Layer1Filter?
    private var cfg = AppConfig.default
    private var running = false
    private var dropCount = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        cfg = AppConfig.load()
        filter = Layer1Filter(config: cfg)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.0"])
        // 本机拦截：只盯常见 ACE/游戏相关网段不可靠，先走默认路由再靠特征丢包
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }
            guard let self else { completionHandler(nil); return }
            self.running = true
            self.log("local intercept up mode=\(self.cfg.workMode) socks=\(self.cfg.useUpstreamSocks)")
            self.readLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        log("tunnel stop reason=\(reason.rawValue) dropped=\(dropCount)")
        completionHandler()
    }

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protos in
            guard let self, self.running else { return }
            self.cfg = AppConfig.load()
            self.filter?.reload(self.cfg)

            var outPackets: [Data] = []
            var outProtos: [NSNumber] = []
            for (idx, pkt) in packets.enumerated() {
                let proto = idx < protos.count ? protos[idx] : NSNumber(value: AF_INET)
                if self.shouldDrop(pkt) {
                    self.dropCount += 1
                    continue
                }
                var mutable = pkt
                if self.neuterIfNeeded(&mutable) {
                    outPackets.append(mutable)
                } else {
                    outPackets.append(pkt)
                }
                outProtos.append(proto)
            }
            if !outPackets.isEmpty {
                self.packetFlow.writePackets(outPackets, withProtocols: outProtos)
            }
            self.readLoop()
        }
    }

    /// 解析 IPv4 TCP 载荷，命中本机规则则丢弃整包。
    private func shouldDrop(_ packet: Data) -> Bool {
        guard let filter, cfg.localInterceptEnabled else { return false }
        guard packet.count >= 40 else { return false }
        let bytes = [UInt8](packet)
        // IPv4
        guard (bytes[0] >> 4) == 4 else { return false }
        let ihl = Int(bytes[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 20 else { return false }
        guard bytes[9] == 6 else { return false } // TCP
        let srcPort = (Int(bytes[ihl]) << 8) | Int(bytes[ihl + 1])
        let dstPort = (Int(bytes[ihl + 2]) << 8) | Int(bytes[ihl + 3])
        let dataOff = Int((bytes[ihl + 12] >> 4) & 0x0F) * 4
        let payloadOff = ihl + dataOff
        guard payloadOff <= packet.count else { return false }
        let payload = packet.subdata(in: payloadOff..<packet.count)
        if payload.isEmpty { return false }
        return filter.shouldDropPacketPayload(payload, srcPort: srcPort, dstPort: dstPort)
    }

    /// 轻洗 NJ 标记（就地改 TCP 载荷并重算校验）。
    private func neuterIfNeeded(_ packet: inout Data) -> Bool {
        guard cfg.localInterceptEnabled, cfg.neuterNjMarkers, cfg.workMode != 0 else { return false }
        guard packet.count >= 40 else { return false }
        var bytes = [UInt8](packet)
        guard (bytes[0] >> 4) == 4 else { return false }
        let ihl = Int(bytes[0] & 0x0F) * 4
        guard bytes[9] == 6 else { return false }
        let dataOff = Int((bytes[ihl + 12] >> 4) & 0x0F) * 4
        let payloadOff = ihl + dataOff
        guard payloadOff < bytes.count else { return false }
        var payload = Data(bytes[payloadOff..<bytes.count])
        guard AceSignatures.neuterNjMarkers(&payload) else { return false }
        let p = [UInt8](payload)
        for i in 0..<p.count { bytes[payloadOff + i] = p[i] }
        // zero checksums then recompute
        bytes[10] = 0; bytes[11] = 0
        let ipSum = Self.checksum(bytes, 0, ihl)
        bytes[10] = UInt8((ipSum >> 8) & 0xFF)
        bytes[11] = UInt8(ipSum & 0xFF)
        let tcpLen = bytes.count - ihl
        bytes[ihl + 16] = 0; bytes[ihl + 17] = 0
        var pseudo = [UInt8]()
        pseudo.append(contentsOf: bytes[12..<16])
        pseudo.append(contentsOf: bytes[16..<20])
        pseudo.append(0)
        pseudo.append(6)
        pseudo.append(UInt8((tcpLen >> 8) & 0xFF))
        pseudo.append(UInt8(tcpLen & 0xFF))
        pseudo.append(contentsOf: bytes[ihl..<bytes.count])
        if pseudo.count % 2 == 1 { pseudo.append(0) }
        let tcpSum = Self.checksum(pseudo, 0, pseudo.count)
        bytes[ihl + 16] = UInt8((tcpSum >> 8) & 0xFF)
        bytes[ihl + 17] = UInt8(tcpSum & 0xFF)
        packet = Data(bytes)
        return true
    }

    private static func checksum(_ bytes: [UInt8], _ start: Int, _ len: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = start
        let end = start + len
        while i + 1 < end {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < end { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    func applyLayer1(port: Int, uplink: Bool, data: Data) -> Data? {
        filter?.process(port: port, direction: uplink ? .uplink : .downlink, data: data) ?? data
    }

    private func log(_ msg: String) {
        NSLog("[水溶C-Tunnel] %@", msg)
    }
}
