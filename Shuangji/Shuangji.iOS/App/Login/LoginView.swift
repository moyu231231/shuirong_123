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
        cfg.accountHost = HubEndpoint.host
        cfg.accountPort = HubEndpoint.accountPort
        cfg.host = HubEndpoint.host
        cfg.socksPort = HubEndpoint.socksPort
        cfg.enginePort = HubEndpoint.enginePort
        // 登录不强制改模式，避免冲掉「读取」收绿流程；默认保留本地标记
        if cfg.workMode != 0 && cfg.workMode != 1 && cfg.workMode != 2 && cfg.workMode != 3 {
            cfg.workMode = 1
        }
        cfg.localInterceptEnabled = true
        cfg.save()

        AccountHubAPI.auth(host: HubEndpoint.host, port: HubEndpoint.accountPort,
                           user: cfg.userName, password: cfg.password) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    AuthSession.markLoggedIn(user: cfg.userName, token: r.token ?? "ok")
                    // 同步引擎为当前模式（含读取），不强制修改
                    EngineAPI.setMode(cfg: cfg, mode: cfg.workMode) { _ in
                        DispatchQueue.main.async {
                            busy = false
                            onSuccess()
                        }
                    }
                case .failure(let e):
                    busy = false
                    errorText = e.localizedDescription
                }
            }
        }
    }
}
