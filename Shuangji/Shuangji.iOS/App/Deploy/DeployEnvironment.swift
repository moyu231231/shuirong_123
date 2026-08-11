import Foundation
import Darwin

/// Dopamine 越狱检测 + 一键部署（工具 / 守护 / 可选 tweak）
enum DeployEnvironment {

    static let confDir = "/var/mobile/Library/Caches/com.shuiyong.ports"
    static let confPath = confDir + "/deploy.conf"
    static let statusHintPath = "/var/mobile/Library/Caches/sy_ports_status.txt"
    static let targetBundleHint = "com.tencent.tmgp.dfm"
    static let containsDefault = "tmgp.dfm"

    enum JBState: Equatable {
        case none
        case dopamineAppOnly
        case jailbroken(root: String)

        var label: String {
            switch self {
            case .none: return "未检测到越狱"
            case .dopamineAppOnly: return "已装 Dopamine，尚未越狱"
            case .jailbroken(let r):
                if r.contains(".jbroot") || r.contains("containers/Bundle") {
                    return "RootHide 已越狱"
                }
                return "已越狱（rootless）"
            }
        }

        var isJailbroken: Bool {
            if case .jailbroken = self { return true }
            return false
        }
    }

    enum DeployError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let s) = self { return s }
            return nil
        }
    }

    // MARK: - Preferences

    static var autoMempatch: Bool {
        get { UserDefaults.standard.object(forKey: "sy_auto_mempatch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sy_auto_mempatch") }
    }

    static var autoTweak: Bool {
        get { UserDefaults.standard.bool(forKey: "sy_auto_tweak") }
        set { UserDefaults.standard.set(newValue, forKey: "sy_auto_tweak") }
    }

    static var settleSeconds: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "sy_settle_sec")
            return v > 0 ? v : 55
        }
        set { UserDefaults.standard.set(newValue, forKey: "sy_settle_sec") }
    }

    // MARK: - Detect

    static func detect() -> JBState {
        if let root = JBRootFinder.findJBRoot() {
            return .jailbroken(root: root)
        }
        let apps = AppCatalog.load()
        if apps.contains(where: {
            $0.bundleID.localizedCaseInsensitiveContains("dopamine")
                || $0.bundleID.localizedCaseInsensitiveContains("roothide")
                || $0.bundleID == "com.opa334.Dopamine"
                || $0.name.localizedCaseInsensitiveContains("Dopamine")
                || $0.name.localizedCaseInsensitiveContains("RootHide")
        }) {
            return .dopamineAppOnly
        }
        return .none
    }

    /// 工具优先装到 mobile（RootHide/官方都可用），越狱根下再装一份
    static func installRoot(for state: JBState) -> String {
        if case .jailbroken(let jb) = state {
            return jb + "/usr/local/shuiyong"
        }
        return JBRootFinder.mobileFallback
    }

    static func tweakDirs(for state: JBState) -> [String] {
        guard state.isJailbroken else { return [] }
        return JBRootFinder.tweakDirs()
    }

    // MARK: - Bundled tools

    private static func toolURL(_ name: String) -> URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private static func syinject() throws -> URL {
        guard let sy = toolURL("syinject") else {
            throw DeployError.failed("缺少 syinject，请重装 tipa")
        }
        return sy
    }

    // MARK: - Deploy

    /// 写入 conf + 拷贝二进制 + 按开关装/卸 tweak + 拉起 sy_watch
    @discardableResult
    static func deploy(state: JBState) throws -> String {
        let sy = try syinject()
        let root = JBRootFinder.mobileFallback
        var log: [String] = []
        log.append("root=\(root)")
        log.append("jb=\(state.label)")

        try writeConf(root: root)
        log.append("conf OK")

        // 只装到 /var/mobile/Library/shuiyong（一次 installtools，避免几十次 spawn 卡住）
        var args: [String] = ["installtools", "--dst", root]
        let bins = ["sy_kpatch", "sy_mempatch", "sy_watch", "syinject"]
        var missingRequired = false
        for name in bins {
            guard let src = toolURL(name) else {
                if name == "sy_kpatch" || name == "sy_watch" {
                    missingRequired = true
                }
                continue
            }
            args.append(contentsOf: ["--src", src.path])
            log.append("+\(name)")
        }
        if missingRequired {
            throw DeployError.failed("缺少 sy_kpatch/sy_watch，请用新 tipa 打包")
        }
        let inst = SpawnUtil.rootRun(sy.path, args: args)
        if inst.code != 0 {
            // 旧 tipa 无 installtools：回退逐个 cp（仍可能慢，但能用）
            if inst.err.contains("unknown") || inst.out.contains("unknown") || inst.code == 1 {
                for name in bins {
                    guard let src = toolURL(name) else { continue }
                    let dst = "\(root)/\(name)"
                    _ = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", root])
                    _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", dst])
                    let r = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", src.path, "--dst", dst])
                    if r.code != 0 {
                        throw DeployError.failed("拷贝 \(name) 失败：\(r.err.isEmpty ? r.out : r.err)")
                    }
                }
                log.append("installtools fallback")
            } else {
                throw DeployError.failed("安装工具失败：\(inst.err.isEmpty ? inst.out : inst.err)")
            }
        }
        if JBRootFinder.isRootHideStyle {
            log.append("flavor=RootHide")
        }

        // 不写 LaunchDaemon：RootHide 上易卡；守护只靠 runbg
        log.append("LaunchDaemon skip")

        // tweak 失败不阻断部署（拷大 dylib / 扫目录很容易拖慢或超时）
        if autoTweak {
            if state.isJailbroken {
                do {
                    try enableTweak(sy: sy, state: state, log: &log)
                } catch {
                    log.append("tweak skip:\(error.localizedDescription)")
                }
            } else {
                log.append("tweak需越狱，已跳过")
            }
        } else {
            // 关开关时不扫全盘卸 tweak，避免慢
            log.append("tweak OFF(skip uninstall)")
        }

        try startWatch(sy: sy, root: root, log: &log)

        let summary = log.joined(separator: " | ")
        UserDefaults.standard.set(true, forKey: "sy_deployed_once")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "sy_deployed_at")
        return summary
    }

    static func stopWatch() {
        // 只杀 pidfile；禁止 killall（RootHide 上常永久挂起）
        let pidfile = confDir + "/sy_watch.pid"
        if let data = try? String(contentsOfFile: pidfile, encoding: .utf8),
           let pid = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            _ = SpawnUtil.rootRun("/bin/kill", args: ["-9", "\(pid)"])
        }
        try? FileManager.default.removeItem(atPath: pidfile)
        try? FileManager.default.removeItem(atPath: "\(JBRootFinder.mobileFallback)/sy_watch.pid")
    }

    static func startWatchOnly() throws -> String {
        let sy = try syinject()
        var log: [String] = []
        try writeConf(root: JBRootFinder.mobileFallback)
        try startWatch(sy: sy, root: JBRootFinder.mobileFallback, log: &log)
        return log.joined(separator: " | ")
    }

    // MARK: - Internals

    private static func writeConf(root: String) throws {
        let body = """
        auto_mempatch=\(autoMempatch ? 1 : 0)
        auto_tweak=\(autoTweak ? 1 : 0)
        settle=\(settleSeconds)
        contains=tmgp.dfm,DFM,dfm,DeltaForce,三角洲
        install_root=\(root)
        bundle=\(targetBundleHint)
        """
        let tmp = NSTemporaryDirectory() + "sy_deploy.conf"
        try body.write(toFile: tmp, atomically: true, encoding: .utf8)
        let sy = try syinject()
        _ = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", confDir])
        _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", confPath])
        let r = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", tmp, "--dst", confPath])
        if r.code != 0 {
            // 无 root 时直接写
            try? FileManager.default.createDirectory(atPath: confDir, withIntermediateDirectories: true)
            try body.write(toFile: confPath, atomically: true, encoding: .utf8)
        }
    }

    private static func installLaunchDaemon(sy: URL, root: String, log: inout [String]) throws {
        guard let plistDir = JBRootFinder.launchDaemonDir() else {
            log.append("LaunchDaemon skip(no jbroot)")
            return
        }
        // RootHide 下 LaunchDaemon 可能不稳定；仍写入，失败不阻断
        let watchBin = JBRootFinder.mobileFallback + "/sy_watch"
        _ = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", plistDir])
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.shuiyong.sywatch</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(watchBin)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>UserName</key>
            <string>root</string>
        </dict>
        </plist>
        """
        let tmp = NSTemporaryDirectory() + "com.shuiyong.sywatch.plist"
        try plist.write(toFile: tmp, atomically: true, encoding: .utf8)
        let dst = plistDir + "/com.shuiyong.sywatch.plist"
        _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", dst])
        let r = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", tmp, "--dst", dst])
        if r.code == 0 {
            log.append("LaunchDaemon plist OK")
            // 不在此 launchctl load：RootHide 上易卡住；守护靠 runbg 拉起
        } else {
            log.append("LaunchDaemon skip")
        }
    }

    private static func enableTweak(sy: URL, state: JBState, log: inout [String]) throws {
        guard let dylib = bundledSpoofDylib() else {
            throw DeployError.failed("缺少 ShuiyongSpoof.dylib / sy_ports.dylib")
        }
        guard let filter = bundledSpoofPlist() else {
            throw DeployError.failed("缺少 ShuiyongSpoof.plist")
        }
        // 最多试 2 个目录，避免 RootHide 扫盘拖死
        let dirs = Array(tweakDirs(for: state).prefix(2))
        guard let dir = dirs.first(where: { candidate in
            let r = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", candidate])
            return r.code == 0 || FileManager.default.fileExists(atPath: candidate)
        }) ?? dirs.first else {
            throw DeployError.failed("无 tweak 目录")
        }
        _ = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", dir])
        let dDst = "\(dir)/ShuiyongSpoof.dylib"
        let pDst = "\(dir)/ShuiyongSpoof.plist"
        _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", dDst])
        _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", pDst])
        var r = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", dylib.path, "--dst", dDst])
        if r.code != 0 {
            throw DeployError.failed("安装 tweak dylib 失败")
        }
        r = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", filter.path, "--dst", pDst])
        if r.code != 0 {
            throw DeployError.failed("安装 tweak plist 失败")
        }
        log.append("tweak ON → \(dir)")
    }

    private static func disableTweak(sy: URL, state: JBState, log: inout [String]) throws {
        for dir in tweakDirs(for: state) {
            _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", "\(dir)/ShuiyongSpoof.dylib"])
            _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", "\(dir)/ShuiyongSpoof.plist"])
        }
        log.append("tweak OFF")
    }

    private static func startWatch(sy: URL, root: String, log: inout [String]) throws {
        stopWatch()
        Thread.sleep(forTimeInterval: 0.2)
        let bin = "\(root)/sy_watch"
        if !FileManager.default.fileExists(atPath: bin) {
            if let src = toolURL("sy_watch") {
                _ = SpawnUtil.rootRun(sy.path, args: [
                    "installtools", "--dst", root, "--src", src.path
                ])
            }
        }
        try? FileManager.default.removeItem(
            atPath: "/var/mobile/Library/Caches/sy_watch_heartbeat.txt"
        )

        // 只走 runbg，禁止再用 rootRun 直接跑 sy_watch（管道会死等）
        let bg = SpawnUtil.rootRun(sy.path, args: [
            "runbg", "--bin", bin, "--arg", "--fg"
        ])
        let childPid = Int(bg.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        log.append("runbg pid=\(childPid) code=\(bg.code)")

        // 最多约 1 秒等心跳；没有也不阻断部署
        var alive = false
        let hb = "/var/mobile/Library/Caches/sy_watch_heartbeat.txt"
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.25)
            if let s = try? String(contentsOfFile: hb, encoding: .utf8), s.contains("alive=1") {
                alive = true
                break
            }
        }

        let stamp: String
        if alive {
            log.append("watch heartbeat OK")
            stamp = "WAIT sy_watch armed time=\(Int(Date().timeIntervalSince1970))"
        } else {
            log.append("watch no heartbeat(non-fatal)")
            stamp = "WAIT deploy_ok watch_pending time=\(Int(Date().timeIntervalSince1970))"
        }
        let tmp = NSTemporaryDirectory() + "sy_ports_status.txt"
        try? stamp.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", tmp, "--dst", statusHintPath])
    }

    /// 若游戏已在跑：立刻 settle 较短后补丁一次（不依赖守护）
    @discardableResult
    static func patchNow(settleSeconds: Int = 12) throws -> String {
        let sy = try syinject()
        let mp = toolURL("sy_kpatch") ?? toolURL("sy_mempatch")
        guard let mp else { throw DeployError.failed("缺少 sy_kpatch") }

        let needles = ["tmgp.dfm", "DFM", "dfm", "DeltaForce", "三角洲"]
        var pid = 0
        for n in needles {
            let pr = SpawnUtil.rootRun(sy.path, args: ["pid", "--contains", n])
            if pr.code == 0,
               let v = Int(pr.out.trimmingCharacters(in: .whitespacesAndNewlines)), v > 1 {
                pid = v
                break
            }
        }
        guard pid > 1 else {
            throw DeployError.failed("未找到游戏进程。请先打开三角洲再点「立即补丁」。")
        }

        // 写 WAIT，保证内存页时间更新
        let wait = "WAIT manual_settle pid=\(pid) sec=\(settleSeconds) time=\(Int(Date().timeIntervalSince1970))"
        let tmp = NSTemporaryDirectory() + "sy_ports_status.txt"
        try wait.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", tmp, "--dst", statusHintPath])

        Thread.sleep(forTimeInterval: TimeInterval(max(5, settleSeconds)))
        let r = SpawnUtil.rootRun(mp.path, args: ["\(pid)"])
        let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code != 0 {
            throw DeployError.failed("补丁失败 pid=\(pid)：\(msg.isEmpty ? "exit \(r.code)" : msg)")
        }
        return msg.isEmpty ? "OK pid=\(pid)" : msg
    }

    private static func bundledSpoofDylib() -> URL? {
        let names = ["ShuiyongSpoof.dylib", "sy_ports.dylib", "ShuiyongMem.dylib"]
        for n in names {
            let u = Bundle.main.bundleURL.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { return u }
            let d = Bundle.main.bundleURL.appendingPathComponent("Deploy/\(n)")
            if FileManager.default.fileExists(atPath: d.path) { return d }
        }
        return nil
    }

    private static func bundledSpoofPlist() -> URL? {
        let cands = [
            Bundle.main.bundleURL.appendingPathComponent("Deploy/ShuiyongSpoof.plist"),
            Bundle.main.bundleURL.appendingPathComponent("ShuiyongSpoof.plist"),
            Bundle.main.url(forResource: "ShuiyongSpoof", withExtension: "plist")
        ].compactMap { $0 }
        return cands.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
