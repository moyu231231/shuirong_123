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
        let fm = FileManager.default
        let fwkRoot = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        var preferred: [(URL, Int)] = []
        var others: [(URL, Int)] = []
        var anyMachO: [(URL, Int)] = []

        // 1) Frameworks（跳过 ACE/tersafe）—— 游戏优先 Unity/GCloud
        if let list = try? fm.contentsOfDirectory(atPath: fwkRoot.path) {
            for item in list where item.hasSuffix(".framework") {
                if blockedFrameworks.contains(where: { item.localizedCaseInsensitiveContains($0) }) {
                    continue
                }
                let name = (item as NSString).deletingPathExtension
                let macho = fwkRoot.appendingPathComponent("\(item)/\(name)")
                guard fm.fileExists(atPath: macho.path) else { continue }
                let size = (try? fm.attributesOfItem(atPath: macho.path)[.size] as? Int) ?? 0
                anyMachO.append((macho, size))
                if isEncryptedMachO(macho) { continue }
                let hot = name.contains("Unity") || name.contains("Il2Cpp")
                    || name.contains("GCloud") || name.contains("Apollo")
                    || name.contains("GameAssembly") || name.contains("UnityFramework")
                if hot { preferred.append((macho, size)) }
                else { others.append((macho, size)) }
            }
        }

        if let best = preferred.max(by: { $0.1 < $1.1 })?.0 { return best }
        if let best = others.max(by: { $0.1 < $1.1 })?.0 { return best }

        // 2) 主程序（普通 App / 无 Framework 时）
        if let exe = locateExecutable(in: bundle), fm.fileExists(atPath: exe.path) {
            anyMachO.append((exe, (try? fm.attributesOfItem(atPath: exe.path)[.size] as? Int) ?? 0))
            if !isEncryptedMachO(exe) { return exe }
        }

        // 3) 读头失败/误判加密时：仍回退到最大的现存 Mach-O，交给 insert_dylib
        if let best = anyMachO.max(by: { $0.1 < $1.1 })?.0 { return best }
        return locateExecutable(in: bundle)
    }

    /// 仅在明确 cryptid!=0 时视为加密。fat / 读失败 / 未知 magic → 不拦截（旧逻辑把 fat 全判加密，导致任意 App 都「没有可注入二进制」）。
    private static func isEncryptedMachO(_ url: URL) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? fh.close() }
        // 只读头部；fat 再按 slice offset 补读
        let head = fh.readData(ofLength: 4096)
        guard head.count >= 32 else { return false }
        let magic = readU32(head, 0, bigEndian: false)
        // Fat（头字段为大端）：检查 arm64 slice 是否全加密
        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            let nfat = Int(readU32(head, 4, bigEndian: true))
            guard nfat > 0, nfat < 32 else { return false }
            var sawArm64 = false
            var allEnc = true
            for i in 0..<nfat {
                let base = 8 + i * 20
                guard base + 20 <= head.count else { break }
                let cputype = Int32(bitPattern: readU32(head, base, bigEndian: true))
                let offset = UInt64(readU32(head, base + 8, bigEndian: true))
                // CPU_TYPE_ARM64 = 0x0100000C
                guard cputype == 0x0100000C else { continue }
                sawArm64 = true
                fh.seek(toFileOffset: offset)
                let slice = fh.readData(ofLength: 65536)
                if !thinSliceEncrypted(slice, offset: 0) {
                    allEnc = false
                }
            }
            return sawArm64 ? allEnc : false
        }
        // Thin 64-bit：补读到足够扫 load commands
        fh.seek(toFileOffset: 0)
        let thin = fh.readData(ofLength: 1_048_576)
        if magic == 0xFEEDFACF || magic == 0xCFFAEDFE {
            return thinSliceEncrypted(thin, offset: 0)
        }
        // 未知格式：不拦，交给 insert_dylib
        return false
    }

    private static func thinSliceEncrypted(_ data: Data, offset: Int) -> Bool {
        guard offset + 32 <= data.count else { return false }
        let magic = readU32(data, offset, bigEndian: false)
        let swap = magic == 0xCFFAEDFE
        guard magic == 0xFEEDFACF || magic == 0xCFFAEDFE else { return false }
        let ncmds = Int(readU32(data, offset + 16, bigEndian: swap))
        var off = offset + 32
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { break }
            let cmd = Int(readU32(data, off, bigEndian: swap))
            let cmdsize = Int(readU32(data, off + 4, bigEndian: swap))
            if cmdsize < 8 { break }
            // LC_ENCRYPTION_INFO = 0x21, LC_ENCRYPTION_INFO_64 = 0x2C
            if cmd == 0x21 || cmd == 0x2C {
                if off + 16 <= data.count {
                    let cryptid = Int(readU32(data, off + 12, bigEndian: swap))
                    if cryptid != 0 { return true }
                }
            }
            off += cmdsize
        }
        return false
    }

    private static func readU32(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
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
