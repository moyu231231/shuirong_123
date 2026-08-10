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

                Section(header: Text("本机规则"), footer: Text("规则保存在本机，配合「内存补丁」使用。不再拉起全局 VPN（旧版会劫持路由导致全机断网）。若曾连接过，请点下方断开。")) {
                    Toggle("启用本机规则", isOn: $cfg.localInterceptEnabled)
                    Toggle("拦上行 4013（举报/异常）", isOn: $cfg.blockUplink4013)
                    Toggle("拦下行检测文件", isOn: $cfg.blockDownlinkDetect)
                    Toggle("拦 NJ 异常包", isOn: $cfg.blockNjReport0E)
                    Toggle("清洗标记 23/09", isOn: $cfg.neuterNjMarkers)
                }

                Section(header: Text("工作模式"), footer: Text("上号用「大厅」（不拦 65010）。进局切「修改」。")) {
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

                Section("网络") {
                    if !vpnState.isEmpty {
                        Text(vpnState).foregroundColor(.secondary)
                    }
                    Button("保存设置") {
                        // 若仍停在已删除的「读取」模式，自动落到大厅
                        if cfg.workMode == 1 { cfg.workMode = 3 }
                        cfg.useUpstreamSocks = false
                        cfg.accountHost = HubEndpoint.host
                        cfg.accountPort = HubEndpoint.port
                        cfg.save()
                        info = "已保存"
                    }
                    Button("断开旧版全局隧道", role: .destructive) { stopVPN() }
                }
            }
            .navigationTitle("链路")
            .onAppear {
                cfg = AppConfig.load()
                if cfg.workMode == 1 { cfg.workMode = 3; cfg.save() }
                // 进页自动尝试断开可能仍连着的黑网隧道
                stopVPNQuiet()
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

    private func stopVPN() {
        NETunnelProviderManager.loadAllFromPreferences { list, _ in
            list?.first?.connection.stopVPNTunnel()
            DispatchQueue.main.async { vpnState = "已断开全局隧道（网络应恢复）" }
        }
    }

    private func stopVPNQuiet() {
        NETunnelProviderManager.loadAllFromPreferences { list, _ in
            guard let m = list?.first, m.connection.status != .disconnected else { return }
            m.connection.stopVPNTunnel()
            DispatchQueue.main.async { vpnState = "已自动断开旧隧道" }
        }
    }
}
