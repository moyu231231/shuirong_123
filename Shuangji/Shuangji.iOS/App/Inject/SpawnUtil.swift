import Foundation
import Darwin

enum SpawnUtil {
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

    static func killall(_ name: String) {
        _ = run("/usr/bin/killall", args: ["-9", name])
    }
}
