import Foundation

/// 只注入包内固定 dylib（对齐 TrollFools：杀进程 → Frameworks → LC_LOAD → 伪签）。
/// 不提供文件选择。Mach-O 改写由 Resources 内 `syinject` 完成。
enum BuiltinInjector {

    static let dylibFileName = "ShuiyongMem.dylib"
    static let markerLoadName = "@rpath/ShuiyongMem.dylib"

    enum InjectError: LocalizedError {
        case noDylib
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noDylib: return "缺少内置组件"
            case .failed(let s): return s
            }
        }
    }

    static var bundledDylibURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent(dylibFileName),
            Bundle.main.url(forResource: "ShuiyongMem", withExtension: "dylib"),
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/\(dylibFileName)")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isInjected(bundleURL: URL, marker: String = markerLoadName) -> Bool {
        let mark = bundleURL.appendingPathComponent("Frameworks/.sy_injected")
        if FileManager.default.fileExists(atPath: mark.path) { return true }
        let dest = bundleURL.appendingPathComponent("Frameworks/\(dylibFileName)")
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        guard let exe = locateExecutable(in: bundleURL),
              let data = try? Data(contentsOf: exe) else { return false }
        return data.range(of: Data("ShuiyongMem.dylib".utf8)) != nil
    }

    static func inject(into app: AppEntry) throws {
        guard let dylib = bundledDylibURL, FileManager.default.fileExists(atPath: dylib.path) else {
            throw InjectError.noDylib
        }
        terminate(app: app)

        let fwk = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: fwk, withIntermediateDirectories: true)
        let dest = fwk.appendingPathComponent(dylibFileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: dylib, to: dest)

        guard let exe = locateExecutable(in: app.bundleURL) else {
            throw InjectError.failed("找不到可执行文件")
        }

        if let helper = helperURL() {
            let code = SpawnUtil.run(helper.path, args: [
                "inject",
                "--app", app.bundleURL.path,
                "--exe", exe.path,
                "--dylib", dest.path,
                "--rpath", "@executable_path/Frameworks"
            ])
            if code != 0 {
                throw InjectError.failed("注入失败 (\(code))")
            }
        }

        let mark = fwk.appendingPathComponent(".sy_injected")
        try Data("1".utf8).write(to: mark)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: dest.path)
    }

    static func eject(from app: AppEntry) throws {
        terminate(app: app)
        let fwk = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let dest = fwk.appendingPathComponent(dylibFileName)
        let mark = fwk.appendingPathComponent(".sy_injected")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.removeItem(at: mark)

        if let helper = helperURL(), let exe = locateExecutable(in: app.bundleURL) {
            _ = SpawnUtil.run(helper.path, args: [
                "eject", "--exe", exe.path, "--name", dylibFileName
            ])
        }
    }

    private static func helperURL() -> URL? {
        if let u = Bundle.main.url(forResource: "syinject", withExtension: nil) { return u }
        let u = Bundle.main.bundleURL.appendingPathComponent("syinject")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
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
