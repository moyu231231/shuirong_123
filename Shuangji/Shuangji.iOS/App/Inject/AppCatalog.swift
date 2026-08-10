import Foundation
import UIKit

/// 应用列表（私有 API，对齐 TrollFools / LSApplicationWorkspace）
enum AppCatalog {

    static func load() -> [AppEntry] {
        let raw = SYFetchInstalledApplications()
        let markName = BuiltinInjector.markerLoadName
        var result: [AppEntry] = []
        result.reserveCapacity(raw.count)

        for case let item as NSDictionary in raw {
            guard let bid = item["bundleID"] as? String,
                  let path = item["bundlePath"] as? String,
                  !path.isEmpty
            else { continue }

            if bid == "com.shuiyong.ports" { continue }
            if bid.hasPrefix("com.apple.") { continue }

            let name: String = {
                if let n = item["name"] as? String, !n.isEmpty { return n }
                return bid
            }()
            let ver = (item["version"] as? String) ?? ""
            let appType = (item["appType"] as? String) ?? "User"
            let team = (item["teamID"] as? String) ?? ""
            let url = URL(fileURLWithPath: path)
            let injected = BuiltinInjector.isInjected(bundleURL: url, marker: markName)

            result.append(AppEntry(
                bundleID: bid,
                name: name,
                version: ver,
                bundleURL: url,
                isUser: appType == "User",
                teamID: team,
                isInjected: injected
            ))
        }

        return result.sorted {
            if $0.isInjected != $1.isInjected { return $0.isInjected && !$1.isInjected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
