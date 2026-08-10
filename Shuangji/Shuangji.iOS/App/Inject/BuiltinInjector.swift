import Foundation

/// 完全按 TrollFools 工具链注入：
/// copy → insert_dylib(--no-strip-codesig) → ldid → ct_bypass → chown 33:33
/// 不再用自研 syinject 改 Mach-O（会把段偏移写坏导致目标秒闪）。
enum BuiltinInjector {

    static let dylibFileName = "ApolloNetService.dylib"
    static let markerLoadName = "@rpath/ApolloNetService.dylib"
    private static let buildProductNames = ["ApolloNetService.dylib", "ShuiyongMem.dylib"]

    /// 不要往这些 framework 里插（ACE 自检 / 加密）
    private static let blockedFrameworks = [
        "tersafe", "Tersafe", "ACE", "TSS", "mrpcs", "MRPCS", "AntiCheat"
    ]

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
        let crypto = Bundle.main.bundleURL.appendingPathComponent("libcrypto.3.dylib")
        guard FileManager.default.fileExists(atPath: crypto.path) else {
            throw InjectError.failed("缺少 libcrypto.3.dylib")
        }

        terminate(app: app)

        let fwk = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let dest = fwk.appendingPathComponent(dylibFileName)
        let team = app.teamID.isEmpty ? "0000000000" : app.teamID

        // 1) 准备目录 + 拷贝 dylib（iOS 15 无 /bin/cp，用 syinject 在 root 进程内读写）
        guard let sy = toolURL("syinject") else { throw InjectError.noTool("syinject") }
        var r = rootFs(sy, "mkdir", ["--path", fwk.path])
        if r.code != 0 {
            throw InjectError.failed("创建 Frameworks 失败：\(r.detail)")
        }
        _ = rootFs(sy, "rm", ["--path", dest.path])
        r = rootFs(sy, "cp", ["--src", src.path, "--dst", dest.path])
        if r.code != 0 {
            // 再试 TrollFools 自带的 cp-15（iOS 15）/ cp（iOS 16+）
            if !copyWithBundledCp(src: src.path, dst: dest.path) {
                let more = r.detail.isEmpty ? "exit \(r.code)" : r.detail
                throw InjectError.failed("复制 dylib 失败：\(more)")
            }
        }

        // 2) 选可注入 Mach-O（避开 tersafe）
        guard let macho = locateInjectTarget(in: app.bundleURL) else {
            throw InjectError.failed("没有可注入的二进制（全被加密或仅剩保护模块）")
        }

        // 3) 备份，失败可回滚
        let bak = macho.path + ".sy_bak"
        _ = rootFs(sy, "cp", ["--src", macho.path, "--dst", bak])

        // 4) insert_dylib —— 与 TrollFools 相同参数
        let loadName = "@rpath/\(dylibFileName)"
        var args = [
            loadName, macho.path,
            "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes", "--weak"
        ]
        var ins = SpawnUtil.rootRun(insert.path, args: args)
        if ins.code != 0 {
            // 再试非 weak
            args = [loadName, macho.path, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes"]
            ins = SpawnUtil.rootRun(insert.path, args: args)
        }
        if ins.code != 0 {
            _ = rootFs(sy, "cp", ["--src", bak, "--dst", macho.path])
            _ = rootFs(sy, "rm", ["--path", dest.path])
            _ = rootFs(sy, "rm", ["--path", bak])
            throw InjectError.failed("insert_dylib 失败：\(ins.err.isEmpty ? ins.out : ins.err)")
        }

        // 5) 补 rpath（TrollFools 也会加 @executable_path/Frameworks）
        if let intn = toolURL("install_name_tool") {
            _ = SpawnUtil.rootRun(intn.path, args: [
                "-add_rpath", "@executable_path/Frameworks", macho.path
            ])
            _ = SpawnUtil.rootRun(intn.path, args: [
                "-add_rpath", "@loader_path/Frameworks", macho.path
            ])
        }

        // 6) CoreTrust：先 dylib，再宿主
        do {
            try resign(ldid: ldid.path, ctb: ctb.path, path: dest.path, team: team, keepEnt: false)
            try resign(ldid: ldid.path, ctb: ctb.path, path: macho.path, team: team, keepEnt: true)
            _ = rootFs(sy, "chown33", ["--path", dest.path])
            _ = rootFs(sy, "chown33", ["--path", macho.path])
        } catch {
            _ = rootFs(sy, "cp", ["--src", bak, "--dst", macho.path])
            _ = rootFs(sy, "rm", ["--path", dest.path])
            _ = rootFs(sy, "rm", ["--path", bak])
            throw error
        }

        // 7) 标记
        let mark = fwk.appendingPathComponent(".sy_injected")
        let markBody = macho.path
        let tmp = NSTemporaryDirectory() + "sy_mark_\(UUID().uuidString)"
        try? markBody.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = rootFs(sy, "cp", ["--src", tmp, "--dst", mark.path])
        try? FileManager.default.removeItem(atPath: tmp)
        _ = rootFs(sy, "rm", ["--path", bak])
        _ = rootFs(sy, "chown33", ["--path", mark.path])
    }

