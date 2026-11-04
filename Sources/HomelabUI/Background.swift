import BackgroundTasks
import Foundation
import HomelabKit
import UIKit
import UserNotifications
import WidgetKit

/// Background refresh: fetch the shown server's state, update the snapshot and widget, and send local notifications
/// for NEW problems or actions (AlertTracker). iOS decides when it runs; nothing here relies on exact timing.
public enum BackgroundRefresh {
    public static let identifier = "com.qantrex.homelab.refresh"

    public static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.notice("background schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The work of one run. Separate from the scheduler so it can be called from tests or a debug button.
    public static func run(storage: Storage = .shared(), tokens: any TokenStore = KeychainTokenStore(),
                           transport: any HTTPTransport = URLSessionTransport()) async {
        schedule()
        var settings = storage.read(AppSettings.self, AppSettings.fileName) ?? AppSettings()
        let list = storage.read(ServerList.self, ServerList.fileName) ?? ServerList()
        guard let server = list.selectedServer else { return }
        let result: String
        do {
            let state: HomelabState
            if server.kind == .demo {
                state = try await DemoBackend(delay: .zero).state()
            } else {
                state = try await CompanionClient(config: server, tokens: tokens, transport: transport).state()
            }
            let old = storage.read(Snapshot.self, Snapshot.fileName(server.id))
            let snap = Snapshot(serverID: server.id, serverName: old?.serverName ?? server.name, state: state, info: old?.info)
            try? storage.write(snap, Snapshot.fileName(server.id))
            try? storage.write(snap, Snapshot.widgetFileName)
            WidgetCenter.shared.reloadAllTimelines()

            var tracker = storage.read(AlertTracker.self, AlertTracker.fileName) ?? AlertTracker()
            let alerts = tracker.update(with: state, server: snap.serverName,
                                        options: .init(problems: settings.notifyProblems, pending: settings.notifyPending))
            try? storage.write(tracker, AlertTracker.fileName)
            if settings.notificationsOn {
                for a in alerts { await Notifier.post(a) }
            }
            result = "ok, \(state.problems.count) problems, \(state.pending.count) pending, \(alerts.count) alerts"
        } catch {
            result = APIError.from(error, host: server.host).message
        }
        settings.lastBackgroundRun = Date()
        settings.lastBackgroundResult = result
        try? storage.write(settings, AppSettings.fileName)
    }
}

enum Notifier {
    static func post(_ alert: AlertTracker.Alert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.kind == .problem ? .default : nil
        content.threadIdentifier = alert.kind.rawValue
        content.userInfo = ["link": alert.kind == .pending ? "homelab://actions" : "homelab://overview"]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Taps on notifications open the right tab.
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationRouter()
    public var open: (@MainActor (URL) -> Void)?

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["link"] as? String,
              let url = URL(string: link) else { return }
        await MainActor.run { open?(url) }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

enum UIDeviceInfo {
    @MainActor static var version: String { UIDevice.current.systemVersion }
}

enum UIPasteboardBridge {
    @MainActor static func copy(_ text: String) { UIPasteboard.general.string = text }
}
