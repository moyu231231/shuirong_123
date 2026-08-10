import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                Section("当前：安全空载") {
                    Text("dylib 只加载、不打补丁、不挂 fishhook、不弹窗。用来确认注入本身会不会闪退。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("已关掉（曾致闪）") {
                    row("TEXT补丁", "get_report / RVA")
                    row("fishhook", "全进程重绑")
                    row("UI", "游戏内浮窗/弹窗")
                    row("网络钩", "send/write")
                }
                Section("上报怎么办") {
                    Text("先用链路/网关拦 4013。进游戏不闪后再逐步加软钩子。")
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
            Text(k)
            Spacer()
            Text(v).font(.caption).foregroundColor(.secondary)
        }
    }
}
