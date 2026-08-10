import SwiftUI

struct RootTabView: View {
    var onLogout: (() -> Void)?

    var body: some View {
        TabView {
            InjectHomeView()
                .tabItem { Label("注入", systemImage: "shippingbox") }
            LinkSettingsView(onLogout: onLogout)
                .tabItem { Label("链路", systemImage: "link") }
            MemoryStatusView()
                .tabItem { Label("内存", systemImage: "memorychip") }
        }
    }
}
