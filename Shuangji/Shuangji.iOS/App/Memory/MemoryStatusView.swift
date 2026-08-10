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
                Section("内存补丁") {
                    row("DATA门闩", "COREREPORT enabled=0/checked=1（防延迟踢）")
                    row("GOT", "外层导入 → tersafe/系统 ret0")
                    row("OnRecv", "检测下发入口 TEXT ret0")
                    row("GetReport", "TssSDKGetReportData* 薄导出 ret0")
                    row("不做", "匿名 RX / COREREPORT TEXT（门闩够用时）/ 总闸")
                }
                Section("注意") {
                    Text("延迟踢多半是上报积压后送出。门闩挡 COREREPORT；小火箭改修改模式仍要拦 send_cs/4013。")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    statusText = "✅ \(body)"
                } else {
                    statusText = "❌ \(body)"
                }
            }
        }
    }
}
