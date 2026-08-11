import SwiftUI

struct MemoryStatusView: View {
    @State private var statusText = "尚未检查"
    @State private var heartText = "守护：未知"
    @State private var busy = false
    @State private var timerOn = false

    private let statusPath = "/var/mobile/Library/Caches/sy_ports_status.txt"
    private let heartPath = "/var/mobile/Library/Caches/sy_watch_heartbeat.txt"
    private let tmpStatus = "/tmp/sy_ports_status.txt"

    var body: some View {
        NavigationView {
            List {
                Section("补丁状态（看 time= 是否变新）") {
                    Text(statusText)
                        .font(.system(.footnote, design: .monospaced))
                    Text(heartText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button(busy ? "刷新中…" : "刷新状态") { checkStatus() }
                        .disabled(busy)
                    Toggle("自动刷新（3秒）", isOn: $timerOn)
                        .onChange(of: timerOn) { on in
                            if on { checkStatus() }
                        }
                }
                Section("操作") {
                    Button("立即补丁（游戏需已打开）") { patchNow() }
                        .disabled(busy)
                    Button("重启自动守护 sy_watch") { restartWatch() }
                        .disabled(busy)
                }
                Section {
                    Text("若一直是旧 OK：说明自动守护没抓到游戏或没跑起来。先开游戏 →「立即补丁」，或「重启自动守护」后再进游戏。心跳 alive=1 且 time 在变才算守护活着。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("内存")
            .onAppear {
                checkStatus()
            }
            .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                if timerOn && !busy { checkStatus() }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func syinjectURL() -> URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("syinject")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func readFile(_ sy: URL, _ path: String) -> String {
        if SpawnUtil.rootRun(sy.path, args: ["exists", "--path", path]).code != 0 {
            return ""
        }
        let r = SpawnUtil.rootRun(sy.path, args: ["cat", "--path", path])
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkStatus() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { busy = false } }
            guard let sy = syinjectURL() else {
                DispatchQueue.main.async {
                    statusText = "缺少 syinject"
                    heartText = "守护：—"
                }
                return
            }
            var body = readFile(sy, statusPath)
            if body.isEmpty { body = readFile(sy, tmpStatus) }
            let heart = readFile(sy, heartPath)
            DispatchQueue.main.async {
                if body.isEmpty {
                    statusText = "无状态\n请部署后开游戏，或点「立即补丁」"
                } else if body.hasPrefix("OK") {
                    statusText = "✅ \(body)"
                } else if body.hasPrefix("WAIT") {
                    statusText = "⏳ \(body)"
                } else {
                    statusText = "❌ \(body)"
                }
                if heart.isEmpty {
                    heartText = "守护：无心跳（sy_watch 可能没在跑）"
                } else if heart.contains("alive=1") {
                    heartText = "守护：\(heart)"
                } else {
                    heartText = "守护已停：\(heart)"
                }
            }
        }
    }

    private func patchNow() {
        busy = true
        statusText = "⏳ 立即补丁中…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let msg = try DeployEnvironment.patchNow(settleSeconds: 12)
                DispatchQueue.main.async {
                    busy = false
                    statusText = "✅ \(msg)"
                    checkStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    statusText = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private func restartWatch() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let s = try DeployEnvironment.startWatchOnly()
                DispatchQueue.main.async {
                    busy = false
                    statusText = "⏳ \(s)"
                    checkStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    statusText = "❌ \(error.localizedDescription)"
                }
            }
        }
    }
}
