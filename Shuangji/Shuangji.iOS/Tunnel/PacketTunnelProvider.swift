import NetworkExtension
import Foundation

/// 旧版全局 VPN 会劫持默认路由且无转发栈 → 全机断网。
/// 现改为拒绝拉起（立即失败），避免再次黑网。过滤规则由 App 内存补丁 + 配置承担。
class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[水溶C-Tunnel] refuse full-tunnel (prevents network blackhole)")
        let err = NSError(
            domain: "com.shuiyong.ports.tunnel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "已禁用全局隧道，请用内存补丁；到链路页点断开"]
        )
        completionHandler(err)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
