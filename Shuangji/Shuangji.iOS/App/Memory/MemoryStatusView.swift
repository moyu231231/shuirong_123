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
                Section("内存补丁（稳态+ACE机型）") {
                    row("机型伪装", "iPhone18,1(17 Pro) + iOS 26.6(23G71)")
                    row("DATA门闩", "版本校验后写 COREREPORT enabled/checked")
                    row("GOT", "仅 OnRecv → ret0（不改 GetReport）")
                    row("不做", "安卓花海华为/PC；报告 TEXT")
                }
                Section("注意") {
                    Text("状态含 spoof=iphone18,1+ios26.6 与 flag=1。小火箭修改模式仍要开。真机若仍是旧系统，仅上报字段被改。")
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
