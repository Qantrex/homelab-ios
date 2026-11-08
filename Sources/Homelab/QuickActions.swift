import HomelabDesign
import HomelabKit
import HomelabUI
import SwiftUI
import UIKit

/// The Home-screen quick actions (long-press the app icon). "Scan document" is static (UIApplicationShortcutItems in
/// App-Info.plist); after it come up to three dynamic ones, the shown server's most used Start actions
/// (`HomeShortcuts`, `ActionUsage` in the App Group), each opening `homelab://actions/<name>`. SwiftUI has no hook for
/// them, so a small app delegate gives the scene a delegate class that receives the shortcut. A launch from a
/// shortcut waits in NotificationRouter until the UI is ready.
@MainActor
enum QuickActions {
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let url = HomeShortcuts.link(type: item.type, userInfo: item.userInfo?.mapValues { $0 as Any }) else {
            return false
        }
        NotificationRouter.shared.route(url)
        return true
    }

    /// Sets the dynamic quick actions from shared storage: after a refresh (app or background), an action start and
    /// a server switch.
    static func update(storage: Storage = .shared()) {
        let usage = storage.read(ActionUsage.self, ActionUsage.fileName) ?? ActionUsage()
        let list = storage.read(ServerList.self, ServerList.fileName) ?? ServerList()
        let settings = storage.read(AppSettings.self, AppSettings.fileName)
        let items = HomeShortcuts.items(usage, server: list.selectedServer?.id, tiles: settings?.startTiles).map { item in
            UIApplicationShortcutItem(type: item.type, localizedTitle: item.title, localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: Symbols.safe(item.icon, fallback: "play.circle")),
                                      userInfo: ["link": item.link.absoluteString as NSString])
        }
        UIApplication.shared.shortcutItems = items
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
