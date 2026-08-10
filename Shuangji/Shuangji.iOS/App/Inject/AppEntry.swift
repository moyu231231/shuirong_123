import Foundation
import UIKit

struct AppEntry: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let version: String
    let bundleURL: URL
    let isUser: Bool
    let teamID: String
    var isInjected: Bool

    var icon: UIImage? { nil }
}
