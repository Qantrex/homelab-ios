import HomelabDesign
import HomelabKit
import HomelabUI
import SwiftUI
import UIKit
import UserNotifications

@main
struct HomelabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        NotificationRouter.registerCategories()   // Approve / Deny on "waiting for you" notifications
        // The Actions badge says "waiting for you": love like every other status, not the system red (research #8).
        UITabBarItem.appearance().badgeColor = UIColor(Palette.love)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { model.open($0) }   // widget taps and homelab:// links
                .onAppear {
                    NotificationRouter.shared.open = { [model] url in model.open(url) }
                    NotificationRouter.shared.refresh = { [model] id in
                        if let server = model.servers.servers.first(where: { $0.id == id }) { await model.refresh(server) }
                    }
                    model.onQuickActionsChange = { QuickActions.update() }
                    QuickActions.update()
                }
                .onChange(of: model.selected?.id) { QuickActions.update() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Always: the widget and the cached overview profit even when notifications are off.
            if phase == .background, model.selected != nil { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
            await QuickActions.update()
        }
    }
}
