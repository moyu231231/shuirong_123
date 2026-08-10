import Foundation

enum SpawnUtil {
    @discardableResult
    static func run(_ path: String, args: [String]) -> Int32 {
        var argv = [path] + args
        return argv.withUnsafeBufferPointer { buf -> Int32 in
            let cStrings = buf.map { strdup($0) } + [nil]
            defer { cStrings.forEach { if let p = $0 { free(p) } } }
            var mutable = cStrings
            var pid: pid_t = 0
            let rc = posix_spawn(&pid, path, nil, nil, &mutable, environ)
            if rc != 0 { return rc }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return (status >> 8) & 0xff
        }
    }

    static func killall(_ name: String) {
        _ = run("/usr/bin/killall", args: ["-9", name])
    }
}
