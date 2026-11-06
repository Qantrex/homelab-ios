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

    /// On school mornings (Mon-Fri 05:30-09:00) ask for a run sooner, so the "Leave by" activity follows the pick.
    /// iOS still decides when; this is only the earliest it may run.
    static func interval(now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let weekday = (2...6).contains(c.weekday ?? 1)
        return weekday && (5 * 60 + 30..<9 * 60).contains(minutes) ? 10 * 60 : 20 * 60
    }

    public static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval())
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.notice("background schedule failed: \(error.localizedDescription)")
        }
    }

    /// The work of one run. Separate from the scheduler so it can be called from tests or a debug button.
    public static func run(storage: Storage = .shared(), tokens: any TokenStore = KeychainTokenStore(),
                           transport: any HTTPTransport = URLSessionTransport()) async {
        schedule()
        await refresh(storage: storage, tokens: tokens, transport: transport)
        await updateLeaveActivity(storage: storage)
        // Then shares and scans the app couldn't send earlier (the extension stores them in the App Group): after the
        // refresh, so a slow upload can't eat the ~30 s and cancel it, and only small PDFs (the app sends big ones).
        let list0 = storage.read(ServerList.self, ServerList.fileName) ?? ServerList()
        await Outbox(directory: storage.url("outbox")).drain(servers: list0, maxPDFBytes: 2 * 1024 * 1024) { (server: ServerConfig) -> any CompanionAPI in
            if server.kind == .demo { return DemoBackend(delay: .zero) }
            return CompanionClient(config: server, tokens: tokens, transport: transport)
        }
    }

    /// Update or end the "Leave by" activity from the newest data. Never starts one (iOS refuses that from here).
    static func updateLeaveActivity(storage: Storage) async {
        let settings = storage.read(AppSettings.self, AppSettings.fileName) ?? AppSettings()
        let list = storage.read(ServerList.self, ServerList.fileName) ?? ServerList()
        let plan = list.selectedServer.flatMap { storage.read(Snapshot.self, Snapshot.fileName($0.id)) }?.state.commute
        await LeaveActivityController.apply(plan: plan, enabled: settings.leaveByOn, foreground: false, storage: storage)
    }

    static func refresh(storage: Storage, tokens: any TokenStore, transport: any HTTPTransport) async {
        let settings = storage.read(AppSettings.self, AppSettings.fileName) ?? AppSettings()
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
            let alerts = tracker.update(with: state, server: snap.serverName, serverID: server.id,
                                        options: .init(problems: settings.notifyProblems, pending: settings.notifyPending))
            try? storage.write(tracker, AlertTracker.fileName)
            if settings.notificationsOn {
                for a in alerts { await Notifier.post(a, private: settings.faceIDLock, voice: settings.voice) }
            }
            result = "ok, \(state.problems.count) problems, \(state.pending.count) pending, \(alerts.count) alerts"
        } catch {
            result = APIError.from(error, host: server.host).message
        }
        // Re-read: the user may have changed a setting during the network call. Only our two fields change.
        var latest = storage.read(AppSettings.self, AppSettings.fileName) ?? settings
        latest.lastBackgroundRun = Date()
        latest.lastBackgroundResult = result
        try? storage.write(latest, AppSettings.fileName)
    }
}

enum Notifier {
    /// `private`: the app lock is on, so the lock screen only says that something happened.
    /// `voice`: the personality's line as the subtitle (not when private).
    static func post(_ alert: AlertTracker.Alert, private hidden: Bool, voice: Personality = .off) async {
        let content = UNMutableNotificationContent()
        content.title = hidden ? "Homelab" : alert.title
        if !hidden, let m = alert.moment, let line = Voice.line(m, voice) { content.subtitle = line }
        content.body = hidden
            ? (alert.kind == .pending ? String(localized: "An action is waiting for you.") : String(localized: "Something needs a look."))
            : alert.body
        content.sound = alert.kind == .problem ? .default : nil
        content.threadIdentifier = alert.kind.rawValue
        // Same links as the agent's pushes: proposals open Actions, problems open Lab.
        content.userInfo = ["link": alert.kind == .pending ? "homelab://actions" : "homelab://lab"]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Taps on notifications open the right tab. A tap that arrives before the UI is ready (cold start) is kept and
/// delivered once `open` is set.
@MainActor
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationRouter()
    private var pending: URL?

    public var open: ((URL) -> Void)? {
        didSet {
            if let url = pending, let open {
                pending = nil
                open(url)
            }
        }
    }

    public func route(_ url: URL) {
        guard url.scheme == "homelab" else { return }
        if let open { open(url) } else { pending = url }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["link"] as? String,
              let url = URL(string: link) else { return }
        await route(url)
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

enum UIDeviceInfo {
    @MainActor static var version: String { UIDevice.current.systemVersion }
}

enum UIPasteboardBridge {
    /// This device only (no Universal Clipboard to the Mac), and gone after 10 minutes.
    @MainActor static func copy(_ text: String) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
    }
}
