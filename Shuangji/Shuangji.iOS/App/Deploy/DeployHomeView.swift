import SwiftUI

struct DeployHomeView: View {
    @State private var jbState: DeployEnvironment.JBState = .none
    @State private var autoMempatch = DeployEnvironment.autoMempatch
    @State private var autoTweak = DeployEnvironment.autoTweak
    @State private var settle = DeployEnvironment.settleSeconds
    @State private var jbFlavor = JailbreakOrchestrator.preferredFlavor
    @State private var busy = false
    @State private var banner: String?
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMsg = ""
    @State private var phaseText = ""

    var body: some View {
        NavigationView {
            Form {
                Section("环境") {
                    HStack {
                        Text("越狱状态")
                        Spacer()
                        Text(jbState.label)
                            .foregroundColor(jbState.isJailbroken ? .green : .orange)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("越狱版本", selection: $jbFlavor) {
                        Text("RootHide Dopamine（推荐）").tag(0)
                        Text("官方 Dopamine").tag(1)
                    }
                    .onChange(of: jbFlavor) { v in
                        JailbreakOrchestrator.preferredFlavor = v
                    }
                    HStack {
                        Text("内置 tipa")
                        Spacer()
                        Text(JailbreakOrchestrator.hasBundledDopamine ? "已打包" : "运行时下载")
                            .foregroundColor(.secondary)
                    }
                    Button("重新检测") { refresh() }
                    Text("一键部署不用开游戏。开游戏只为自动/立即补丁。RootHide 下勿把三角洲勾进「隐藏越狱」。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("自动补丁模式") {
                    Toggle("自动外部内存补丁（推荐）", isOn: $autoMempatch)
                        .onChange(of: autoMempatch) { v in
                            DeployEnvironment.autoMempatch = v
                        }
                    Toggle("三角洲机型 tweak（可选·有镜像痕迹）", isOn: $autoTweak)
                        .onChange(of: autoTweak) { v in
                            DeployEnvironment.autoTweak = v
                        }
                    Stepper("settle \(settle)s", value: $settle, in: 20...120, step: 5)
                        .onChange(of: settle) { v in
                            DeployEnvironment.settleSeconds = v
                        }
                }

                Section("一键越狱并部署") {
                    Button(busy ? "进行中…" : "一键越狱并部署") {
                        runOneClick()
                    }
                    .disabled(busy)
                    .font(.headline)

                    if !phaseText.isEmpty {
                        Text(phaseText)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }

                    Button("仅部署补丁环境（已越狱）") {
                        runDeploy()
                    }
                    .disabled(busy)

                    Button("仅重启守护 sy_watch") {
                        runStartWatch()
                    }
                    .disabled(busy)

                    Button("停止守护", role: .destructive) {
                        DeployEnvironment.stopWatch()
                        banner = "已尝试停止 sy_watch"
                    }

                    if let banner {
                        Text(banner)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("补丁到底有没有用") {
                    Text("""
                    · flag/GOT：挡 COREREPORT / OnRecv，这是主价值，和改机型无关。
                    · 改机型串：只改进程里已缓存的 iPhone*,* 字符串；ACE 若现场读 hw.machine，外部改串无效，需开「机型 tweak」，且游戏不能在 RootHide 黑名单。
                    · 内存页看到 flag=1 才算补丁生效；spoof=0 只说明没扫到可改串，不等于整套失败。
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Section("流程说明") {
                    Text("""
                    1. 选 RootHide Dopamine（推荐）→ 一键越狱并部署
                    2. TrollStore 安装 tipa（需 URL Scheme）
                    3. Dopamine 内点 Jailbreak
                    4. 自动部署到 /var/mobile/Library/shuiyong（兼容 RootHide）
                    5. 开三角洲 → 内存页看 flag/spoof/jb
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("部署")
            .onAppear(perform: refresh)
            .alert(alertTitle, isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMsg)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func refresh() {
        jbState = DeployEnvironment.detect()
        jbFlavor = JailbreakOrchestrator.preferredFlavor
        autoMempatch = DeployEnvironment.autoMempatch
        autoTweak = DeployEnvironment.autoTweak
        settle = DeployEnvironment.settleSeconds
    }

    private func applyPrefs() {
        JailbreakOrchestrator.preferredFlavor = jbFlavor
        DeployEnvironment.autoMempatch = autoMempatch
        DeployEnvironment.autoTweak = autoTweak
        DeployEnvironment.settleSeconds = settle
    }

    private func runOneClick() {
        busy = true
        phaseText = "准备中…"
        banner = nil
        applyPrefs()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try JailbreakOrchestrator.oneClick { p in
                    DispatchQueue.main.async {
                        phaseText = "[\(p.phase.rawValue)] \(p.detail)"
                    }
                }
                DispatchQueue.main.async {
                    busy = false
                    refresh()
                    banner = summary
                    phaseText = "完成"
                    alertTitle = "一键完成"
                    alertMsg = summary + "\n\n打开三角洲后将自动外部补丁（若已开自动）。"
                    showAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    refresh()
                    banner = error.localizedDescription
                    phaseText = "失败"
                    alertTitle = "未完成"
                    alertMsg = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func runDeploy() {
        busy = true
        banner = "部署中…"
        applyPrefs()
        let state = DeployEnvironment.detect()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try DeployEnvironment.deploy(state: state)
                DispatchQueue.main.async {
                    busy = false
                    refresh()
                    banner = summary
                    alertTitle = "部署成功"
                    alertMsg = summary
                    showAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    banner = error.localizedDescription
                    alertTitle = "部署失败"
                    alertMsg = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func runStartWatch() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let s = try DeployEnvironment.startWatchOnly()
                DispatchQueue.main.async {
                    busy = false
                    banner = s
                    alertTitle = "守护已启动"
                    alertMsg = s
                    showAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    banner = error.localizedDescription
                    alertTitle = "启动失败"
                    alertMsg = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }
}
