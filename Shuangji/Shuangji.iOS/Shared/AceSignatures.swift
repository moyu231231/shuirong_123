import Foundation

/// 与 PC 端 Port65010 / NJ 规则对齐的线缆特征（tersafe CS + NJ）。
/// TrollStore 无进程注入，只能在隧道里按字节特征处理。
public enum AceSignatures {

    /// 65010 上行举报头：33 66 00 0B 00 0C 40 13
    public static let header4013: [UInt8] = [0x33, 0x66, 0x00, 0x0B, 0x00, 0x0C, 0x40, 0x13]

    /// NJ 上行举报体：01 00 00 0E … 0A 92（解密目标）
    public static let njReport0E: [UInt8] = [0x01, 0x00, 0x00, 0x0E]
    public static let marker0A92: [UInt8] = [0x0A, 0x92]

    public static let nj23: [UInt8] = [0x01, 0x0A, 0x00, 0x23]
    public static let nj09: [UInt8] = [0x01, 0x0A, 0x00, 0x09]

    public static func contains4013(_ data: Data) -> Bool {
        contains(data, header4013)
    }

    /// 01 00 00 0E 后 64 字节内出现 0A 92
    public static func containsNjReport0E(_ data: Data) -> Bool {
        guard data.count >= 20 else { return false }
        let bytes = [UInt8](data)
        let n = min(bytes.count, 65536)
        var i = 0
        while i <= n - 4 {
            if bytes[i] == 0x01, bytes[i + 1] == 0x00,
               bytes[i + 2] == 0x00, bytes[i + 3] == 0x0E {
                let lim = min(i + 64, n - 1)
                var j = i + 4
                while j < lim {
                    if bytes[j] == 0x0A, bytes[j + 1] == 0x92 { return true }
                    j += 1
                }
            }
            i += 1
        }
        return false
    }

    /// 本机轻洗：01 0A 00 23/09 → 01 0A 00 00（对齐 WPE ACE_Filter）
    public static func neuterNjMarkers(_ data: inout Data) -> Bool {
        guard data.count >= 4 else { return false }
        var changed = false
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while i <= n - 4 {
                if base[i] == 0x01, base[i + 1] == 0x0A, base[i + 2] == 0x00,
                   base[i + 3] == 0x23 || base[i + 3] == 0x09 {
                    base[i + 3] = 0x00
                    changed = true
                }
                i += 1
            }
        }
        return changed
    }

    public static func isWatchPort(_ port: Int) -> Bool {
        switch port {
        case 80, 443, 8080, 8443, 10011, 10012, 10013, 65010:
            return true
        default:
            return false
        }
    }

    public static func isInterestingHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if AceCdnRulesSwift.isBlackholeIp(h) { return true }
        return AceCdnRulesSwift.looksAceOrCdnHost(h) || h.contains("tencent")
    }

    public static func shouldDropAceCdn(_ host: String) -> Bool {
        AceCdnRulesSwift.shouldDropConnect(host)
    }

    public static func contains(_ data: Data, _ pat: [UInt8]) -> Bool {
        guard data.count >= pat.count else { return false }
        let bytes = [UInt8](data)
        let n = min(bytes.count, 65536)
        let plen = pat.count
        var i = 0
        while i <= n - plen {
            var ok = true
            for k in 0..<plen {
                if bytes[i + k] != pat[k] { ok = false; break }
            }
            if ok { return true }
            i += 1
        }
        return false
    }
}

/// 与 PC 端 AceCdnRules.cs 对齐的关键字 / IP 黑洞。
enum AceCdnRulesSwift {
    static let hostNeedles: [String] = [
        "anticheatexpert", "cschannel", "acesdk", "mrpcs", "tsssdk", "tss.",
        "ano.", "anogs", "iescdn", "qcloud", "cdn-tencent", "tencentcdn",
        "nj.", "gcloudsdk", "tdm.", "tp2.",
    ]
    static let ipBlackhole: [String] = [
        "183.2.172.46",
    ]

    static func looksAceOrCdnHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if isBlackholeIp(h) { return true }
        for n in hostNeedles where h.contains(n) { return true }
        return false
    }

    static func isBlackholeIp(_ hostOrIp: String) -> Bool {
        var s = hostOrIp.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("["), s.hasSuffix("]") {
            s = String(s.dropFirst().dropLast())
        }
        let low = s.lowercased()
        return ipBlackhole.contains { $0.lowercased() == low }
    }

    static func shouldDropConnect(_ host: String) -> Bool {
        looksAceOrCdnHost(host)
    }
}
