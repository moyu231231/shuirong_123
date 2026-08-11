import Foundation
import UIKit

struct AppEntry: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let version: String
    let bundleURL: URL
    /// 应用沙盒 Data 容器（清理设备标识用）
    let dataContainerPath: String
    let isUser: Bool
    let teamID: String
    var isInjected: Bool

    var icon: UIImage? { nil }
}
