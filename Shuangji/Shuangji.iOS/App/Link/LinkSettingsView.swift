import SwiftUI
import NetworkExtension

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
                    Text("中枢 \(cfg.accountHost):\(cfg.accountPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("退出登录", role: .destructive) {
                        onLogout?()
                    }
                }

                Section(header: Text("本机拦截"), footer: Text("不依赖 PC 网关。打开隧道后按工作模式在本机丢弃/清洗目标包。局内请用「修改」。")) {
                    Toggle("启用本机拦截", isOn: $cfg.localInterceptEnabled)
                    Toggle("上行 4013（举报/异常）", isOn: $cfg.blockUplink4013)
                    Toggle("下行检测文件", isOn: $cfg.blockDownlinkDetect)
                    Toggle("NJ 异常包", isOn: $cfg.blockNjReport0E)
                    Toggle("标记清洗 23/09", isOn: $cfg.neuterNjMarkers)
                }

                Section(header: Text("工作模式"), footer: Text("读取/大厅：放行 65010 以便上号。进局点「修改」才拦举报与检测文件。")) {
                    modeButton(title: "读取", subtitle: "上号期，不拦 65010", tag: 1)
                    modeButton(title: "大厅", subtitle: "只洗 NJ", tag: 3)
                    modeButton(title: "修改", subtitle: "局内：本机拦 4013/检测文件", tag: 2)
                    modeButton(title: "待机", subtitle: "全放行", tag: 0)
                    Text("当前：\(modeName(cfg.workMode))")
                        .font(.footnote)
                        .foregroundColor(cfg.workMode == 2 ? .green : .secondary)
                    if !info.isEmpty {
                        Text(info).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("隧道") {
                    Toggle("经上游 SOCKS（一般关闭）", isOn: $cfg.useUpstreamSocks)
                    if cfg.useUpstreamSocks {
                        TextField("节点", text: $cfg.host)
                            .textInputAutocapitalization(.never)
                        TextField("SOCKS 端口", value: $cfg.socksPort, format: .number)
                            .keyboardType(.numberPad)
                    }
                    if !vpnState.isEmpty {
                        Text(vpnState).foregroundColor(.secondary)
                    }
                    Button("保存设置") {
                        cfg.save()
                        info = "已保存（隧道会自动重载）"
                    }
                    Button("连接本机拦截") { startVPN() }
                    Button("断开") { stopVPN() }
                }
            }
            .navigationTitle("链路")
            .onAppear { cfg = AppConfig.load() }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func modeButton(title: String, subtitle: String, tag: Int) -> some View {
        Button {
            cfg.workMode = tag
            cfg.save()
            info = "已切换为\(modeName(tag))（纯本机，不经引擎）"
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
        case 1: return "读取"
        case 2: return "修改"
        case 3: return "大厅"
        default: return "未知"
        }
    }

    private func startVPN() {
        cfg.save()
        NETunnelProviderManager.loadAllFromPreferences { list, _ in
            let m = list?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "com.shuiyong.ports.tunnel"
            proto.serverAddress = "local-intercept"
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
                        DispatchQueue.main.async { vpnState = "本机拦截已连接" }
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
}
