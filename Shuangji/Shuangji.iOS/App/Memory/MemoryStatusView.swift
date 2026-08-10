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
                Section("如何确认补丁成功") {
                    Text("游戏内不弹窗。进游戏约 20 秒后，回本 App 点「检查补丁」。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(statusText)
                        .font(.system(.body, design: .monospaced))
                    Button(busy ? "检查中…" : "检查补丁") { checkStatus() }
                        .disabled(busy)
                }
                Section("状态含义") {
                    row("OK patched=N", "成功，N 为补丁数（>0）")
                    row("WAIT …", "已加载，还在等待/延时")
                    row("FAIL …", "失败（无 tersafe 或补丁 0）")
                    row("无文件", "未进过游戏或 dylib 未加载")
                }
                Section("另可对照") {
                    Text("链路/网关里举报包是否还在上涨；有 OK 且 patched>0 即内存层已挂上。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("内存")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption)
            Spacer()
            Text(v).font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.trailing)
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
                let ex = SpawnUtil.rootRun(sy.path, args: ["exists", "--path", path])
                if ex.code != 0 { continue }
                let r = SpawnUtil.rootRun(sy.path, args: ["cat", "--path", path])
                body = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { break }
            }
            DispatchQueue.main.async {
                if body.isEmpty {
                    statusText = "无状态文件\n请先注入并进游戏约 20 秒后再查"
                } else if body.hasPrefix("OK") {
                    statusText = "✅ \(body)"
                } else if body.hasPrefix("WAIT") {
                    statusText = "⏳ \(body)\n再等一会后重查"
                } else {
                    statusText = "❌ \(body)"
                }
            }
        }
    }
}
