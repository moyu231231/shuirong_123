import Foundation
import UIKit

/// 把官方 Dopamine 越狱引擎嵌进水溶C流程：内置 tipa → TrollStore 安装 → 打开 Dopamine → 等待 /var/jb → 自动部署补丁环境
enum JailbreakOrchestrator {

    static let dopamineBundleIDs = [
        "com.opa334.Dopamine",
        "com.opa334.Dopamine.RootHide"
    ]
    /// 打包时写入；运行时也可从 GitHub 拉取
    static let dopamineReleaseTipaURL =
        "https://github.com/opa334/Dopamine/releases/download/3.0.4/Dopamine.tipa"

    enum Phase: String {
        case idle
        case preparing
        case installingDopamine
        case waitingJailbreak
        case deploying
        case done
        case failed
    }

    struct Progress {
        var phase: Phase
        var detail: String
    }

    enum OrchError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let s) = self { return s }
            return nil
        }
    }

    /// 一键：越狱（若需要）+ 部署 sy_kpatch/sy_watch
    static func oneClick(progress: @escaping (Progress) -> Void) throws -> String {
        func report(_ phase: Phase, _ detail: String) {
            progress(Progress(phase: phase, detail: detail))
        }

        report(.preparing, "检测环境…")
        var state = DeployEnvironment.detect()
        if state.isJailbroken {
            report(.deploying, "已越狱，开始部署补丁环境…")
            let s = try DeployEnvironment.deploy(state: state)
            report(.done, s)
            return "已越狱 → " + s
        }

        // 1) 确保 Dopamine 已安装
        if case .none = state {
            report(.installingDopamine, "准备安装内置 Dopamine…")
            try ensureDopamineInstalled(progress: report)
            // 装完后重新检测
            for _ in 0..<90 {
                Thread.sleep(forTimeInterval: 2)
                state = DeployEnvironment.detect()
                if state != .none { break }
                report(.installingDopamine, "等待 TrollStore 完成安装 Dopamine…")
            }
            state = DeployEnvironment.detect()
            if case .none = state {
                throw OrchError.failed(
                    "未检测到 Dopamine。请确认 TrollStore 已开启 URL Scheme，并在弹窗中点安装。也可手动用 TrollStore 安装 App 内 Dopamine.tipa 后重试。"
                )
            }
        }

        // 2) 打开 Dopamine，等用户点 Jailbreak（内核利用必须在其进程内完成）
        if !state.isJailbroken {
            report(.waitingJailbreak, "正在打开 Dopamine，请在其中点 Jailbreak…")
            openDopamine()
            let deadline = Date().addingTimeInterval(10 * 60)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 3)
                state = DeployEnvironment.detect()
                if state.isJailbroken { break }
                let left = Int(deadline.timeIntervalSinceNow)
                report(.waitingJailbreak, "等待越狱完成（剩余约 \(max(0, left))s）…请在 Dopamine 内点 Jailbreak")
            }
            state = DeployEnvironment.detect()
            if !state.isJailbroken {
                throw OrchError.failed(
                    "超时未检测到 /var/jb。请在 Dopamine 内成功 Jailbreak 后，回到水溶C再点一次「一键越狱并部署」。"
                )
            }
        }

        report(.deploying, "越狱成功，部署补丁环境…")
        let summary = try DeployEnvironment.deploy(state: state)
        report(.done, summary)
        return "越狱OK → " + summary
    }

    // MARK: - Install Dopamine

    private static func ensureDopamineInstalled(progress: @escaping (Phase, String) -> Void) throws {
        let tipa = try resolveTipaURL()
        progress(.installingDopamine, "启动本地分发并唤起 TrollStore…")

        let server = TinyHTTPServer(fileURL: tipa, port: 18473)
        try server.start()
        defer { server.stop() }

        guard let httpURL = server.baseURL else {
            throw OrchError.failed("本地 HTTP 未就绪")
        }

        // 给 listener 一点时间
        Thread.sleep(forTimeInterval: 0.4)

        let encoded = httpURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? httpURL.absoluteString
        let scheme = "apple-magnifier://install?url=\(encoded)"
        guard let installURL = URL(string: scheme) else {
            throw OrchError.failed("无法构造 TrollStore 安装 URL")
        }

        var opened = false
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            UIApplication.shared.open(installURL, options: [:]) { ok in
                opened = ok
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 8)
        if !opened {
            // 兜底：导出 tipa 路径提示
            let export = exportTipaToDocuments(tipa)
            throw OrchError.failed(
                "无法唤起 TrollStore URL Scheme。请到 TrollStore 设置开启 URL Scheme 并 Rebuild Icon Cache。\n也可手动安装：\(export?.path ?? tipa.path)"
            )
        }

        // 保持 HTTP 一段时间供 TrollStore 下载
        progress(.installingDopamine, "TrollStore 拉取中，请确认安装…")
        Thread.sleep(forTimeInterval: 45)
    }

    private static func resolveTipaURL() throws -> URL {
        let bundled = [
            Bundle.main.url(forResource: "Dopamine", withExtension: "tipa"),
            Bundle.main.bundleURL.appendingPathComponent("Dopamine.tipa"),
            Bundle.main.bundleURL.appendingPathComponent("Deploy/Dopamine.tipa")
        ].compactMap { $0 }
        if let u = bundled.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return u
        }

        // 运行时下载到 Caches
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Dopamine.tipa")
        if FileManager.default.fileExists(atPath: dest.path),
           (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0 > 1_000_000 {
            return dest
        }
        guard let remote = URL(string: dopamineReleaseTipaURL) else {
            throw OrchError.failed("无效的 Dopamine 下载地址")
        }
        let data: Data
        do {
            data = try Data(contentsOf: remote)
        } catch {
            throw OrchError.failed("下载 Dopamine.tipa 失败：\(error.localizedDescription)。请检查网络或重新打包内置 tipa。")
        }
        try data.write(to: dest, options: .atomic)
        return dest
    }

    private static func exportTipaToDocuments(_ tipa: URL) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dest = docs.appendingPathComponent("Dopamine.tipa")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: tipa, to: dest)
        return dest
    }

    private static func openDopamine() {
        for bid in dopamineBundleIDs {
            if SYOpenApplicationWithBundleID(bid) { return }
        }
        // 再扫一遍已装列表
        let apps = AppCatalog.load()
        if let app = apps.first(where: {
            $0.bundleID.localizedCaseInsensitiveContains("dopamine")
        }) {
            _ = SYOpenApplicationWithBundleID(app.bundleID)
        }
    }

    static var hasBundledDopamine: Bool {
        let cands = [
            Bundle.main.url(forResource: "Dopamine", withExtension: "tipa"),
            Bundle.main.bundleURL.appendingPathComponent("Dopamine.tipa"),
            Bundle.main.bundleURL.appendingPathComponent("Deploy/Dopamine.tipa")
        ].compactMap { $0 }
        return cands.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
