import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                LabeledContent("库", value: BuiltinInjector.dylibFileName)
                LabeledContent("线程", value: "脉冲挂起")
                LabeledContent("取数", value: "清空")
                LabeledContent("发送", value: "特征过滤")
                LabeledContent("加密", value: "输出置零")
            }
            .navigationTitle("内存")
        }
        .navigationViewStyle(.stack)
    }
}
