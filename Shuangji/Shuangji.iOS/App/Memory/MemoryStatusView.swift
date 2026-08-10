import SwiftUI

struct MemoryStatusView: View {
    @State private var statusText = "尚未检查"
    @State private var busy = false

    private let statusPaths = [
        "/var/mobile/Library/Caches/sy_ports_status.txt",
        "/tmp/sy_ports_status.txt"
    ]

    var body: some View {
        NavigationView {
            List {
                Section("当前") {
                    row("机器码补丁", "已关闭（会闪）")
                    row("fishhook", "报告 + OnRecv/anti_data")
                    row("提示", "游戏内悬浮窗")
                }
                Section("检查") {
                    Text(statusText)
                        .font(.system(.body, design: .monospaced))
                    Button(busy ? "检查中…" : "检查补丁") { checkStatus() }
                        .disabled(busy)
                }
            }
            .navigationTitle("内存")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).font(.caption).foregroundColor(.secondary)
        }
    }

    private func checkStatus() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { busy = false } }
            let sy = Bundle.main.bundleURL.appendingPathComponent("syinject")
            guard FileManager.default.fileExists(atPath: sy.path) else {
                DispatchQueue.main.async { statusText = "缺少 syinject" }
                return
            }
            var body = ""
            for path in statusPaths {
                if SpawnUtil.rootRun(sy.path, args: ["exists", "--path", path]).code != 0 { continue }
                let r = SpawnUtil.rootRun(sy.path, args: ["cat", "--path", path])
                body = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { break }
            }
            DispatchQueue.main.async {
                if body.isEmpty {
                    statusText = "无状态文件，请进游戏后再查"
                } else if body.hasPrefix("OK") {
                    statusText = "✅ \(body)"
                } else if body.hasPrefix("WAIT") {
                    statusText = "⏳ \(body)"
                } else {
                    statusText = "❌ \(body)"
                }
            }
        }
    }
}
