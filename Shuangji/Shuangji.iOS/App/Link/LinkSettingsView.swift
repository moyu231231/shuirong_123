import SwiftUI
import NetworkExtension

struct LinkSettingsView: View {
    @State private var cfg = AppConfig.load()
    @State private var vpnState = ""
    @State private var info = ""
    @State private var modeLabel = "—"
    @State private var busy = false
    @State private var currentMode = -1

    var body: some View {
        NavigationView {
            Form {
                Section("节点") {
                    TextField("地址", text: $cfg.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("代理端口", value: $cfg.socksPort, format: .number)
                        .keyboardType(.numberPad)
                    TextField("控制端口", value: $cfg.enginePort, format: .number)
                        .keyboardType(.numberPad)
                    TextField("账号", text: $cfg.userName)
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $cfg.password)
                }

                Section(header: Text("工作模式"), footer: Text("举报/异常上报只在「修改」模式拦 65010。上号用读取→大厅，进局点修改。")) {
                    modeButton(title: "读取", subtitle: "收绿样本", tag: 1)
                    modeButton(title: "大厅", subtitle: "只洗 NJ，放行 65010", tag: 3)
                    modeButton(title: "修改", subtitle: "局内：拦举报/异常上报", tag: 2)
                    modeButton(title: "待机", subtitle: "全放行", tag: 0)
                    Button("重置数据池") { reset() }.disabled(busy)
                    Text("当前：\(modeLabel)")
                        .font(.footnote)
                        .foregroundColor(currentMode == 2 ? .green : .secondary)
                    if !info.isEmpty {
                        Text(info)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Text("绿读不到时：确认「经节点转发」+ 小火箭/隧道走本机 SOCKS，点读取后再上号。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section("隧道") {
                    Toggle("上行过滤(4013)", isOn: $cfg.blockUplink4013)
                    Toggle("异常包过滤", isOn: $cfg.blockNjReport0E)
                    Toggle("标记清洗", isOn: $cfg.neuterNjMarkers)
                    Toggle("经节点转发", isOn: $cfg.useUpstreamSocks)
                    if !vpnState.isEmpty {
                        Text(vpnState).foregroundColor(.secondary)
                    }
                    Button("保存") {
                        cfg.save()
                        info = "已保存"
                    }
                    Button("连接") { startVPN() }
                    Button("断开") { stopVPN() }
                }
            }
            .navigationTitle("链路")
            .onAppear { refresh() }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func modeButton(title: String, subtitle: String, tag: Int) -> some View {
        Button {
            setMode(tag)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if currentMode == tag {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                }
            }
        }
        .disabled(busy)
    }

    private func setMode(_ m: Int) {
        busy = true
        cfg.save()
        info = "切换中…"
        EngineAPI.setMode(cfg: cfg, mode: m) { r in
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let msg):
                    currentMode = m
                    modeLabel = EngineAPI.modeName(m)
                    info = msg
                case .failure(let e):
                    info = e.localizedDescription
                }
                refresh()
            }
        }
    }

    private func reset() {
        busy = true
        EngineAPI.reset(cfg: cfg) { r in
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let msg): info = msg
                case .failure(let e): info = e.localizedDescription
                }
                refresh()
            }
        }
    }

    private func refresh() {
        EngineAPI.status(cfg: cfg) { r in
            DispatchQueue.main.async {
                if case .success(let s) = r {
                    let m = s.Mode ?? -1
                    currentMode = m
                    let pool = s.PoolCount ?? 0
                    let x = s.BoostInterceptCount ?? 0
                    modeLabel = "\(EngineAPI.modeName(m))  绿=\(pool) 拦=\(x)"
                    if info.isEmpty || info == "切换中…" {
                        info = s.ReadyText ?? ""
                    }
                }
            }
        }
    }

    private func startVPN() {
        cfg.save()
        NETunnelProviderManager.loadAllFromPreferences { list, _ in
            let m = list?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "com.shuiyong.ports.tunnel"
            proto.serverAddress = cfg.host
            m.protocolConfiguration = proto
            m.localizedDescription = "链路"
            m.isEnabled = true
            m.saveToPreferences { err in
                if let err {
                    DispatchQueue.main.async { vpnState = err.localizedDescription }
                    return
                }
                m.loadFromPreferences { _ in
                    do {
                        try m.connection.startVPNTunnel()
                        DispatchQueue.main.async { vpnState = "已连接" }
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
