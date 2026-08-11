import Foundation
import Darwin

/// 解析官方 rootless (`/var/jb`) 与 RootHide 随机 jbroot
enum JBRootFinder {

    static let mobileFallback = "/var/mobile/Library/shuiyong"

    /// 返回真实可写的越狱根（rootfs 视角），找不到返回 nil
    static func findJBRoot() -> String? {
        let fm = FileManager.default

        // 1) 经典 rootless
        for p in ["/var/jb", "/var/jb/usr/lib"] {
            if fm.fileExists(atPath: p) { return "/var/jb" }
        }

        // 2) 环境变量
        if let jr = getenv("JB_ROOT_PATH"), let s = String(validatingUTF8: jr), !s.isEmpty,
           fm.fileExists(atPath: s) {
            return s
        }

        // 3) jbclient / libroot / libroothide
        if let via = viaDlsymGetJBRoot() { return via }

        // 4) RootHide：扫描 .jbroot-*
        if let rh = scanRootHideJBRoot() { return rh }

        return nil
    }

    static var isRootHideStyle: Bool {
        guard let r = findJBRoot() else { return false }
        return r.contains(".jbroot") || r.contains("/var/containers/Bundle")
    }

    static func toolInstallRoots() -> [String] {
        var roots = [mobileFallback]
        if let jb = findJBRoot() {
            roots.insert(jb + "/usr/local/shuiyong", at: 0)
        }
        return roots
    }

    static func tweakDirs() -> [String] {
        guard let jb = findJBRoot() else { return [] }
        return [
            jb + "/Library/MobileSubstrate/DynamicLibraries",
            jb + "/usr/lib/TweakInject",
            jb + "/Library/TweakInject"
        ]
    }

    static func launchDaemonDir() -> String? {
        guard let jb = findJBRoot() else { return nil }
        return jb + "/Library/LaunchDaemons"
    }

    // MARK: - private

    private static func viaDlsymGetJBRoot() -> String? {
        let libs = [
            "libjailbreak.dylib",
            "libroot.dylib",
            "libroothide.dylib",
            "/var/jb/basebin/libjailbreak.dylib"
        ]
        for path in libs {
            guard let h = dlopen(path, RTLD_NOW) else { continue }
            typealias GetFn = @convention(c) () -> UnsafePointer<CChar>?
            if let sym = dlsym(h, "jbclient_get_jbroot") {
                let fn = unsafeBitCast(sym, to: GetFn.self)
                if let p = fn(), let s = String(validatingUTF8: p), !s.isEmpty {
                    return s
                }
            }
            if let sym = dlsym(h, "get_jbroot") {
                let fn = unsafeBitCast(sym, to: GetFn.self)
                if let p = fn(), let s = String(validatingUTF8: p), !s.isEmpty {
                    return s
                }
            }
            typealias JbrootFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
            if let sym = dlsym(h, "jbroot") {
                let fn = unsafeBitCast(sym, to: JbrootFn.self)
                if let p = fn("/"), let s = String(validatingUTF8: p), !s.isEmpty, s != "/" {
                    return s.hasSuffix("/") ? String(s.dropLast()) : s
                }
            }
        }
        return nil
    }

    private static func scanRootHideJBRoot() -> String? {
        let fm = FileManager.default
        let bases = [
            "/var/containers/Bundle/Application",
            "/var/containers/Bundle"
        ]
        for base in bases {
            guard let items = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for name in items where name.hasPrefix(".jbroot") {
                let root = (base as NSString).appendingPathComponent(name)
                // 有效 jbroot 通常有 usr 或 Library
                if fm.fileExists(atPath: root + "/usr")
                    || fm.fileExists(atPath: root + "/Library")
                    || fm.fileExists(atPath: root + "/basebin") {
                    return root
                }
            }
        }
        return nil
    }
}
