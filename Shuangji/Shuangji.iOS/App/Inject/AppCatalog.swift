import Foundation
import UIKit

/// 应用列表（私有 API，对齐 TrollFools / LSApplicationWorkspace 用法）
enum AppCatalog {

    static func load() -> [AppEntry] {
        var result: [AppEntry] = []
        let workspace: AnyObject? = {
            let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type
            let sel = NSSelectorFromString("defaultWorkspace")
            guard let cls, cls.responds(to: sel) else { return nil }
            return cls.perform(sel)?.takeUnretainedValue()
        }()
        guard let workspace else { return result }

        let allSel = NSSelectorFromString("allApplications")
        guard workspace.responds(to: allSel),
              let apps = workspace.perform(allSel)?.takeUnretainedValue() as? [NSObject]
        else { return result }

        let markName = BuiltinInjector.markerLoadName

        for proxy in apps {
            guard let bid = proxy.value(forKey: "applicationIdentifier") as? String,
                  let url = proxy.value(forKey: "bundleURL") as? URL
            else { continue }
            if bid.hasPrefix("com.apple.") { continue }

            let name = (proxy.value(forKey: "localizedName") as? String)
                ?? (proxy.value(forKey: "itemName") as? String)
                ?? bid
            let ver = (proxy.value(forKey: "shortVersionString") as? String) ?? ""
            let appType = (proxy.value(forKey: "applicationType") as? String) ?? "User"
            let injected = BuiltinInjector.isInjected(bundleURL: url, marker: markName)

            result.append(AppEntry(
                bundleID: bid,
                name: name,
                version: ver,
                bundleURL: url,
                isUser: appType == "User",
                isInjected: injected
            ))
        }

        return result.sorted {
            if $0.isInjected != $1.isInjected { return $0.isInjected && !$1.isInjected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
