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
                Section("推荐：纯本地三层") {
                    row("引擎", "sy_mempatch / task_for_pid")
                    row("A", "外层 GOT → ret0")
                    row("B", "tersafe DATA 回调切断")
                    row("C", "叶子上报 RVA（COREREPORT 等）")
                    row("不做", "总闸 10E36C / 扫描器 / 网络 4013")
                    row("延时", "45s+随机抖动")
                }
                Section("备选") {
                    row("动态注入", "opainject（易被扫镜像）")
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
                    statusText = "无状态\n请内存补丁后再查"
                } else if body.hasPrefix("OK") {
                    // Highlight data/leaf for pure-local success criteria
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
