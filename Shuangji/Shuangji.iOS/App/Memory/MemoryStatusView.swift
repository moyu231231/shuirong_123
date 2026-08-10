import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                Section("当前策略") {
                    row("库", BuiltinInjector.dylibFileName)
                    row("取数", "get_report* → 空")
                    row("发送", "send/sendto 吞 4013")
                    row("开关", "enable_get_report 禁用")
                    row("入站", "不补丁 rcv_anti（防闪）")
                }
                Section("成功标志") {
                    Text("注入成功：本 App 弹窗「注入成功」")
                        .font(.footnote)
                    Text("钩子成功：进游戏后弹「水溶C / 内存钩子已生效」")
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
            Text(v).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
