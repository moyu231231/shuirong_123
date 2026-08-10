import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                Section("已恢复") {
                    row("导出", "get_report* → 空")
                    row("导入表", "fishhook 报告符号")
                    row("提示", "进游戏后顶部浮条")
                }
                Section("仍不做") {
                    row("内部 RVA", "总闸/扫内存（易闪）")
                    row("网络钩", "send/write")
                    row("文件名", "sy_ports（非 Apollo）")
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
