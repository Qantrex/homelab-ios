import Foundation
import Testing
@testable import HomelabKit

extension OwnerInvarianceTests {
    /// O3 (docs/plans/MODULAR.md): with the owner's servers and settings, no first-run screen, start tip, "Hidden now"
    /// line or rule context appears, and Today reads Home Assistant as before (Home shown, every 30 s). The Settings
    /// rows the modular work added and that show for this setup are listed here on purpose: the owner chose Where you
    /// are, Quiet hours and the show rules (the rule under each section and its sheet). A new row for this setup
    /// has to be added here, knowingly.
    @Test func noNewSurfaces() throws {
        let storage = Storage(directory: temporaryDirectory())
        try Storage.encoder.encode(Self.ownerServers()).write(to: storage.url(ServerList.fileName))
        try Storage.encoder.encode(Self.ownerSettings()).write(to: storage.url(AppSettings.fileName))
        let (m, _, _, _) = makeModel(storage: storage)
        let now = Date()

        // No new screen, prompt or line on Today.
        #expect(m.hasServers && m.firstRun == nil && !m.showsStartTip)
        #expect(m.settings.todayLayout.rules == nil && !m.presenceSetUp && !m.todayNeedsContext)
        let today = m.todaySections(now: now, homeEntities: { [] }, fetched: { nil })
        #expect(today.context == nil && today.sections == m.settings.todayDensity.sections(m.settings.todayLayout))
        #expect(m.hiddenOnToday(m.todayContext(now: now), now: now).isEmpty)
        #expect(m.pollsHome(shown: today.sections) && HomePoll.interval == 30)

        // The Settings rows added by M3 that show for this setup, as chosen by the owner.
        let rows = [("Where you are", m.showsPresenceRow), ("Quiet hours", m.settings.showsQuietHoursRow)]
        #expect(rows.filter(\.1).map(\.0) == ["Where you are", "Quiet hours"])
        #expect(m.settings.quietHours == nil && m.settings.presenceEntity == nil)                    // both off
        // The rule sheet offers no presence rules until Where you are is set.
        #expect(m.ruleKinds(for: .deals) == [.always, .needsMe, .times])
        #expect(m.settings.todayLayout.sections.allSatisfy { m.settings.todayLayout.ruleWords(for: $0) == ($0 == .machines ? "Only in Overkill" : "Always") })
    }
}
