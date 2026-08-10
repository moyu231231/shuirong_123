import SwiftUI

struct LoginView: View {
    var onSuccess: () -> Void

    @State private var cfg = AppConfig.load()
    @State private var busy = false
    @State private var errorText = ""
    @State private var hubOK: Bool?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("账号中枢"), footer: Text("使用中枢开好的用户名/密码登录后才能使用本软件。")) {
                    TextField("中枢地址", text: $cfg.accountHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("端口", value: $cfg.accountPort, format: .number)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $cfg.userName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $cfg.password)
                    if let hubOK {
                        Text(hubOK ? "中枢可达" : "中枢不可达")
                            .font(.caption)
                            .foregroundColor(hubOK ? .green : .red)
                    }
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
            .navigationTitle("水溶C 登录")
            .onAppear { ping() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func ping() {
        AccountHubAPI.ping(host: cfg.accountHost, port: cfg.accountPort) { ok in
            DispatchQueue.main.async { hubOK = ok }
        }
    }

    private func login() {
        busy = true
        errorText = ""
        cfg.save()
        AccountHubAPI.auth(host: cfg.accountHost, port: cfg.accountPort,
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
