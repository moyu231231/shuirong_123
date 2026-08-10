import SwiftUI
import NetworkExtension

struct LinkSettingsView: View {
    @State private var cfg = AppConfig.load()
    @State private var vpnState = ""
    @State private var info = ""
    @State private var busy = false

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

                Section("隧道") {
                    Toggle("上行过滤", isOn: $cfg.blockUplink4013)
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

                Section("模式") {
                    Button("读取") { mode(1) }.disabled(busy)
                    Button("大厅") { mode(3) }.disabled(busy)
                    Button("局内") { mode(2) }.disabled(busy)
                    Button("待机") { mode(0) }.disabled(busy)
                    Button("重置") { reset() }.disabled(busy)
                    if !info.isEmpty {
                        Text(info).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("链路")
            .onAppear { refresh() }
        }
        .navigationViewStyle(.stack)
    }

    private func mode(_ m: Int) {
        busy = true
        cfg.save()
        EngineAPI.setMode(cfg: cfg, mode: m) { r in
            DispatchQueue.main.async {
                busy = false
                info = (try? r.get()).map { _ in "OK" } ?? "失败"
                refresh()
            }
        }
    }

    private func reset() {
        busy = true
        EngineAPI.reset(cfg: cfg) { r in
            DispatchQueue.main.async {
                busy = false
                info = (try? r.get()).map { _ in "OK" } ?? "失败"
            }
        }
    }

    private func refresh() {
        EngineAPI.status(cfg: cfg) { r in
            DispatchQueue.main.async {
                if case .success(let s) = r {
                    info = "m=\(s.Mode ?? -1) p=\(s.PoolCount ?? 0) x=\(s.BoostInterceptCount ?? 0)"
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
