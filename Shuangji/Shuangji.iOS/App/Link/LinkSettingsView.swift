import SwiftUI
import NetworkExtension
import UIKit

struct LinkSettingsView: View {
    var onLogout: (() -> Void)?

    @State private var cfg = AppConfig.load()
    @State private var vpnState = ""
    @State private var info = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("账号"), footer: Text("已登录：\(AuthSession.userName)")) {
                    Button("退出登录", role: .destructive) { onLogout?() }
                }

                Section(header: Text("为什么会仍被检测"), footer: Text("空 VPN 不拦包；只改 GOT 挡不住 tersafe 内部检测。必须：①内存补丁 ②流量走云端网关（小火箭 SOCKS）。服务器上需同时跑账号中枢+网关+引擎，引擎为「修改」模式。")) {
                    Text(info.isEmpty ? "按下方顺序操作" : info)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("① 云端拦截（必需）") {
                    Button(busy ? "切换中…" : "切换为修改模式") { setModifyMode() }
                        .disabled(busy)
                    Button("一键导入小火箭节点") { openShadowrocket() }
                    Button("复制代理链接") { copyProxyLink() }
                    Text("小火箭开启全局/规则代理后再进游戏。上号可先大厅，进局保持修改。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section("② 工作模式（引擎）") {
                    modeButton(title: "大厅", subtitle: "上号：不拦 65010", tag: 3)
                    modeButton(title: "修改", subtitle: "局内：拦 4013/检测文件", tag: 2)
                    modeButton(title: "待机", subtitle: "全放行", tag: 0)
                    Text("当前本地标记：\(modeName(cfg.workMode))")
                        .font(.footnote)
                        .foregroundColor(cfg.workMode == 2 ? .green : .secondary)
                }

                Section("③ 状态 VPN（可选，不拦包）") {
                    if !vpnState.isEmpty {
                        Text(vpnState).foregroundColor(.secondary)
                    }
                    Button("连接") { startVPN() }
                    Button("断开", role: .destructive) { stopVPN() }
                }
            }
            .navigationTitle("链路")
            .onAppear {
                cfg = AppConfig.load()
                cfg.host = HubEndpoint.host
                cfg.socksPort = HubEndpoint.socksPort
                cfg.enginePort = HubEndpoint.enginePort
                cfg.accountHost = HubEndpoint.host
                cfg.accountPort = HubEndpoint.accountPort
                if cfg.workMode == 1 { cfg.workMode = 3 }
                cfg.save()
                refreshVPNState()
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func modeButton(title: String, subtitle: String, tag: Int) -> some View {
        Button {
            busy = true
            cfg.workMode = tag
            cfg.save()
            EngineAPI.setMode(cfg: cfg, mode: tag) { r in
                DispatchQueue.main.async {
                    busy = false
                    switch r {
                    case .success: info = "引擎已切换：\(modeName(tag))"
                    case .failure(let e): info = "引擎切换失败：\(e.localizedDescription)（仍可先用小火箭）"
                    }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if cfg.workMode == tag {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                }
            }
        }
        .disabled(busy)
    }

    private func modeName(_ m: Int) -> String {
        switch m {
        case 0: return "待机"
        case 2: return "修改"
        case 3: return "大厅"
        default: return "大厅"
        }
    }

    private func setModifyMode() {
        busy = true
        cfg.workMode = 2
        cfg.save()
        EngineAPI.setMode(cfg: cfg, mode: 2) { r in
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success: info = "引擎已是修改模式，请导入小火箭并全局代理"
                case .failure(let e): info = e.localizedDescription
                }
            }
        }
    }

    private func proxyLink() -> String {
        let u = cfg.userName.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? cfg.userName
        let p = cfg.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? cfg.password
        return "socks5://\(u):\(p)@\(HubEndpoint.host):\(HubEndpoint.socksPort)"
    }

    private func openShadowrocket() {
        let raw = "socks5://\(cfg.userName):\(cfg.password)@\(HubEndpoint.host):\(HubEndpoint.socksPort)"
        let b64 = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        if let url = URL(string: "shadowrocket://add/\(b64)") {
            UIApplication.shared.open(url) { ok in
                DispatchQueue.main.async {
                    info = ok ? "已唤起小火箭，请允许添加并开启代理" : "未安装小火箭，已复制链接，请手动添加"
                    if !ok { UIPasteboard.general.string = proxyLink() }
                }
            }
        } else {
            UIPasteboard.general.string = proxyLink()
            info = "已复制代理链接"
        }
    }

    private func copyProxyLink() {
        UIPasteboard.general.string = proxyLink()
        info = "已复制（粘贴到小火箭添加）"
    }

    private func startVPN() {
        cfg.save()
        NETunnelProviderManager.loadAllFromPreferences { list, err in
            if let err {
                DispatchQueue.main.async { vpnState = err.localizedDescription }
                return
            }
            let m = list?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "com.shuiyong.ports.tunnel"
            proto.serverAddress = "本机状态"
            m.protocolConfiguration = proto
            m.localizedDescription = "水溶C"
            m.isEnabled = true
            m.saveToPreferences { err in
                if let err {
                    DispatchQueue.main.async { vpnState = err.localizedDescription }
                    return
                }
                m.loadFromPreferences { _ in
                    do {
                        try m.connection.startVPNTunnel()
                        DispatchQueue.main.async {
                            vpnState = "已连接（仅状态，不拦包；拦截靠小火箭）"
                        }
                    } catch {
                        DispatchQueue.main.async { vpnState = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func stopVPN() {
        NETunnelProviderManager.loadAllFromPreferences { list, _ in
            list?.first?.connection.stopVPNTunnel()
            DispatchQueue.main.async { vpnState = "已断开" }
        }
    }

    private func refreshVPNState() {
        NETunnelProviderManager.loadAllFromPreferences { list, _ in
            let st = list?.first?.connection.status
            let text: String
            switch st {
            case .connected: text = "状态 VPN 已连接（不拦包）"
            case .connecting: text = "连接中…"
            default: text = "状态 VPN 未连接"
            }
            DispatchQueue.main.async { vpnState = text }
        }
    }
}
