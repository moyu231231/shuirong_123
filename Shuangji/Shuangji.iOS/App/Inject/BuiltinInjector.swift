import Foundation

/// TrollFools 同款：宿主原始备份 `.sy_bak` 常驻，移除/重注都从备份还原再动手。
/// 旧逻辑成功后删备份 → 移除只能 optool 刮 LC → 重注叠在脏二进制上 → 二次闪退。
enum BuiltinInjector {

    static let dylibFileName = "ApolloNetService.dylib"
    static let markerLoadName = "@rpath/ApolloNetService.dylib"
    private static let buildProductNames = ["ApolloNetService.dylib", "ShuiyongMem.dylib"]

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
            Bundle.main.url(forResource: "ApolloNetService", withExtension: "dylib"),
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

        func cleanupInjectedFiles() {
            _ = rootFs(sy, "rm", ["--path", dest.path])
            _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent(".sy_injected").path])
            _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent("ShuiyongMem.dylib").path])
        }

        func restoreFromBak() {
            if let bakPath, let machoPath {
                _ = rootFs(sy, "cp", ["--src", bakPath, "--dst", machoPath])
                _ = rootFs(sy, "chown33", ["--path", machoPath])
            }
        }

        do {
            // 0) root 找未加密目标
            let found = SpawnUtil.rootRun(sy.path, args: ["find", "--app", app.bundleURL.path])
            let path = found.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if found.code != 0 || path.isEmpty {
                throw InjectError.failed(
                    "没有可注入的未加密二进制。App Store 加密包需砸壳/解密；或 Frameworks 里需有未加密 Mach-O。"
                )
            }
            if SpawnUtil.rootRun(sy.path, args: ["enc", "--path", path]).code != 0 {
                throw InjectError.failed("目标仍加密，已拒绝注入：\(path)")
            }
            machoPath = path
            let bak = path + ".sy_bak"
            bakPath = bak

            // 1) 有原始备份则先还原到干净宿主；没有才新建（绝不能用已注入文件覆盖备份）
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

            // 2) 目录 + 拷贝 dylib
            var r = rootFs(sy, "mkdir", ["--path", fwk.path])
            if r.code != 0 {
                throw InjectError.failed("创建 Frameworks 失败：\(r.detail)")
            }
            _ = rootFs(sy, "rm", ["--path", dest.path])
            r = rootFs(sy, "cp", ["--src", src.path, "--dst", dest.path])
            if r.code != 0, !copyWithBundledCp(src: src.path, dst: dest.path) {
                throw InjectError.failed("复制 dylib 失败：\(r.detail.isEmpty ? "exit \(r.code)" : r.detail)")
            }

            // 3) 先签 dylib
            try resign(ldid: ldid.path, ctb: ctb.path, path: dest.path, team: team, keepEnt: false)
            _ = rootFs(sy, "chown33", ["--path", dest.path])

            // 4) insert_dylib（此时宿主一定是干净备份还原后的）
            let loadName = "@rpath/\(dylibFileName)"
            var args = [
                loadName, path,
                "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes", "--weak"
            ]
            var ins = SpawnUtil.rootRun(insert.path, args: args)
            if ins.code != 0 {
                args = [loadName, path, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes"]
                ins = SpawnUtil.rootRun(insert.path, args: args)
            }
            if ins.code != 0 {
                let msg = (ins.err.isEmpty ? ins.out : ins.err).trimmingCharacters(in: .whitespacesAndNewlines)
                throw InjectError.failed(
                    msg.localizedCaseInsensitiveContains("encrypted")
                    ? "注入目标加密（请换砸壳包）：\(msg)"
                    : "insert_dylib 失败：\(msg)"
                )
            }

            // 5) rpath（干净文件上只加一次）
            if let intn = toolURL("install_name_tool") {
                _ = SpawnUtil.rootRun(intn.path, args: ["-add_rpath", "@executable_path/Frameworks", path])
                _ = SpawnUtil.rootRun(intn.path, args: ["-add_rpath", "@loader_path/Frameworks", path])
            }

            // 6) 宿主重签
            try resign(ldid: ldid.path, ctb: ctb.path, path: path, team: team, keepEnt: true)
            _ = rootFs(sy, "chown33", ["--path", path])

            // 7) 标记 —— 保留 .sy_bak，供移除/重注还原
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
        // 标记丢了也尽量找备份：扫描 find 目标旁的 .sy_bak
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
                // 整文件还原到注入前，不靠 optool 刮 LC
                let r = rootFs(sy, "cp", ["--src", bak, "--dst", machoPath])
                if r.code != 0 {
                    throw InjectError.failed("还原备份失败：\(r.detail)")
                }
                _ = rootFs(sy, "chown33", ["--path", machoPath])
                // 备份继续留着，方便再次注入
            } else if let optool = toolURL("optool") {
                // 老版本已删备份：尽力卸 LC（可能仍不稳定，建议重装游戏）
                _ = SpawnUtil.rootRun(optool.path, args: [
                    "uninstall", "-p", "@rpath/\(dylibFileName)", "-t", machoPath
                ])
                if let ldid = toolURL("ldid"), let ctb = toolURL("ct_bypass") {
                    let team = app.teamID.isEmpty ? "0000000000" : app.teamID
                    try? resign(ldid: ldid.path, ctb: ctb.path, path: machoPath, team: team, keepEnt: true)
                    _ = rootFs(sy, "chown33", ["--path", machoPath])
                }
            }
        }

        _ = rootFs(sy, "rm", ["--path", dest.path])
        _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent("ShuiyongMem.dylib").path])
        _ = rootFs(sy, "rm", ["--path", mark.path])
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
