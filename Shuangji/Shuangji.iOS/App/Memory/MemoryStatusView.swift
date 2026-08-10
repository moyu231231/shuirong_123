import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                Section("注入闪退根因（已修）") {
                    Text("旧版把 dylib 命名成 ApolloNetService.dylib，会覆盖腾讯正版库 → 进游戏秒闪。现已改为 sy_ports.dylib。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("你需要做") {
                    Text("1. 重装游戏（恢复被盖坏的库）\n2. 装新 tipa\n3. 再注入（空载，只验证能进游戏）")
                        .font(.footnote)
                }
                Section("当前 dylib") {
                    row("文件", "sy_ports.dylib")
                    row("逻辑", "空载，无补丁/无钩子")
                    row("目标", "避开 Apollo/GCloud/tersafe")
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
}