    static func eject(from app: AppEntry) throws {
        terminate(app: app)
        let fwk = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let dest = fwk.appendingPathComponent(dylibFileName)
        let mark = fwk.appendingPathComponent(".sy_injected")
        let sy = toolURL("syinject")

        // 若有记录的 macho，用 optool 卸 LC
        if let machoPath = try? String(contentsOf: mark, encoding: .utf8),
           !machoPath.isEmpty,
           FileManager.default.fileExists(atPath: machoPath),
           let optool = toolURL("optool") {
            _ = SpawnUtil.rootRun(optool.path, args: [
                "uninstall", "-p", "@rpath/\(dylibFileName)", "-t", machoPath
            ])
            if let ldid = toolURL("ldid"), let ctb = toolURL("ct_bypass") {
                let team = app.teamID.isEmpty ? "0000000000" : app.teamID
                try? resign(ldid: ldid.path, ctb: ctb.path, path: machoPath, team: team, keepEnt: true)
            }
        }

        if let sy {
            _ = rootFs(sy, "rm", ["--path", dest.path])
            _ = rootFs(sy, "rm", ["--path", fwk.appendingPathComponent("ShuiyongMem.dylib").path])
            _ = rootFs(sy, "rm", ["--path", mark.path])
        }
    }

    // MARK: - helpers

    private static func rootFs(_ sy: URL, _ mode: String, _ args: [String]) -> (code: Int32, detail: String) {
        let r = SpawnUtil.rootRun(sy.path, args: [mode] + args)
        let detail = r.err.isEmpty ? r.out : r.err
        return (r.code, detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// iOS 15 用 cp-15，16+ 用 cp（与 TrollFools 一致）
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
            throw InjectError.failed("ct_bypass 失败：\(r.err.isEmpty ? r.out : r.err)")
        }
    }

    private static func locateInjectTarget(in bundle: URL) -> URL? {
        let fwkRoot = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        var preferred: [(URL, Int)] = []
        var others: [(URL, Int)] = []

        if let list = try? FileManager.default.contentsOfDirectory(atPath: fwkRoot.path) {
            for item in list where item.hasSuffix(".framework") {
                if blockedFrameworks.contains(where: { item.localizedCaseInsensitiveContains($0) }) {
                    continue
                }
                let name = (item as NSString).deletingPathExtension
                let macho = fwkRoot.appendingPathComponent("\(item)/\(name)")
                guard FileManager.default.fileExists(atPath: macho.path),
                      !isEncryptedMachO(macho) else { continue }
                let size = (try? FileManager.default.attributesOfItem(atPath: macho.path)[.size] as? Int) ?? 0
                let hot = name.contains("Unity") || name.contains("Il2Cpp")
                    || name.contains("GCloud") || name.contains("Apollo")
                    || name.contains("GameAssembly")
                if hot { preferred.append((macho, size)) }
                else { others.append((macho, size)) }
            }
        }

        // 优先大体积游戏框架（TrollFools 也是选可用 framework，而不是主程序）
        if let best = preferred.max(by: { $0.1 < $1.1 })?.0 { return best }
        if let best = others.max(by: { $0.1 < $1.1 })?.0 { return best }

        // 最后才主程序
        if let exe = locateExecutable(in: bundle), !isEncryptedMachO(exe) {
            return exe
        }
        return nil
    }

    private static func isEncryptedMachO(_ url: URL) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return true }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: min(1_048_576, Int(fh.seekToEndOfFile())))
        fh.seek(toFileOffset: 0)
        guard data.count > 32 else { return true }
        // 粗扫 LC_ENCRYPTION_INFO cryptid != 0
        let bytes = [UInt8](data)
        var magic: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &magic) { dest in
            data.copyBytes(to: dest, from: 0..<4)
        }
        guard magic == 0xFEEDFACF else { return true } // 只要 thin arm64；fat 交给 insert_dylib
        var off = 32
        let ncmds = Int(bytes[16]) | (Int(bytes[17]) << 8) | (Int(bytes[18]) << 16) | (Int(bytes[19]) << 24)
        // sizeofcmds at 20
        for _ in 0..<ncmds {
            if off + 8 > bytes.count { break }
            let cmd = Int(bytes[off]) | (Int(bytes[off+1]) << 8) | (Int(bytes[off+2]) << 16) | (Int(bytes[off+3]) << 24)
            let cmdsize = Int(bytes[off+4]) | (Int(bytes[off+5]) << 8) | (Int(bytes[off+6]) << 16) | (Int(bytes[off+7]) << 24)
            if cmdsize < 8 { break }
            if cmd == 0x21 || cmd == 0x2C { // LC_ENCRYPTION_INFO / _64
                if off + 16 <= bytes.count {
                    let cryptid = Int(bytes[off+12]) | (Int(bytes[off+13]) << 8)
                        | (Int(bytes[off+14]) << 16) | (Int(bytes[off+15]) << 24)
                    if cryptid != 0 { return true }
                }
            }
            off += cmdsize
        }
        return false
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
