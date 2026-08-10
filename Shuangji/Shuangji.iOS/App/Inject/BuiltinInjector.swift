import Foundation

/// 只注入包内固定 dylib。
/// 通过 root persona 跑 syinject deploy（对齐 TrollFools 的 cp/mkdir 提权写法）。
enum BuiltinInjector {

    static let dylibFileName = "ShuiyongMem.dylib"
    static let markerLoadName = "@rpath/ShuiyongMem.dylib"

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
        guard let dylib = bundledDylibURL else { throw InjectError.noDylib }
        guard let helper = helperURL() else { throw InjectError.noHelper }
        terminate(app: app)

        let result = SpawnUtil.rootRun(helper.path, args: [
            "deploy",
            "--app", app.bundleURL.path,
            "--src", dylib.path,
            "--name", dylibFileName
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
    }

    static func eject(from app: AppEntry) throws {
        guard let helper = helperURL() else { throw InjectError.noHelper }
        terminate(app: app)
        let result = SpawnUtil.rootRun(helper.path, args: [
            "eject",
            "--app", app.bundleURL.path,
            "--name", dylibFileName
        ])
        if result.code < 0 {
            throw InjectError.failed("提权启动失败(\(result.code))，请确认用 TrollStore 安装")
        }
    }

    private static func mapDeployError(_ code: Int32, detail: String) -> String {
        switch code {
        case 2: return "无法创建 Frameworks：\(detail)"
        case 3: return "无法复制 dylib：\(detail)"
        case 4: return "没有可注入的二进制（可能被加密保护）"
        case 5: return "写入加载命令失败：\(detail)"
        default: return "注入失败(\(code))：\(detail)"
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
