import HomelabUI
import SwiftUI
import UIKit

/// The Home-screen quick action "Scan document" (UIApplicationShortcutItems in App-Info.plist). SwiftUI has no hook
/// for it, so a small app delegate gives the scene a delegate class that receives the shortcut. It opens the same
/// place as the link homelab://scan; a launch from the shortcut waits in NotificationRouter until the UI is ready.
@MainActor
enum QuickActions {
    static let scanType = "com.qantrex.homelab.scan"

    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == scanType, let url = URL(string: "homelab://scan") else { return false }
        NotificationRouter.shared.route(url)
        return true
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // A cold start from the shortcut arrives here, not in the scene delegate.
        if let item = options.shortcutItem { QuickActions.handle(item) }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActions.handle(shortcutItem))
    }
}
