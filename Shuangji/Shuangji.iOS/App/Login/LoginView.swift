import SwiftUI

struct LoginView: View {
    var onSuccess: () -> Void

    @State private var cfg = AppConfig.load()
    @State private var busy = false
    @State private var errorText = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("登录"), footer: Text("使用已开通的用户名和密码登录。")) {
                    TextField("用户名", text: $cfg.userName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $cfg.password)
                }
                if !errorText.isEmpty {
                    Section {
                        Text(errorText).foregroundColor(.red).font(.footnote)
                    }
                }
                Section {
                    Button(busy ? "登录中…" : "登录") { login() }
                        .disabled(busy || cfg.userName.isEmpty || cfg.password.isEmpty)
                }
            }
            .navigationTitle("水溶C")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func login() {
        busy = true
        errorText = ""
        // 强制使用内置中枢，不读/不展示用户可改地址
        cfg.accountHost = HubEndpoint.host
        cfg.accountPort = HubEndpoint.port
        cfg.save()
        AccountHubAPI.auth(host: HubEndpoint.host, port: HubEndpoint.port,
                           user: cfg.userName, password: cfg.password) { result in
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let r):
                    AuthSession.markLoggedIn(user: cfg.userName, token: r.token ?? "ok")
                    cfg.save()
                    onSuccess()
                case .failure(let e):
                    errorText = e.localizedDescription
                }
            }
        }
    }
}
