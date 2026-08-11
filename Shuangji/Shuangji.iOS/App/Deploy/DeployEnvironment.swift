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
        let root = installRoot(for: state)
        var log: [String] = []
        log.append("root=\(root)")
        log.append("jb=\(state.label)")

        try writeConf(root: root)
        log.append("conf OK")

        // 始终装到 mobile（RootHide 无 /var/jb 时也能跑）；越狱根再备份一份
        let installRoots = JBRootFinder.toolInstallRoots()
        for ir in installRoots {
            _ = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", ir])
        }
        _ = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", confDir])

        let bins = ["sy_kpatch", "sy_mempatch", "sy_watch", "syinject"]
        for name in bins {
            guard let src = toolURL(name) else {
                if name == "sy_kpatch" || name == "sy_watch" {
                    throw DeployError.failed("缺少 \(name)，请用新 tipa 打包")
                }
                continue
            }
            for ir in installRoots {
                let dst = "\(ir)/\(name)"
                _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", dst])
                let r = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", src.path, "--dst", dst])
                if r.code != 0 && ir == JBRootFinder.mobileFallback {
                    throw DeployError.failed("拷贝 \(name) 失败：\(r.err.isEmpty ? r.out : r.err)")
                }
                _ = SpawnUtil.rootRun(sy.path, args: ["chmod", "--path", dst, "--mode", "0755"])
            }
            log.append("+\(name)")
        }
        log.append("paths=\(installRoots.joined(separator: ","))")
        if JBRootFinder.isRootHideStyle {
            log.append("flavor=RootHide")
        }

        // LaunchDaemon plist（越狱态）
        if state.isJailbroken {
            try installLaunchDaemon(sy: sy, root: root, log: &log)
        }

        if autoTweak {
            if state.isJailbroken {
                try enableTweak(sy: sy, state: state, log: &log)
            } else {
                try disableTweak(sy: sy, state: state, log: &log)
                log.append("tweak需越狱，已跳过")
            }
        } else {
            try disableTweak(sy: sy, state: state, log: &log)
        }

        // 拉起守护：永远从 mobile 路径起（RootHide 兼容）
        try startWatch(sy: sy, root: JBRootFinder.mobileFallback, log: &log)

        let summary = log.joined(separator: " | ")
        UserDefaults.standard.set(true, forKey: "sy_deployed_once")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "sy_deployed_at")
        return summary
    }

    static func stopWatch() {
        guard let sy = try? syinject() else { return }
        let pidfile = confDir + "/sy_watch.pid"
        if let data = try? String(contentsOfFile: pidfile, encoding: .utf8),
           let pid = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            _ = SpawnUtil.rootRun("/bin/kill", args: ["-9", "\(pid)"])
        }
        for r in JBRootFinder.toolInstallRoots() {
            _ = SpawnUtil.rootRun(sy.path, args: ["rm", "--path", "\(r)/sy_watch.pid"])
        }
        _ = SpawnUtil.rootRun("/usr/bin/killall", args: ["-9", "sy_watch"])
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
            log.append("LaunchDaemon OK")
            _ = SpawnUtil.rootRun("/bin/launchctl", args: ["unload", dst])
            _ = SpawnUtil.rootRun("/bin/launchctl", args: ["load", dst])
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
        let dirs = tweakDirs(for: state)
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
        Thread.sleep(forTimeInterval: 0.4)
        let bin = "\(root)/sy_watch"
        let ex = SpawnUtil.rootRun(sy.path, args: ["exists", "--path", bin])
        if ex.code != 0 && !FileManager.default.fileExists(atPath: bin) {
            // 尝试从 App 包再拷一次
            if let src = toolURL("sy_watch") {
                _ = SpawnUtil.rootRun(sy.path, args: ["mkdir", "--path", root])
                _ = SpawnUtil.rootRun(sy.path, args: ["cp", "--src", src.path, "--dst", bin])
            }
        }
        // 强制可执行（旧 tipa 拷出来可能是 0644）
        _ = SpawnUtil.rootRun(sy.path, args: ["chmod", "--path", bin, "--mode", "0755"])
        for name in ["sy_kpatch", "sy_mempatch", "syinject"] {
            _ = SpawnUtil.rootRun(sy.path, args: [
                "chmod", "--path", "\(root)/\(name)", "--mode", "0755"
            ])
        }

        // 清旧心跳，避免误判
        _ = SpawnUtil.rootRun(sy.path, args: [
            "rm", "--path", "/var/mobile/Library/Caches/sy_watch_heartbeat.txt"
        ])

        // 用 syinject runbg 后台拉起 --fg（不依赖 daemonize，也不堵管道）
        let bg = SpawnUtil.rootRun(sy.path, args: [
            "runbg", "--bin", bin, "--arg", "--fg"
        ])
        let childPid = Int(bg.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        log.append("runbg pid=\(childPid) code=\(bg.code)")

        // 等心跳最多 5 秒
        var alive = false
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            let heart = SpawnUtil.rootRun(sy.path, args: [
                "cat", "--path", "/var/mobile/Library/Caches/sy_watch_heartbeat.txt"
            ])
            if heart.out.contains("alive=1") {
                alive = true
                break
            }
        }
        if !alive {
            // 再试直接 spawn daemon 模式
            _ = SpawnUtil.rootRun(bin, args: [])
            Thread.sleep(forTimeInterval: 1.0)
            let heart2 = SpawnUtil.rootRun(sy.path, args: [
                "cat", "--path", "/var/mobile/Library/Caches/sy_watch_heartbeat.txt"
            ])
            alive = heart2.out.contains("alive=1")
        }
        if !alive {
            throw DeployError.failed(
                "sy_watch 仍无心跳。请重新「一键部署」后再试。log: \(bg.err.isEmpty ? bg.out : bg.err)"
            )
        }
        log.append("watch heartbeat OK")

        let stamp = "WAIT sy_watch restarted time=\(Int(Date().timeIntervalSince1970))"
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
