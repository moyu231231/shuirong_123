import SwiftUI

struct MemoryStatusView: View {
    var body: some View {
        NavigationView {
            List {
                HStack {
                    Text("库")
                    Spacer()
                    Text(BuiltinInjector.dylibFileName).foregroundColor(.secondary)
                }
                HStack {
                    Text("线程")
                    Spacer()
                    Text("脉冲挂起").foregroundColor(.secondary)
                }
                HStack {
                    Text("取数")
                    Spacer()
                    Text("清空").foregroundColor(.secondary)
                }
                HStack {
                    Text("发送")
                    Spacer()
                    Text("特征过滤").foregroundColor(.secondary)
                }
                HStack {
                    Text("加密")
                    Spacer()
                    Text("输出置零").foregroundColor(.secondary)
                }
            }
            .navigationTitle("内存")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
