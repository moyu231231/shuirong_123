import Foundation
import Darwin

enum SpawnUtil {
    /// 普通 spawn（不提权）
    @discardableResult
    static func run(_ path: String, args: [String]) -> Int32 {
        var cArgs = ([path] + args).map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        let rc = cArgs.withUnsafeMutableBufferPointer { buf -> Int32 in
            posix_spawn(&pid, path, nil, nil, buf.baseAddress, environ)
        }
        if rc != 0 { return rc }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0xff
    }

    /// root persona spawn（写别人 App 包必须走这个）
    @discardableResult
    static func rootRun(_ path: String, args: [String]) -> (code: Int32, out: String, err: String) {
        var out: NSString?
        var err: NSString?
        let code = SYSpawnRoot(path, args, &out, &err)
        return (code, (out as String?) ?? "", (err as String?) ?? "")
    }

    static func killall(_ name: String) {
        // killall 也可能需要 root；先试普通，再试 root
        if run("/usr/bin/killall", args: ["-9", name]) != 0 {
            _ = rootRun("/usr/bin/killall", args: ["-9", name])
        }
    }
}
