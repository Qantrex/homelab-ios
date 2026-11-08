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
        let api: any CompanionAPI = server.kind == .demo
            ? DemoBackend(delay: .zero) : CompanionClient(config: server, tokens: tokens, transport: transport)
        do {
            let state = try await api.state()
            let old = storage.read(Snapshot.self, Snapshot.fileName(server.id))
            let snap = Snapshot(serverID: server.id, serverName: old?.serverName ?? server.name, state: state, info: old?.info)
            try? storage.write(snap, Snapshot.fileName(server.id))
            try? storage.write(snap, Snapshot.widgetFileName)
            WidgetCenter.shared.reloadAllTimelines()

            var tracker = storage.read(AlertTracker.self, AlertTracker.fileName) ?? AlertTracker()
            // Deals only when the owner wants a notification for them. No list (404: the server has none, or a failed
            // request) changes nothing in the tracker, so a bad connection can't make old deals look new.
            let deals: DealList? = settings.notifyDeals ? (try? await api.deals()) : nil
            let alerts = tracker.update(with: state, deals: deals, server: snap.serverName, serverID: server.id,
                                        options: .init(problems: settings.notifyProblems, pending: settings.notifyPending,
                                                       deals: settings.notifyDeals, dealCategories: settings.dealCategories))
            try? storage.write(tracker, AlertTracker.fileName)
            // None while notifications are off or quiet hours hold (the tracker has learned them all the same).
            let now = Date()
            for a in settings.notificationsToPost(alerts, now: now) {
                // Hyperdetail: the fields of what it is about and a remark, in the body.
                let extra = settings.todayDensity.isHyper
                    ? Hyper.noticeExtra(a, state: state, deals: deals, personality: settings.voice, now: now) : nil
                await Notifier.post(a, server: server.id, private: settings.faceIDLock, voice: settings.voice, extra: extra)
            }
            // The Start list for the Home-screen quick actions (the app writes it too; the action list itself
            // isn't cached): only from a server known to offer it.
            if old?.info?.features.contains(.runActions) == true, let list = try? await api.actions() {
                var usage = storage.read(ActionUsage.self, ActionUsage.fileName) ?? ActionUsage()
                if usage.setOffered(list, server: server.id) { try? storage.write(usage, ActionUsage.fileName) }
            }
            result = settings.backgroundResult(problems: state.problems.count, pending: state.pending.count,
                                               alerts: alerts.count, now: now)
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
    /// `private`: the app lock is on, so the notification only says that something happened, except a proposal with
    /// Approve / Deny: it names its action and keeps its buttons (they need Face ID; iOS hides the preview on the
    /// locked lock screen by default). `voice`: the personality's line as the subtitle (not when private).
    /// What it says and which buttons it gets: `ProposalNotice.content`.
    static func post(_ alert: AlertTracker.Alert, server: UUID, private hidden: Bool, voice: Personality = .off,
                     extra: String? = nil) async {
        let shown = ProposalNotice.content(for: alert, locked: hidden, voice: voice, extra: extra)
        let content = UNMutableNotificationContent()
        content.title = shown.title
        if let line = shown.subtitle { content.subtitle = line }
        content.body = shown.body
        content.sound = alert.kind == .problem ? .default : nil
        content.threadIdentifier = alert.kind.rawValue
        // Same links as the agent's pushes: proposals open Actions, problems open Lab.
        var info: [String: String] = ["link": Self.link(for: alert.kind)]
        if let proposal = alert.proposal, let category = shown.category {
            content.categoryIdentifier = category.rawValue
            info.merge(ProposalNotice.userInfo(server: server, proposal: proposal.id)) { old, _ in old }
        }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Where a tap goes: a proposal opens Actions, a deal the Deals screen (the same link as the server's push),
    /// anything else Lab.
    static func link(for kind: AlertTracker.Alert.Kind) -> String {
        switch kind {
        case .pending: "homelab://actions"
        case .deal: "homelab://deals"
        case .problem, .summary: "homelab://lab"
        }
    }

    /// The short answer after Approve / Deny on a notification. Tapping it opens Actions.
    static func postResult(_ message: (title: String, body: String), id: String) async {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = AlertTracker.Alert.Kind.pending.rawValue
        content.userInfo = ["link": "homelab://actions"]
        let request = UNNotificationRequest(identifier: "result-\(id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The Approve / Deny buttons, one category per set of buttons a proposal can have. Both need Face ID or the
    /// passcode first (`authenticationRequired`), also with the app lock on; Deny is red. Neither opens the app: the
    /// press runs in the background.
    static func registerCategories() {
        let approve = UNNotificationAction(identifier: ProposalNotice.approveAction, title: String(localized: "Approve"),
                                           options: [.authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: ProposalNotice.denyAction, title: String(localized: "Deny"),
                                        options: [.authenticationRequired, .destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let categories = ProposalNotice.Category.allCases.map { c in
            UNNotificationCategory(identifier: c.rawValue, actions: c.verbs.map { $0 == .deny ? deny : approve },
                                   intentIdentifiers: [], options: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }
}

/// Approve / Deny pressed on a proposal notification: finds the signed button again, presses it through the API,
/// posts the result and refreshes. Runs while the app is in the background (or not running: iOS launches it).
enum ProposalPress {
    static func run(_ request: ProposalNotice.Request, storage: Storage = .shared(),
                    tokens: any TokenStore = KeychainTokenStore(),
                    transport: any HTTPTransport = URLSessionTransport()) async {
        let settings = storage.read(AppSettings.self, AppSettings.fileName) ?? AppSettings()
        let list = storage.read(ServerList.self, ServerList.fileName) ?? ServerList()
        let id = "\(request.proposal)-\(request.verb.rawValue)"
        // No check of the app lock here: iOS ran this only after Face ID or the passcode (`authenticationRequired`).
        // With the lock on, the result below stays vague.
        guard let server = list.servers.first(where: { $0.id == request.server && $0.speaksCompanionAPI }) else {
            await Notifier.postResult(("Homelab", String(localized: "That server is no longer in Homelab.")), id: id)
            return
        }
        let api: any CompanionAPI = server.kind == .demo
            ? DemoBackend(delay: .zero) : CompanionClient(config: server, tokens: tokens, transport: transport)
        let snap = storage.read(Snapshot.self, Snapshot.fileName(server.id))
        let outcome = await ProposalNotice.press(request, api: api, cached: snap?.state, host: server.host)
        let hasChat = snap?.info?.features.contains(.chat) ?? false
        await Notifier.postResult(ProposalNotice.message(outcome, verb: request.verb, server: snap?.serverName ?? server.name,
                                                         hidden: settings.faceIDLock, hasChat: hasChat), id: id)
        // Fresh data for the badge, the widget and the open app: through the app's model when it runs, else like a
        // background refresh (that one only fetches the shown server).
        if let refresh = await NotificationRouter.shared.refresh {
            await refresh(server.id)
        } else if list.selectedServer?.id == server.id {
            await BackgroundRefresh.refresh(storage: storage, tokens: tokens, transport: transport)
        }
    }
}

/// Taps on notifications open the right tab. A tap that arrives before the UI is ready (cold start) is kept and
/// delivered once `open` is set. Approve / Deny on a proposal notification runs `ProposalPress` instead.
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

    /// Refreshes a server in the running app (its model) after a notification's button press.
    public var refresh: (@MainActor (UUID) async -> Void)?

    /// Call once at launch, before the first notification can be answered.
    public static func registerCategories() { Notifier.registerCategories() }

    public func route(_ url: URL) {
        guard url.scheme == "homelab" else { return }
        if let open { open(url) } else { pending = url }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let request = ProposalNotice.Request(actionID: response.actionIdentifier, userInfo: info) {
            // Keep running if the owner leaves the notification at once; iOS ends the task when time is up.
            // When time is up the handler cancels the press and ends the task (iOS would kill the app otherwise).
            let work = Task { await ProposalPress.run(request) }
            let task = await ExtraTime.begin("proposal-press") { work.cancel() }
            await work.value
            await ExtraTime.end(task)
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = info["link"] as? String, let url = URL(string: link) else { return }
        await route(url)
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Extra background time for work that outlives a notification button. `onExpiry` runs when iOS takes it back and
/// the task ends right after it.
enum ExtraTime {
    @MainActor final class Handle {
        var id = UIBackgroundTaskIdentifier.invalid
    }

    @MainActor static func begin(_ name: String, onExpiry: @escaping @Sendable () -> Void) -> Handle {
        let handle = Handle()
        handle.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                onExpiry()
                end(handle)
            }
        }
        return handle
    }

    @MainActor static func end(_ handle: Handle) {
        guard handle.id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(handle.id)
        handle.id = .invalid
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
