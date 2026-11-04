import HomelabKit
import HomelabUI
import SwiftUI
import UserNotifications

@main
struct HomelabApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { model.open($0) }   // widget taps and homelab:// links
                .onAppear {
                    NotificationRouter.shared.open = { [model] url in model.open(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, model.settings.notificationsOn { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}
