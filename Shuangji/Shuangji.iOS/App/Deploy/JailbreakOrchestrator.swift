import Foundation
import UIKit

/// 把 Dopamine / RootHide Dopamine 嵌进水溶C：内置 tipa → TrollStore → 打开越狱 App → 等 jbroot → 自动部署
enum JailbreakOrchestrator {

    static let dopamineBundleIDs = [
        "com.opa334.Dopamine",
        "com.opa334.Dopamine.RootHide",
        "com.roothide.Dopamine",
        "com.roothide.manager"
    ]

    static let stockDopamineTipaURL =
        "https://github.com/opa334/Dopamine/releases/download/3.0.4/Dopamine.tipa"
    static let rootHideDopamineTipaURL =
        "https://github.com/roothide/Dopamine2-roothide/releases/download/25/Dopamine.tipa"

    /// 0=RootHide（推荐打三角洲） 1=官方 Dopamine
    static var preferredFlavor: Int {
        get {
            if UserDefaults.standard.object(forKey: "sy_jb_flavor") == nil { return 0 }
            return UserDefaults.standard.integer(forKey: "sy_jb_flavor")
        }
        set { UserDefaults.standard.set(newValue, forKey: "sy_jb_flavor") }
    }

    static var activeTipaURL: String {
        preferredFlavor == 0 ? rootHideDopamineTipaURL : stockDopamineTipaURL
    }

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

        report(.preparing, "检测环境（含 RootHide jbroot）…")
        var state = DeployEnvironment.detect()
        if state.isJailbroken {
            report(.deploying, "已越狱，开始部署补丁环境…")
            let s = try DeployEnvironment.deploy(state: state)
            report(.done, s)
            return "已越狱 → " + s
        }

        if case .none = state {
            report(.installingDopamine, preferredFlavor == 0
                   ? "准备安装 RootHide Dopamine…"
                   : "准备安装官方 Dopamine…")
            try ensureDopamineInstalled(progress: report)
            for _ in 0..<90 {
                Thread.sleep(forTimeInterval: 2)
                state = DeployEnvironment.detect()
                if state != .none { break }
                report(.installingDopamine, "等待 TrollStore 完成安装…")
            }
            state = DeployEnvironment.detect()
            if case .none = state {
                throw OrchError.failed(
                    "未检测到 Dopamine。请确认 TrollStore 已开启 URL Scheme。RootHide 用户请装 Dopamine2-roothide tipa。"
                )
            }
        }

        if !state.isJailbroken {
            report(.waitingJailbreak, "打开 Dopamine，请点 Jailbreak…")
            openDopamine()
            let deadline = Date().addingTimeInterval(10 * 60)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 3)
                state = DeployEnvironment.detect()
                if state.isJailbroken { break }
                let left = Int(deadline.timeIntervalSinceNow)
                report(.waitingJailbreak,
                       "等待 jbroot（剩余约 \(max(0, left))s）。RootHide 无 /var/jb，靠扫描 .jbroot-*")
            }
            state = DeployEnvironment.detect()
            if !state.isJailbroken {
                throw OrchError.failed(
                    "超时未检测到越狱根。RootHide 成功后应有 .jbroot-*。请确认 Jailbreak 成功后再点一次。"
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
        guard let remote = URL(string: activeTipaURL) else {
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
        let apps = AppCatalog.load()
        if let app = apps.first(where: {
            $0.bundleID.localizedCaseInsensitiveContains("dopamine")
                || $0.name.localizedCaseInsensitiveContains("Dopamine")
                || $0.name.localizedCaseInsensitiveContains("RootHide")
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
