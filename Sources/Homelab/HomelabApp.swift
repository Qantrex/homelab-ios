import HomelabKit
import HomelabUI
import SwiftUI
import UserNotifications

@main
struct HomelabApp: App {
    @State private var model = AppModel.live()
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
            // Always: the widget and the cached overview profit even when notifications are off.
            if phase == .background, model.selected != nil { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}
