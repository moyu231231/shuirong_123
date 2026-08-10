import Foundation

/// TrollFools 同款链路：
/// root find(未加密) → copy dylib → ct_bypass(dylib) → insert_dylib → ldid/ct_bypass(宿主) → chown
/// 绝不改加密 Mach-O；失败必须完整回滚，避免半注入闪退。
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
        var bak: String?
        var machoPath: String?

        func rollback() {
            if let bak, let machoPath {
                _ = rootFs(sy, "cp", ["--src", bak, "--dst", machoPath])
                _ = rootFs(sy, "rm", ["--path", bak])
            }
            _ = rootFs(sy, "rm", ["--path", dest.path])
            _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent(".sy_injected").path])
            _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent("ShuiyongMem.dylib").path])
        }

        do {
            // 0) 先用 root 找未加密目标（沙盒读头会误判，绝不能靠 FileHandle）
            let found = SpawnUtil.rootRun(sy.path, args: ["find", "--app", app.bundleURL.path])
            let path = found.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if found.code != 0 || path.isEmpty {
                throw InjectError.failed(
                    "没有可注入的未加密二进制。App Store 加密包需砸壳/解密；或 Frameworks 里需有未加密 Mach-O（与 TrollFools 相同限制）。"
                )
            }
            let enc = SpawnUtil.rootRun(sy.path, args: ["enc", "--path", path])
            if enc.code != 0 {
                throw InjectError.failed("目标仍加密，已拒绝注入：\(path)")
            }
            machoPath = path

            // 1) 目录 + 拷贝 dylib
            var r = rootFs(sy, "mkdir", ["--path", fwk.path])
            if r.code != 0 {
                throw InjectError.failed("创建 Frameworks 失败：\(r.detail)")
            }
            _ = rootFs(sy, "rm", ["--path", dest.path])
            r = rootFs(sy, "cp", ["--src", src.path, "--dst", dest.path])
            if r.code != 0, !copyWithBundledCp(src: src.path, dst: dest.path) {
                throw InjectError.failed("复制 dylib 失败：\(r.detail.isEmpty ? "exit \(r.code)" : r.detail)")
            }

            // 2) 先签 dylib（TrollFools：asset 先 ct_bypass）
            try resign(ldid: ldid.path, ctb: ctb.path, path: dest.path, team: team, keepEnt: false)
            _ = rootFs(sy, "chown33", ["--path", dest.path])

            // 3) 备份宿主
            let bakPath = path + ".sy_bak"
            bak = bakPath
            _ = rootFs(sy, "rm", ["--path", bakPath])
            r = rootFs(sy, "cp", ["--src", path, "--dst", bakPath])
            if r.code != 0 {
                throw InjectError.failed("备份失败：\(r.detail)")
            }

            // 4) insert_dylib
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
                if msg.localizedCaseInsensitiveContains("encrypted") {
                    throw InjectError.failed("注入目标加密（请换砸壳包）：\(msg)")
                }
                throw InjectError.failed("insert_dylib 失败：\(msg)")
            }

            // 5) rpath
            if let intn = toolURL("install_name_tool") {
                _ = SpawnUtil.rootRun(intn.path, args: ["-add_rpath", "@executable_path/Frameworks", path])
                _ = SpawnUtil.rootRun(intn.path, args: ["-add_rpath", "@loader_path/Frameworks", path])
            }

            // 6) 宿主重签 + CoreTrust
            try resign(ldid: ldid.path, ctb: ctb.path, path: path, team: team, keepEnt: true)
            _ = rootFs(sy, "chown33", ["--path", path])

            // 7) 标记成功后再删备份
            let mark = fwk.appendingPathComponent(".sy_injected")
            let tmp = NSTemporaryDirectory() + "sy_mark_\(UUID().uuidString)"
            try? path.write(toFile: tmp, atomically: true, encoding: .utf8)
            _ = rootFs(sy, "cp", ["--src", tmp, "--dst", mark.path])
            try? FileManager.default.removeItem(atPath: tmp)
            _ = rootFs(sy, "chown33", ["--path", mark.path])
            _ = rootFs(sy, "rm", ["--path", bakPath])
            bak = nil
        } catch {
            rollback()
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

        // 优先从备份恢复；没有备份再用 optool 卸 LC
        if let machoPath {
            let bak = machoPath + ".sy_bak"
            let restored = rootFs(sy, "cp", ["--src", bak, "--dst", machoPath])
            if restored.code == 0 {
                _ = rootFs(sy, "rm", ["--path", bak])
            } else if let optool = toolURL("optool") {
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
        // 扫掉可能残留的 bak
        if let machoPath {
            _ = rootFs(sy, "rm", ["--path", machoPath + ".sy_bak"])
        }
    }

    // MARK: - helpers

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
