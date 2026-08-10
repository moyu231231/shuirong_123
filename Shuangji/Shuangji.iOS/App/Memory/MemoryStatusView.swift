import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                Section("当前策略（防闪）") {
                    row("时机", "tersafe 出现后再等 20 秒")
                    row("补丁", "仅 get_report* 导出")
                    row("fishhook", "已关闭")
                    row("提示", "补丁后顶部浮条")
                }
                Section("说明") {
                    Text("进游戏先应能正常玩约 20 秒，再出现「报告钩子已生效」。若一进就闪，把情况说下。")
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
