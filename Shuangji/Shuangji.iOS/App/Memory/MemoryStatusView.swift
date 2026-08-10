import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                Section("当前策略（防闪退）") {
                    row("导出", "get_report* / enable → 空")
                    row("导入表", "fishhook 仅报告符号")
                    row("内部 RVA", "暂不打（曾致闪退）")
                }
                Section("成功标志") {
                    Text("进游戏数秒后屏幕上方出现黑色浮条：「报告钩子已生效」。不是系统弹窗。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("用法") {
                    row("注入", "成功后自动打开游戏")
                    row("iPad", "可与游戏分屏")
                    row("网络", "4013 走链路，不钩 send")
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
            Text(v).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
