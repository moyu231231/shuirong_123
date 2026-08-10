import SwiftUI
import NetworkExtension
import UIKit

struct LinkSettingsView: View {
    var onLogout: (() -> Void)?

    @State private var cfg = AppConfig.load()
    @State private var vpnState = ""
    @State private var info = ""
    @State private var busy = false
    @State private var poolText = "尚未刷新"
    @State private var greenFrozen = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("账号"), footer: Text("已登录：\(AuthSession.userName)")) {
                    Button("退出登录", role: .destructive) { onLogout?() }
                }

                Section(header: Text("绿色数据"), footer: Text("流程：点「读取」→ 小火箭代理 → 同账号上号等绿>0 → 再切大厅/修改进局。绿冻结后要重读请先「重置绿池」。")) {
                    Text(poolText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(greenFrozen ? .green : .secondary)
                    Button(busy ? "刷新中…" : "刷新绿池状态") { refreshPool() }
                        .disabled(busy)
                    Button("重置绿池（解冻可再读）", role: .destructive) { resetPool() }
                        .disabled(busy)
                }

                Section(header: Text("① 工作模式（引擎）"), footer: Text(info.isEmpty ? "读取=收上号绿包；大厅=上号不拦；修改=局内拦 4013。" : info)) {
                    modeButton(title: "读取", subtitle: "上号绿色期：透传并收集 65010 下行", tag: 1)
                    modeButton(title: "大厅", subtitle: "上号：不拦 65010", tag: 3)
                    modeButton(title: "修改", subtitle: "局内：拦 4013/检测文件 + 用绿样本替换", tag: 2)
                    modeButton(title: "待机", subtitle: "全放行", tag: 0)
                    Text("当前：\(EngineAPI.modeName(cfg.workMode))")
                        .font(.footnote)
                        .foregroundColor(cfg.workMode == 1 ? .orange : (cfg.workMode == 2 ? .green : .secondary))
                }

                Section("② 云端代理") {
                    Button("一键导入小火箭节点") { openShadowrocket() }
                    Button("复制代理链接") { copyProxyLink() }
                    Text("必须走 SOCKS 经网关，引擎才能读到绿/拦 4013。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                cfg.save()
                refreshVPNState()
                refreshPool()
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
                    case .success:
                        info = "引擎已切换：\(EngineAPI.modeName(tag))"
                        refreshPool()
                    case .failure(let e):
                        info = "引擎切换失败：\(e.localizedDescription)"
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

    private func refreshPool() {
        EngineAPI.status(cfg: cfg) { r in
            DispatchQueue.main.async {
                switch r {
                case .success(let s):
                    let n = s.PoolCount ?? 0
                    let frozen = s.GreenFrozen ?? false
                    greenFrozen = frozen
                    let ready = s.ReadyText ?? ""
                    let mode = s.Mode.map { EngineAPI.modeName($0) } ?? "?"
                    poolText = "引擎模式=\(mode)  绿池=\(n)  冻结=\(frozen ? "是" : "否")\n\(ready.isEmpty ? (n > 0 ? "已有绿样本" : "绿池为空") : ready)"
                    if let m = s.Mode { cfg.workMode = m; cfg.save() }
                case .failure(let e):
                    poolText = "状态失败：\(e.localizedDescription)\n（确认引擎 :8088 在跑且账号正确）"
                    greenFrozen = false
                }
            }
        }
    }

    private func resetPool() {
        busy = true
        EngineAPI.reset(cfg: cfg) { r in
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success:
                    info = "绿池已重置，请切「读取」再上号"
                    cfg.workMode = 1
                    cfg.save()
                    EngineAPI.setMode(cfg: cfg, mode: 1) { _ in
                        DispatchQueue.main.async { refreshPool() }
                    }
                case .failure(let e):
                    info = "重置失败：\(e.localizedDescription)"
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
