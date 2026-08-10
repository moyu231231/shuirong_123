import SwiftUI
import NetworkExtension

struct LinkSettingsView: View {
    var onLogout: (() -> Void)?

    @State private var cfg = AppConfig.load()
    @State private var vpnState = ""
    @State private var info = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("账号"), footer: Text("已登录：\(AuthSession.userName)")) {
                    Button("退出登录", role: .destructive) {
                        onLogout?()
                    }
                }

                Section(header: Text("本机规则"), footer: Text("开启规则并连接 VPN 后，状态栏会显示已连接。为避免断网，流量不走隧道；局内拦截请配合「内存补丁」。")) {
                    Toggle("启用本机拦截", isOn: $cfg.localInterceptEnabled)
                    Toggle("拦上行 4013（举报/异常）", isOn: $cfg.blockUplink4013)
                    Toggle("拦下行检测文件", isOn: $cfg.blockDownlinkDetect)
                    Toggle("拦 NJ 异常包", isOn: $cfg.blockNjReport0E)
                    Toggle("清洗标记 23/09", isOn: $cfg.neuterNjMarkers)
                }

                Section(header: Text("工作模式"), footer: Text("上号用「大厅」。进局切「修改」。")) {
                    modeButton(title: "大厅", subtitle: "上号/大厅：只洗 NJ", tag: 3)
                    modeButton(title: "修改", subtitle: "局内：拦 4013/检测文件", tag: 2)
                    modeButton(title: "待机", subtitle: "全放行", tag: 0)
                    Text("当前：\(modeName(cfg.workMode))")
                        .font(.footnote)
                        .foregroundColor(cfg.workMode == 2 ? .green : .secondary)
                    if !info.isEmpty {
                        Text(info).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("VPN") {
                    if !vpnState.isEmpty {
                        Text(vpnState).foregroundColor(.secondary)
                    }
                    Button("保存设置") {
                        if cfg.workMode == 1 { cfg.workMode = 3 }
                        cfg.useUpstreamSocks = false
                        cfg.accountHost = HubEndpoint.host
                        cfg.accountPort = HubEndpoint.port
                        cfg.save()
                        info = "已保存"
                    }
                    Button("连接") { startVPN() }
                    Button("断开", role: .destructive) { stopVPN() }
                }
            }
            .navigationTitle("链路")
            .onAppear {
                cfg = AppConfig.load()
                if cfg.workMode == 1 { cfg.workMode = 3; cfg.save() }
                refreshVPNState()
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func modeButton(title: String, subtitle: String, tag: Int) -> some View {
        Button {
            cfg.workMode = tag
            cfg.save()
            info = "已切换为\(modeName(tag))"
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
    }

    private func modeName(_ m: Int) -> String {
        switch m {
        case 0: return "待机"
        case 2: return "修改"
        case 3: return "大厅"
        default: return "大厅"
        }
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
            proto.serverAddress = "本机拦截"
            m.protocolConfiguration = proto
            m.localizedDescription = "水溶C本机拦截"
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
                            vpnState = "已连接（状态栏应显示 VPN）"
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            refreshVPNState()
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
            guard let st = list?.first?.connection.status else {
                DispatchQueue.main.async { vpnState = "未连接" }
                return
            }
            let text: String
            switch st {
            case .connected: text = "已连接"
            case .connecting: text = "连接中…"
            case .disconnecting: text = "断开中…"
            case .reasserting: text = "重连中…"
            default: text = "未连接"
            }
            DispatchQueue.main.async { vpnState = text }
        }
    }
}
