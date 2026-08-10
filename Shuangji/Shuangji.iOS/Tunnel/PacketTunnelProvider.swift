import NetworkExtension
import Foundation

/// TrollStore 安装的 Network Extension：第1层过滤 + 第2层上游 SOCKS5（Shuangji Gateway）。
///
/// 说明：完整 PacketTunnel 透明代理实现较长；此处给出可编译骨架与过滤挂载点。
/// 量产时建议基于现成开源隧道（如 hev-socks5-tunnel / leaf）嵌入，在双向泵里调用 Layer1Filter。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var filter: Layer1Filter?
    private var cfg = AppConfig.default

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        cfg = AppConfig.load()
        filter = Layer1Filter(config: cfg)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }
            self?.log("tunnel up host=\(self?.cfg.host ?? "") socks=\(self?.cfg.socksPort ?? 0) layer2=\(self?.cfg.useUpstreamSocks == true)")
            // TODO: 启动本地 SOCKS/透明转发引擎，upstream = cfg.host:cfg.socksPort + user/pass
            // 在每条 TCP 双向泵中：
            //   uplink   -> filter.process(port:p, .uplink, data)
            //   downlink -> filter.process(port:p, .downlink, data)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("tunnel stop reason=\(reason.rawValue)")
        completionHandler()
    }

    /// 供嵌入式转发引擎回调：应用层字节经过第1层。
    func applyLayer1(port: Int, uplink: Bool, data: Data) -> Data? {
        filter?.process(port: port, direction: uplink ? .uplink : .downlink, data: data) ?? data
    }

    private func log(_ msg: String) {
        NSLog("[水溶C-Tunnel] %@", msg)
    }
}
