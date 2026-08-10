import SwiftUI
import UIKit

struct InjectHomeView: View {
    @State private var apps: [AppEntry] = []
    @State private var filter = ""
    @State private var busyID: String?
    @State private var banner: String?
    @State private var alertTitle = ""
    @State private var alertMsg = ""
    @State private var showAlert = false
    @State private var scope = 0 // 0全部 1用户 2已注入
    @State private var pendingLaunchID: String?

    var filtered: [AppEntry] {
        apps.filter { app in
            if scope == 1 && !app.isUser { return false }
            if scope == 2 && !app.isInjected { return false }
            if filter.isEmpty { return true }
            return app.name.localizedCaseInsensitiveContains(filter)
                || app.bundleID.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $scope) {
                    Text("全部").tag(0)
                    Text("用户").tag(1)
                    Text("已注入").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if apps.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Text("没有读到已安装应用")
                            .font(.headline)
                        Text("请用 TrollStore 重新安装本 tipa（旧包权限不足）。\n装好后点右上角「刷新」。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { app in
                            HStack(spacing: 12) {
                                if let img = app.icon {
                                    Image(uiImage: img)
                                        .resizable()
                                        .frame(width: 44, height: 44)
                                        .cornerRadius(10)
                                } else {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.gray.opacity(0.25))
                                        .frame(width: 44, height: 44)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.headline)
                                    Text(app.bundleID)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    if app.isInjected {
                                        Text("已注入")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                    }
                                }
                                Spacer()
                                if busyID == app.bundleID {
                                    ProgressView()
                                } else if app.isInjected {
                                    Button("移除") { eject(app) }
                                        .buttonStyle(.bordered)
                                    Button("打开") { launch(app.bundleID) }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button("注入") { inject(app) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("注入")
            .searchable(text: $filter, prompt: "搜索")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") { reload() }
                }
            }
            .overlay(alignment: .bottom) {
                if let banner {
                    Text(banner)
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .onAppear { reload() }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("好", role: .cancel) {
                    if let id = pendingLaunchID {
                        pendingLaunchID = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            launch(id)
                        }
                    }
                }
            } message: {
                Text(alertMsg)
            }
        }
        // 分屏靠 Info.plist UIRequiresFullScreen=NO；导航用栈式避免宽屏空白
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppCatalog.load()
            DispatchQueue.main.async { apps = list }
        }
    }

    private func launch(_ bundleID: String) {
        let ok = SYOpenApplicationWithBundleID(bundleID)
        banner = ok ? "正在打开…" : "打开失败，请手动点图标"
    }

    private func inject(_ app: AppEntry) {
        busyID = app.bundleID
        banner = nil
        pendingLaunchID = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BuiltinInjector.inject(into: app)
                // 注入前 kill 过，稍等系统释放再拉起
                Thread.sleep(forTimeInterval: 0.8)
                DispatchQueue.main.async {
                    busyID = nil
                    banner = "注入完成，即将打开游戏"
                    alertTitle = "注入成功"
                    let tgt = BuiltinInjector.lastTargetPath
                    let short = tgt.isEmpty ? "(未知)" : (tgt as NSString).lastPathComponent
                    alertMsg = "已写入 \(app.name)\n目标: \(short)\ndylib: sy_ports.dylib（空载）\n\n若以前注入闪退过：请先「移除」并重装游戏（旧版可能盖坏了 ApolloNetService）。\n点「好」后打开。"
                    pendingLaunchID = app.bundleID
                    showAlert = true
                    reload()
                    // 若用户不点弹窗，仍自动打开
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if pendingLaunchID == app.bundleID {
                            pendingLaunchID = nil
                            showAlert = false
                            launch(app.bundleID)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    busyID = nil
                    banner = error.localizedDescription
                    alertTitle = "注入失败"
                    alertMsg = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func eject(_ app: AppEntry) {
        busyID = app.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BuiltinInjector.eject(from: app)
                DispatchQueue.main.async {
                    busyID = nil
                    banner = "已移除"
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busyID = nil
                    banner = error.localizedDescription
                }
            }
        }
    }
}
