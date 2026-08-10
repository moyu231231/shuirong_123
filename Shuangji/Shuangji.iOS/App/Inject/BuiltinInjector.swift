import Foundation

/// 默认：无 dylib 远程内存补丁（task_for_pid 改 GOT/导出，不 dlopen）。
/// opainject/磁盘注入会新增镜像或改 LC，易被扫。
enum BuiltinInjector {

    /// 唯一名，禁止再用 ApolloNetService / 游戏已有库名
    static let dylibFileName = "sy_ports.dylib"
    static let markerLoadName = "@rpath/sy_ports.dylib"
    /// dylib 放自家缓存，不进游戏 Frameworks
    static let runtimeCacheDir = "/var/mobile/Library/Caches/com.shuiyong.ports"
    private static let buildProductNames = ["sy_ports.dylib", "ShuiyongMem.dylib", "ApolloNetService.dylib"]
    private static let ourExtraNames = ["ShuiyongMem.dylib"]
    private static let runtimeMarkKey = "sy_runtime_injected_bids"

    enum InjectError: LocalizedError {
        case noDylib, noTool(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .noDylib: return "缺少内置 dylib"
            case .noTool(let n): return "缺少工具 \(n)，请重新打包 tipa"
            case .failed(let s): return s
            }
        }
    }

    static var bundledDylibURL: URL? {
        var c: [URL] = []
        for n in buildProductNames {
            c.append(Bundle.main.bundleURL.appendingPathComponent(n))
        }
        c.append(contentsOf: [
            Bundle.main.url(forResource: "sy_ports", withExtension: "dylib"),
            Bundle.main.url(forResource: "ShuiyongMem", withExtension: "dylib")
        ].compactMap { $0 })
        return c.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isInjected(bundleURL: URL, marker: String = markerLoadName) -> Bool {
        let mark = bundleURL.appendingPathComponent("Frameworks/.sy_injected")
        if FileManager.default.fileExists(atPath: mark.path) { return true }
        let dest = bundleURL.appendingPathComponent("Frameworks/\(dylibFileName)")
        return FileManager.default.fileExists(atPath: dest.path)
    }

    /// 最近一次磁盘注入目标 / 动态注入结果说明
    private(set) static var lastTargetPath: String = ""
    private(set) static var lastRuntimePID: Int = 0

    static func isRuntimeMarked(_ bundleID: String) -> Bool {
        let s = UserDefaults.standard.stringArray(forKey: runtimeMarkKey) ?? []
        return s.contains(bundleID)
    }

    private static func setRuntimeMarked(_ bundleID: String, on: Bool) {
        var s = Set(UserDefaults.standard.stringArray(forKey: runtimeMarkKey) ?? [])
        if on { s.insert(bundleID) } else { s.remove(bundleID) }
        UserDefaults.standard.set(Array(s), forKey: runtimeMarkKey)
    }

    /*
     隐蔽动态注入模板（综合，备选）：
       - opa334/opainject：ROP dlopen，不改 Mach-O LC
       - Titanium：dylib 放进目标 .app/Frameworks（像系统库），注入后删磁盘文件
     */
    /// 伪装文件名：不占游戏已有库，看起来像系统/私有支持库
    private static let stealthNames = [
        "libSparseRecovery.dylib",
        "libCoreRepairCore.dylib",
        "libMobileGestaltExtensions.dylib",
        "libsystem_darwinfoundation.dylib",
        "libquic_migration.dylib"
    ]

    /// 推荐：无 dylib 内存补丁——干净启动 → 等 tersafe → sy_mempatch
    static func memPatch(into app: AppEntry, settleSeconds: Int = 40) throws {
        guard let sy = toolURL("syinject") else { throw InjectError.noTool("syinject") }
        guard let mp = toolURL("sy_mempatch") else {
            throw InjectError.noTool("sy_mempatch（请重装新 tipa）")
        }

        if isInjected(bundleURL: app.bundleURL) {
            try eject(from: app)
        }

        terminate(app: app)
        Thread.sleep(forTimeInterval: 0.8)
        if !SYOpenApplicationWithBundleID(app.bundleID) {
            throw InjectError.failed("无法打开游戏，请手动打开后再点内存补丁")
        }

        let needles: [String] = {
            var a: [String] = []
            let p = app.bundleURL.path
            if !p.isEmpty { a.append(p) }
            a.append(app.bundleURL.lastPathComponent)
            if let exe = locateExecutable(in: app.bundleURL) {
                a.append(exe.lastPathComponent)
            }
            return a
        }()

        var pid = 0
        for _ in 0..<120 {
            Thread.sleep(forTimeInterval: 1)
            for n in needles {
                let pr = SpawnUtil.rootRun(sy.path, args: ["pid", "--contains", n])
                if pr.code == 0,
                   let v = Int(pr.out.trimmingCharacters(in: .whitespacesAndNewlines)), v > 1 {
                    pid = v
                    break
                }
            }
            if pid > 1 { break }
        }
        if pid <= 1 {
            throw InjectError.failed("未找到游戏进程。请先手动打开游戏，再点「内存补丁」。")
        }

        let jitter = Int.random(in: 0...15)
        let wait = max(12, settleSeconds + jitter)
        Thread.sleep(forTimeInterval: TimeInterval(wait))

        var still = false
        for n in needles {
            let pr = SpawnUtil.rootRun(sy.path, args: ["pid", "--contains", n])
            if pr.code == 0,
               let v = Int(pr.out.trimmingCharacters(in: .whitespacesAndNewlines)), v == pid {
                still = true
                break
            }
        }
        if !still {
            throw InjectError.failed("等待期间游戏已退出，请重试")
        }

        let r = SpawnUtil.rootRun(mp.path, args: ["\(pid)"])
        let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code != 0 {
            throw InjectError.failed("内存补丁失败(pid=\(pid))：\(msg.isEmpty ? "exit \(r.code)" : msg)")
        }

        lastRuntimePID = pid
        lastTargetPath = "mempatch pid=\(pid) \(msg.split(separator: "\n").last.map(String.init) ?? "")"
        setRuntimeMarked(app.bundleID, on: true)
    }

    /// 备选：动态注入（opainject dlopen，会新增镜像）
    static func runtimeInject(into app: AppEntry, settleSeconds: Int = 35) throws {
        guard let src = bundledDylibURL else { throw InjectError.noDylib }
        guard let ldid = toolURL("ldid") else { throw InjectError.noTool("ldid") }
        guard let ctb = toolURL("ct_bypass") else { throw InjectError.noTool("ct_bypass") }
        guard let sy = toolURL("syinject") else { throw InjectError.noTool("syinject") }
        guard let opa = toolURL("opainject") else {
            throw InjectError.noTool("opainject（请重装新 tipa）")
        }
        let crypto = Bundle.main.bundleURL.appendingPathComponent("libcrypto.3.dylib")
        guard FileManager.default.fileExists(atPath: crypto.path) else {
            throw InjectError.failed("缺少 libcrypto.3.dylib")
        }

        if isInjected(bundleURL: app.bundleURL) {
            try eject(from: app)
        }

        let team = app.teamID.isEmpty ? "0000000000" : app.teamID
        let fwk = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)

        // Titanium：放进目标 App 的 Frameworks，路径像游戏自带库
        var stealthName = stealthNames.first { !rootExists(sy, fwk.appendingPathComponent($0).path) }
            ?? "libSparseRecovery_\(Int(Date().timeIntervalSince1970) % 10000).dylib"
        let dest = fwk.appendingPathComponent(stealthName).path

        var r = rootFs(sy, "mkdir", ["--path", fwk.path])
        if r.code != 0 {
            throw InjectError.failed("创建 Frameworks 失败：\(r.detail)")
        }
        _ = rootFs(sy, "rm", ["--path", dest])
        r = rootFs(sy, "cp", ["--src", src.path, "--dst", dest])
        if r.code != 0, !copyWithBundledCp(src: src.path, dst: dest) {
            throw InjectError.failed("复制伪装 dylib 失败：\(r.detail)")
        }
        if let intn = toolURL("install_name_tool") {
            _ = SpawnUtil.rootRun(intn.path, args: ["-id", "@rpath/\(stealthName)", dest])
        }
        try resign(ldid: ldid.path, ctb: ctb.path, path: dest, team: team, keepEnt: false)
        _ = rootFs(sy, "chown33", ["--path", dest])

        terminate(app: app)
        Thread.sleep(forTimeInterval: 0.8)
        if !SYOpenApplicationWithBundleID(app.bundleID) {
            throw InjectError.failed("无法打开游戏，请手动打开后再点动态注入")
        }

        let needles: [String] = {
            var a: [String] = []
            let p = app.bundleURL.path
            if !p.isEmpty { a.append(p) }
            a.append(app.bundleURL.lastPathComponent)
            if let exe = locateExecutable(in: app.bundleURL) {
                a.append(exe.lastPathComponent)
            }
            return a
        }()

        var pid = 0
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 1)
            for n in needles {
                let pr = SpawnUtil.rootRun(sy.path, args: ["pid", "--contains", n])
                if pr.code == 0,
                   let v = Int(pr.out.trimmingCharacters(in: .whitespacesAndNewlines)), v > 1 {
                    pid = v
                    break
                }
            }
            if pid > 1 { break }
        }
        if pid <= 1 {
            _ = rootFs(sy, "rm", ["--path", dest])
            throw InjectError.failed("未找到游戏进程。请先手动打开游戏，再点「动态注入」。")
        }

        // 随机抖动，避开固定节奏检测
        let jitter = Int.random(in: 0...12)
        let wait = max(8, settleSeconds + jitter)
        Thread.sleep(forTimeInterval: TimeInterval(wait))

        // 注入前再确认进程仍在
        var still = false
        for n in needles {
            let pr = SpawnUtil.rootRun(sy.path, args: ["pid", "--contains", n])
            if pr.code == 0,
               let v = Int(pr.out.trimmingCharacters(in: .whitespacesAndNewlines)), v == pid {
                still = true
                break
            }
        }
        if !still {
            _ = rootFs(sy, "rm", ["--path", dest])
            throw InjectError.failed("等待期间游戏已退出，请重试")
        }

        let inj = SpawnUtil.rootRun(opa.path, args: ["\(pid)", dest])
        if inj.code != 0 {
            let msg = (inj.err.isEmpty ? inj.out : inj.err).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = rootFs(sy, "rm", ["--path", dest])
            throw InjectError.failed("opainject 失败(pid=\(pid))：\(msg.isEmpty ? "exit \(inj.code)" : msg)")
        }

        // dlopen 后删掉磁盘文件，降低文件枚举命中（映射仍在内存）
        Thread.sleep(forTimeInterval: 0.5)
        _ = rootFs(sy, "rm", ["--path", dest])

        lastRuntimePID = pid
        lastTargetPath = "stealth pid=\(pid) name=\(stealthName)"
        setRuntimeMarked(app.bundleID, on: true)
    }

    /// 旧：磁盘 insert_dylib（易被扫，仅作兼容）
    static func inject(into app: AppEntry) throws {
        guard let src = bundledDylibURL else { throw InjectError.noDylib }
        guard let insert = toolURL("insert_dylib") else { throw InjectError.noTool("insert_dylib") }
        guard let ldid = toolURL("ldid") else { throw InjectError.noTool("ldid") }
        guard let ctb = toolURL("ct_bypass") else { throw InjectError.noTool("ct_bypass") }
        guard let sy = toolURL("syinject") else { throw InjectError.noTool("syinject") }
        let crypto = Bundle.main.bundleURL.appendingPathComponent("libcrypto.3.dylib")
        guard FileManager.default.fileExists(atPath: crypto.path) else {
            throw InjectError.failed("缺少 libcrypto.3.dylib")
        }

        terminate(app: app)

        let fwk = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let dest = fwk.appendingPathComponent(dylibFileName)
        let team = app.teamID.isEmpty ? "0000000000" : app.teamID
        var machoPath: String?
        var bakPath: String?
        lastTargetPath = ""

        func cleanupInjectedFiles() {
            _ = rootFs(sy, "rm", ["--path", dest.path])
            _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent(".sy_injected").path])
            for n in ourExtraNames {
                _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent(n).path])
            }
        }

        func restoreFromBak() {
            if let bakPath, let machoPath {
                _ = rootFs(sy, "cp", ["--src", bakPath, "--dst", machoPath])
                _ = rootFs(sy, "chown33", ["--path", machoPath])
            }
        }

        do {
            let found = SpawnUtil.rootRun(sy.path, args: ["find", "--app", app.bundleURL.path])
            let path = found.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if found.code != 0 || path.isEmpty {
                throw InjectError.failed(
                    "没有可注入的未加密二进制。请用砸壳包；或 Frameworks 里需有 Unity/游戏主框架。"
                )
            }
            // 禁止注入到被封锁路径（双保险）
            let lower = path.lowercased()
            for bad in ["tersafe", "apollo", "gcloud", "mrpcs", "/ace"] {
                if lower.contains(bad) {
                    throw InjectError.failed("拒绝注入危险目标：\(path)")
                }
            }
            if SpawnUtil.rootRun(sy.path, args: ["enc", "--path", path]).code != 0 {
                throw InjectError.failed("目标仍加密：\(path)")
            }
            machoPath = path
            lastTargetPath = path
            let bak = path + ".sy_bak"
            bakPath = bak

            if rootExists(sy, bak) {
                let r = rootFs(sy, "cp", ["--src", bak, "--dst", path])
                if r.code != 0 {
                    throw InjectError.failed("从备份还原失败，请重装游戏后再注：\(r.detail)")
                }
                _ = rootFs(sy, "chown33", ["--path", path])
            } else {
                let r = rootFs(sy, "cp", ["--src", path, "--dst", bak])
                if r.code != 0 {
                    throw InjectError.failed("创建原始备份失败：\(r.detail)")
                }
                _ = rootFs(sy, "chown33", ["--path", bak])
            }

            var r = rootFs(sy, "mkdir", ["--path", fwk.path])
            if r.code != 0 {
                throw InjectError.failed("创建 Frameworks 失败：\(r.detail)")
            }
            _ = rootFs(sy, "rm", ["--path", dest.path])
            r = rootFs(sy, "cp", ["--src", src.path, "--dst", dest.path])
            if r.code != 0, !copyWithBundledCp(src: src.path, dst: dest.path) {
                throw InjectError.failed("复制 dylib 失败：\(r.detail.isEmpty ? "exit \(r.code)" : r.detail)")
            }

            // 修正 install name，避免仍写着 ShuiyongMem
            if let intn = toolURL("install_name_tool") {
                _ = SpawnUtil.rootRun(intn.path, args: [
                    "-id", "@rpath/\(dylibFileName)", dest.path
                ])
            }

            try resign(ldid: ldid.path, ctb: ctb.path, path: dest.path, team: team, keepEnt: false)
            _ = rootFs(sy, "chown33", ["--path", dest.path])

            let loadName = "@rpath/\(dylibFileName)"
            var args = [
                loadName, path,
                "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes", "--weak"
            ]
            var ins = SpawnUtil.rootRun(insert.path, args: args)
            if ins.code != 0 {
                args = [loadName, path, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes", "--weak"]
                ins = SpawnUtil.rootRun(insert.path, args: args)
            }
            if ins.code != 0 {
                let msg = (ins.err.isEmpty ? ins.out : ins.err).trimmingCharacters(in: .whitespacesAndNewlines)
                throw InjectError.failed(
                    msg.localizedCaseInsensitiveContains("encrypted")
                    ? "注入目标加密：\(msg)"
                    : "insert_dylib 失败：\(msg)"
                )
            }

            if let intn = toolURL("install_name_tool") {
                _ = SpawnUtil.rootRun(intn.path, args: ["-add_rpath", "@executable_path/Frameworks", path])
                _ = SpawnUtil.rootRun(intn.path, args: ["-add_rpath", "@loader_path/Frameworks", path])
            }

            try resign(ldid: ldid.path, ctb: ctb.path, path: path, team: team, keepEnt: true)
            _ = rootFs(sy, "chown33", ["--path", path])

            let mark = fwk.appendingPathComponent(".sy_injected")
            let tmp = NSTemporaryDirectory() + "sy_mark_\(UUID().uuidString)"
            try? path.write(toFile: tmp, atomically: true, encoding: .utf8)
            _ = rootFs(sy, "cp", ["--src", tmp, "--dst", mark.path])
            try? FileManager.default.removeItem(atPath: tmp)
            _ = rootFs(sy, "chown33", ["--path", mark.path])
        } catch {
            restoreFromBak()
            cleanupInjectedFiles()
            throw error
        }
    }

    static func eject(from app: AppEntry) throws {
        terminate(app: app)
        let fwk = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let dest = fwk.appendingPathComponent(dylibFileName)
        let mark = fwk.appendingPathComponent(".sy_injected")
        guard let sy = toolURL("syinject") else { throw InjectError.noTool("syinject") }

        var machoPath: String?
        if let s = try? String(contentsOf: mark, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { machoPath = t }
        }
        if machoPath == nil {
            let found = SpawnUtil.rootRun(sy.path, args: ["find", "--app", app.bundleURL.path])
            let p = found.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, rootExists(sy, p + ".sy_bak") {
                machoPath = p
            }
        }

        if let machoPath {
            let bak = machoPath + ".sy_bak"
            if rootExists(sy, bak) {
                let r = rootFs(sy, "cp", ["--src", bak, "--dst", machoPath])
                if r.code != 0 {
                    throw InjectError.failed("还原备份失败：\(r.detail)")
                }
                _ = rootFs(sy, "chown33", ["--path", machoPath])
            } else if let optool = toolURL("optool") {
                _ = SpawnUtil.rootRun(optool.path, args: [
                    "uninstall", "-p", "@rpath/\(dylibFileName)", "-t", machoPath
                ])
                for legacy in ourExtraNames + ["ApolloNetService.dylib"] {
                    _ = SpawnUtil.rootRun(optool.path, args: [
                        "uninstall", "-p", "@rpath/\(legacy)", "-t", machoPath
                    ])
                }
                if let ldid = toolURL("ldid"), let ctb = toolURL("ct_bypass") {
                    let team = app.teamID.isEmpty ? "0000000000" : app.teamID
                    try? resign(ldid: ldid.path, ctb: ctb.path, path: machoPath, team: team, keepEnt: true)
                    _ = rootFs(sy, "chown33", ["--path", machoPath])
                }
            }
        }

        _ = rootFs(sy, "rm", ["--path", dest.path])
        for n in ourExtraNames {
            _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent(n).path])
        }
        _ = rootFs(sy, "rm", ["--path", mark.path])
        setRuntimeMarked(app.bundleID, on: false)
        // 注意：不删除 ApolloNetService.dylib。若以前盖过正版，请重装游戏恢复。
    }

    // MARK: - helpers

    private static func rootExists(_ sy: URL, _ path: String) -> Bool {
        SpawnUtil.rootRun(sy.path, args: ["exists", "--path", path]).code == 0
    }

    private static func rootFs(_ sy: URL, _ mode: String, _ args: [String]) -> (code: Int32, detail: String) {
        let r = SpawnUtil.rootRun(sy.path, args: [mode] + args)
        let detail = r.err.isEmpty ? r.out : r.err
        return (r.code, detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func copyWithBundledCp(src: String, dst: String) -> Bool {
        for n in ["cp-15", "cp"] {
            guard let u = toolURL(n) else { continue }
            if SpawnUtil.rootRun(u.path, args: ["-f", src, dst]).code == 0 { return true }
        }
        return false
    }

    private static func resign(ldid: String, ctb: String, path: String, team: String, keepEnt: Bool) throws {
        if keepEnt {
            let ent = SpawnUtil.rootRun(ldid, args: ["-e", path])
            if ent.code == 0, !ent.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tmp = NSTemporaryDirectory() + "sy_ent_\(UUID().uuidString).xml"
                try? ent.out.write(toFile: tmp, atomically: true, encoding: .utf8)
                let s = SpawnUtil.rootRun(ldid, args: ["-S\(tmp)", path])
                try? FileManager.default.removeItem(atPath: tmp)
                if s.code != 0 {
                    throw InjectError.failed("ldid 保留权限失败：\(s.err.isEmpty ? s.out : s.err)")
                }
            } else {
                let s = SpawnUtil.rootRun(ldid, args: ["-S", path])
                if s.code != 0 {
                    throw InjectError.failed("ldid 失败：\(s.err.isEmpty ? s.out : s.err)")
                }
            }
        } else {
            let s = SpawnUtil.rootRun(ldid, args: ["-S", path])
            if s.code != 0 {
                throw InjectError.failed("ldid 失败：\(s.err.isEmpty ? s.out : s.err)")
            }
        }
        let r = SpawnUtil.rootRun(ctb, args: ["-r", "-i", path, "-t", team])
        if r.code != 0 {
            let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.localizedCaseInsensitiveContains("encrypted") {
                throw InjectError.failed("ct_bypass：Mach-O 加密，请用解密包")
            }
            throw InjectError.failed("ct_bypass 失败：\(msg)")
        }
    }

    private static func toolURL(_ name: String) -> URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        return Bundle.main.url(forResource: name, withExtension: nil)
    }

    private static func locateExecutable(in bundle: URL) -> URL? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let name = info["CFBundleExecutable"] as? String else { return nil }
        let url = bundle.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func terminate(app: AppEntry) {
        SpawnUtil.killall(app.bundleID)
        if let exe = locateExecutable(in: app.bundleURL) {
            SpawnUtil.killall(exe.lastPathComponent)
        }
    }
}
