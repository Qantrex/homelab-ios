import Foundation
import HomelabKit

/// Where the widgets get their data (step 6c): the snapshot the app wrote, and, for an identity (Tailscale) server, a
/// fresh `/state` fetched by the widget itself when that snapshot is older than 5 minutes. Every widget kind runs its
/// own timeline, so the shared snapshot is what keeps it to about one GET per 15 minutes.
///
/// Never reads the Keychain: the client gets an empty token store, and token servers are skipped (`WidgetPolicy`).
/// Writes only `widget-snapshot.json` (and a small log for Diagnostics), never `snapshot-<id>.json`, `servers.json`
/// or `settings.json`.
enum WidgetData {
    static func current(now: Date = Date()) async -> Snapshot? {
        let storage = Storage.shared()
        let cached = storage.read(Snapshot.self, Snapshot.widgetFileName)
        guard let list = storage.read(ServerList.self, ServerList.fileName), let server = list.selectedServer,
              WidgetPolicy.mayFetch(server: server) else { return cached }
        // A snapshot of another server (the selection changed) counts as none.
        let mine = cached?.serverID == server.id ? cached : nil
        guard WidgetPolicy.shouldFetch(snapshot: mine, now: now) else { return cached }
        do {
            let client = CompanionClient(config: server, tokens: MemoryTokenStore(), transport: URLSessionTransport.widget)
            let state = try await client.state()
            let snap = Snapshot(serverID: server.id, serverName: mine?.serverName ?? server.name, state: state,
                                info: mine?.info, fetched: Date())
            // The app may have written a newer one meanwhile.
            let latest = storage.read(Snapshot.self, Snapshot.widgetFileName)
            if WidgetPolicy.shouldWrite(snap, over: latest, selected: list.selectedServer?.id) {
                try? storage.write(snap, Snapshot.widgetFileName)
            }
            storage.log(RunLog.widgetFetch, "ok")
            return snap
        } catch {
            storage.log(RunLog.widgetFetch, APIError.from(error, host: server.host).message)
            return cached
        }
    }
}
