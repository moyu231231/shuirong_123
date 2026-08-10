import SwiftUI

@main
struct ShuiyongApp: App {
    @State private var loggedIn = AuthSession.isLoggedIn

    var body: some Scene {
        WindowGroup {
            if loggedIn {
                RootTabView(onLogout: {
                    AuthSession.logout()
                    loggedIn = false
                })
            } else {
                LoginView {
                    loggedIn = true
                }
            }
        }
    }
}
