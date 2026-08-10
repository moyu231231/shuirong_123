import Foundation

/// 注入：弱引用 LC + 避开 tersafe + ldid/ct_bypass（对齐 TrollFools，防注入保护闪退）
enum BuiltinInjector {

    /// 对外装载名（伪装成常见 GCloud/Apollo 组件，降低字符串扫描命中）
    static let dylibFileName = "ApolloNetService.dylib"
    static let markerLoadName = "@rpath/ApolloNetService.dylib"
    /// 编译产物可能仍叫这个
    private static let buildProductNames = ["ApolloNetService.dylib", "ShuiyongMem.dylib"]

    enum InjectError: LocalizedError {
        case noDylib
        case noHelper
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noDylib: return "缺少内置组件"
            case .noHelper: return "缺少 syinject"
            case .failed(let s): return s
            }
        }
    }

    static var bundledDylibURL: URL? {
        var candidates: [URL] = []
        for n in buildProductNames {
            candidates.append(Bundle.main.bundleURL.appendingPathComponent(n))
            candidates.append(Bundle.main.bundleURL.appendingPathComponent("Frameworks/\(n)"))
        }
        candidates.append(contentsOf: [
            Bundle.main.url(forResource: "ApolloNetService", withExtension: "dylib"),
            Bundle.main.url(forResource: "ShuiyongMem", withExtension: "dylib")
        ].compactMap { $0 })
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isInjected(bundleURL: URL, marker: String = markerLoadName) -> Bool {
        let mark = bundleURL.appendingPathComponent("Frameworks/.sy_injected")
        if FileManager.default.fileExists(atPath: mark.path) { return true }
        for n in buildProductNames {
            let dest = bundleURL.appendingPathComponent("Frameworks/\(n)")
            if FileManager.default.fileExists(atPath: dest.path) { return true }
        }
        guard let exe = locateExecutable(in: bundleURL),
              let data = try? Data(contentsOf: exe) else { return false }
        return data.range(of: Data("ApolloNetService.dylib".utf8)) != nil
            || data.range(of: Data("ShuiyongMem.dylib".utf8)) != nil
    }

    static func inject(into app: AppEntry) throws {
        guard let dylib = bundledDylibURL else { throw InjectError.noDylib }
        guard let helper = helperURL() else { throw InjectError.noHelper }
        terminate(app: app)

        let result = SpawnUtil.rootRun(helper.path, args: [
            "deploy",
            "--app", app.bundleURL.path,
            "--src", dylib.path,
            "--name", dylibFileName,
            "--weak"
        ])
        if result.code != 0 {
            let detail = [result.err, result.out]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "code \(result.code)"
            if result.code < 0 {
                throw InjectError.failed("提权启动失败(\(result.code))，请确认用 TrollStore 安装")
            }
            throw InjectError.failed(mapDeployError(result.code, detail: detail))
        }

        // 解析 "ok /path/to/macho"
        let machoPath = parseOkPath(result.out)
            ?? app.bundleURL.appendingPathComponent("Frameworks").path
        let destDylib = app.bundleURL
            .appendingPathComponent("Frameworks/\(dylibFileName)", isDirectory: false)

        // CoreTrust：改完 LC 必须伪签 + ct_bypass，否则目标必闪
        do {
            try coreTrustRepair(macho: machoPath, dylib: destDylib.path, teamID: app.teamID)
        } catch {
            // 签名失败则回滚，避免留下半残注入让 A 一直闪退
            _ = SpawnUtil.rootRun(helper.path, args: [
                "eject", "--app", app.bundleURL.path, "--name", dylibFileName
            ])
            throw error
        }
    }

    static func eject(from app: AppEntry) throws {
        guard let helper = helperURL() else { throw InjectError.noHelper }
        terminate(app: app)
        let result = SpawnUtil.rootRun(helper.path, args: [
            "eject",
            "--app", app.bundleURL.path,
            "--name", dylibFileName
        ])
        // 兼容旧名
        _ = SpawnUtil.rootRun(helper.path, args: [
            "eject",
            "--app", app.bundleURL.path,
            "--name", "ShuiyongMem.dylib"
        ])
        if result.code < 0 {
            throw InjectError.failed("提权启动失败(\(result.code))，请确认用 TrollStore 安装")
        }
    }

    private static func coreTrustRepair(macho: String, dylib: String, teamID: String) throws {
        let team = teamID.isEmpty ? "0000000000" : teamID
        guard let ldid = toolURL("ldid"), let ctb = toolURL("ct_bypass") else {
            throw InjectError.failed("缺少 ldid/ct_bypass，无法完成签名（注入后会闪退）")
        }
        // ct_bypass 依赖同目录 libcrypto.3.dylib
        let crypto = Bundle.main.bundleURL.appendingPathComponent("libcrypto.3.dylib")
        if !FileManager.default.fileExists(atPath: crypto.path) {
            throw InjectError.failed("缺少 libcrypto.3.dylib，请重新打包 tipa")
        }

        // dylib：ldid -S + ct_bypass
        let s1 = SpawnUtil.rootRun(ldid.path, args: ["-S", dylib])
        if s1.code != 0 {
            throw InjectError.failed("dylib ldid 失败：\(s1.err.isEmpty ? s1.out : s1.err)")
        }
        var r = SpawnUtil.rootRun(ctb.path, args: ["-r", "-i", dylib, "-t", team])
        if r.code != 0 {
            throw InjectError.failed("dylib CoreTrust 处理失败：\(r.err.isEmpty ? r.out : r.err)")
        }

        // 被改写的宿主 Mach-O
        if FileManager.default.fileExists(atPath: macho), !macho.hasSuffix("Frameworks") {
            let ent = SpawnUtil.rootRun(ldid.path, args: ["-e", macho])
            if ent.code == 0, !ent.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tmp = NSTemporaryDirectory() + "sy_\(UUID().uuidString).xml"
                try? ent.out.write(toFile: tmp, atomically: true, encoding: .utf8)
                _ = SpawnUtil.rootRun(ldid.path, args: ["-S\(tmp)", macho])
                try? FileManager.default.removeItem(atPath: tmp)
            } else {
                let s2 = SpawnUtil.rootRun(ldid.path, args: ["-S", macho])
                if s2.code != 0 {
                    throw InjectError.failed("宿主 ldid 失败：\(s2.err.isEmpty ? s2.out : s2.err)")
                }
            }
            r = SpawnUtil.rootRun(ctb.path, args: ["-r", "-i", macho, "-t", team])
            if r.code != 0 {
                throw InjectError.failed("宿主 CoreTrust 处理失败：\(r.err.isEmpty ? r.out : r.err)")
            }
            _ = SpawnUtil.rootRun("/usr/sbin/chown", args: ["-R", "33:33", macho])
        }
        _ = SpawnUtil.rootRun("/usr/sbin/chown", args: ["33:33", dylib])
    }

    private static func parseOkPath(_ out: String) -> String? {
        for line in out.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("ok ") {
                let p = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { return p }
            }
        }
        return nil
    }

    private static func mapDeployError(_ code: Int32, detail: String) -> String {
        switch code {
        case 2: return "无法创建 Frameworks：\(detail)"
        case 3: return "无法复制 dylib：\(detail)"
        case 4: return "没有可注入的二进制（加密或仅剩 tersafe 等保护模块）"
        case 5: return "写入加载命令失败：\(detail)"
        default: return "注入失败(\(code))：\(detail)"
        }
    }

    private static func helperURL() -> URL? {
        if let u = Bundle.main.url(forResource: "syinject", withExtension: nil) { return u }
        let u = Bundle.main.bundleURL.appendingPathComponent("syinject")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private static func toolURL(_ name: String) -> URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: u.path)
            || FileManager.default.fileExists(atPath: u.path) { return u }
        return Bundle.main.url(forResource: name, withExtension: nil)
    }

    private static func locateExecutable(in bundle: URL) -> URL? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let name = info["CFBundleExecutable"] as? String
        else { return nil }
        let url = bundle.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func terminate(app: AppEntry) {
        SpawnUtil.killall(app.bundleID)
        if let exe = locateExecutable(in: app.bundleURL) {
            SpawnUtil.killall(exe.deletingPathExtension().lastPathComponent)
            SpawnUtil.killall(exe.lastPathComponent)
        }
    }
}
