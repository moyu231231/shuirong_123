import NetworkExtension
import Foundation

/// 本机拦截隧道：可连接并显示 VPN 状态。
/// 故意不劫持默认路由（includedRoutes 为空），否则无转发栈会全机断网。
/// 实际拦截靠「内存补丁」+ App 内本机规则；隧道用于状态展示与后续扩展。
class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let cfg = AppConfig.load()
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.0"])
        // 关键：不要 NEIPv4Route.default()，流量继续走系统网卡
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { error in
            if let error {
                completionHandler(error)
                return
            }
            NSLog("[水溶C-Tunnel] up (no default-route) local=%d mode=%d",
                  cfg.localInterceptEnabled ? 1 : 0, cfg.workMode)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[水溶C-Tunnel] stop reason=%d", reason.rawValue)
        completionHandler()
    }
}
