import BackgroundTasks
import SpikeShared
import SwiftUI
import WidgetKit

@main
struct HomelabApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastDeepLink: String?

    var body: some Scene {
        WindowGroup {
            SpikeView(lastDeepLink: $lastDeepLink)
                .onOpenURL { lastDeepLink = $0.absoluteString }   // widget tap → homelab://spike
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Background.schedule() }
        }
        // Test S6: iOS decides when this runs (hours, sometimes a day). Each run is counted in the shared file.
        .backgroundTask(.appRefresh(Background.identifier)) {
            await Background.run()
        }
    }
}

enum Background {
    static let identifier = "com.qantrex.homelab.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            let group = AppGroup.resolve().group
            SpikeStore.update(group: group) { $0.lastBackgroundResult = "schedule failed: \(error)" }
        }
    }

    static func run() async {
        schedule()   // keep the chain going
        let group = AppGroup.resolve().group
        let url = SpikeStore.load(group: group).probeURL
        let probe = url.isEmpty ? nil : await NetworkProbe.run(url, timeout: 20)
        SpikeStore.update(group: group) {
            $0.backgroundRuns += 1
            $0.lastBackgroundRun = Date()
            $0.lastBackgroundResult = probe?.summary ?? "no URL set"
            $0.writer = "background"
            $0.lastWrite = Date()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
