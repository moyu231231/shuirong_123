import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                Section("IDA 定点（tersafe 7.7.49）") {
                    row("导出", "get_report* / enable → 空")
                    row("上报", "COREREPORT / TDM / shell")
                    row("总闸", "0x10E36C ms 控制块 RET0")
                    row("隐藏", "vm扫描 / shadowed / bin_patch / md5")
                }
                Section("明确不做") {
                    row("线程", "不挂起、不扫线程名")
                    row("网络", "不钩 send/write")
                    row("用法", "退游戏→注入→再开")
                }
                Section("成功标志") {
                    Text("进游戏数秒后弹窗：报告/检测补丁已生效（含各项计数）")
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
            Text(v).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
