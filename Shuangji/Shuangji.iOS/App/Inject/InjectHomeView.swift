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

    var filtered: [AppEntry] {
        apps.filter { app in
            if scope == 1 && !app.isUser { return false }
            if scope == 2 && !(app.isInjected || BuiltinInjector.isRuntimeMarked(app.bundleID)) {
                return false
            }
            if filter.isEmpty { return true }
            return app.name.localizedCaseInsensitiveContains(filter)
                || app.bundleID.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Text("推荐：内存补丁（纯 mempatch，无注入）· 可先清理设备标识")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 6)

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
                        Text("请用 TrollStore 重新安装本 tipa。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { app in
                            HStack(spacing: 10) {
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
                                        Text("磁盘注入(易被扫)")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    } else if BuiltinInjector.isRuntimeMarked(app.bundleID) {
                                        Text("曾内存补丁/注入")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                    }
                                }
                                Spacer()
                                if busyID == app.bundleID {
                                    ProgressView()
                                } else {
                                    Menu {
                                        Button("清理设备标识") { cleanDeviceIDs(app) }
                                        Button("内存补丁（稳态·无注入）") { memPatch(app) }
                                        Button("打开游戏") { launch(app.bundleID) }
                                        if app.isInjected {
                                            Button("清磁盘残留", role: .destructive) { eject(app) }
                                        }
                                    } label: {
                                        Text("操作")
                                            .font(.subheadline.weight(.semibold))
                                    }
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
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMsg)
            }
        }
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

    private func memPatch(_ app: AppEntry) {
        busyID = app.bundleID
        banner = "纯内存补丁：启动 → 等 tersafe → sy_mempatch（无注入）…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BuiltinInjector.memPatch(into: app, settleSeconds: 55)
                DispatchQueue.main.async {
                    busyID = nil
                    banner = "内存补丁完成 pid=\(BuiltinInjector.lastRuntimePID)"
                    alertTitle = "内存补丁成功"
                    alertMsg = "\(BuiltinInjector.lastTargetPath)\n\n仅 DATA 门闩 + GOT，未注入 dylib。\n到「内存」页检查状态。\n还须：修改模式 + 小火箭走网关。"
                    showAlert = true
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busyID = nil
                    banner = error.localizedDescription
                    alertTitle = "内存补丁失败"
                    alertMsg = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func cleanDeviceIDs(_ app: AppEntry) {
        busyID = app.bundleID
        banner = "清理 ACE/TSS 设备标识缓存…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let out = try BuiltinInjector.cleanDeviceIDs(of: app)
                DispatchQueue.main.async {
                    busyID = nil
                    banner = "设备标识已清理"
                    alertTitle = "清理完成"
                    alertMsg = "\(out)\n\n已删沙盒内 TssSDK/IDFV/tersafe 等相关缓存。\n建议再点「内存补丁」后进游戏。"
                    showAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    busyID = nil
                    banner = error.localizedDescription
                    alertTitle = "清理失败"
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
                    banner = "已清磁盘残留"
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
