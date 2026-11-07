import Foundation
import Testing
@testable import HomelabKit

/// Bugs found by the review of the app side of docs/plans/MODULAR.md (M3, 2026-11-07), each kept fixed by a test:
/// Home Assistant read only while the Home tiles were on screen, settings lost for one unreadable new key, and Today
/// redone on every Home Assistant read without any rule.
@MainActor @Suite(.serialized) struct ModularReviewFixTests {
    let now = ServerDate.parse("2026-11-07T12:00:00Z")!
    let haURL = URL(string: "https://ha.example.ts.net")!

    /// A model with a Home Assistant (one pinned light) and, unless `companion` is false, a Companion server.
    func model(companion: Bool = true) throws -> AppModel {
        let (m, _, _, _) = makeModel()
        try m.save(ServerConfig(name: "HA", kind: .homeAssistant, baseURL: haURL, auth: .token,
                                pinnedEntities: ["light.desk"]), token: "llat")
        if companion {
            try m.save(ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity), token: nil)
        }
        #expect((m.selected != nil) == companion && m.homeAssistant != nil)
        return m
    }

    // MARK: Home Assistant is read while anything on Today needs it

    @Test func homePollsWhileAnythingOnTodayNeedsIt() {
        func polls(ha: Bool = true, shown: Bool = false, visible: Bool = true, rule: ShowRule? = nil,
                   companion: Bool = true, presence: Bool = false) -> Bool {
            HomePoll.shouldPoll(homeAssistant: ha, homeShown: shown, homeVisible: visible, homeRule: rule,
                                companionSelected: companion, presenceSetUp: presence)
        }
        #expect(polls(shown: true))                                   // the owner: Home shown, as before
        #expect(!polls())                                             // Home hidden, a Companion server, no presence
        #expect(polls(rule: .needsMe))                                // hidden by its rule until a tile is unavailable
        #expect(!polls(visible: false, rule: .needsMe))               // turned off: the rule doesn't matter
        #expect(!polls(rule: .times(.evenings)))                      // a time rule: only while it shows
        #expect(polls(companion: false))                              // the headline reads Home Assistant
        #expect(polls(presence: true))                                // Where you are
        #expect(!polls(ha: false, shown: true, companion: false, presence: true))
        #expect(HomePoll.interval == 30)
    }

    /// The review's probe: Home set to "When it needs me" starts hidden (nothing is unavailable yet), and nothing used
    /// to read Home Assistant then, so it could never show. Now Today reads it, and an unavailable tile brings it in.
    @Test func homeNeedsMeShowsOnceAPinnedTileIsUnavailable() throws {
        let m = try model()
        m.settings.todayLayout.setRule(.needsMe, for: .home)
        for density in [Density.standard, .calm] {
            m.settings.todayDensity = density
            let before = m.todaySections(now: now, homeEntities: { [] }, fetched: { nil }).sections
            #expect(!before.contains(.home), "\(density)")
            #expect(m.pollsHome(shown: before), "\(density)")
            let states = [HAEntity(entityID: "light.desk", state: "unavailable")]
            let after = m.todaySections(now: now, homeEntities: { states }, fetched: { now }).sections
            #expect(after.contains(.home), "\(density)")
        }
        m.settings.todayLayout.setVisible(.home, false)
        #expect(!m.pollsHome(shown: []))
    }

    @Test func ownerShapedTodayPollsOnlyWithHomeShown() throws {
        let m = try model()
        #expect(m.pollsHome(shown: m.todaySections(now: now, homeEntities: { [] }, fetched: { nil }).sections))
        m.settings.todayLayout.setVisible(.home, false)
        #expect(!m.pollsHome(shown: m.todaySections(now: now, homeEntities: { [] }, fetched: { nil }).sections))
    }

    /// Without a Companion server the headline reads Home Assistant: also while Home is hidden, and only from recent
    /// states (else the grey "Home." it said before the first read).
    @Test func homeHeadlineNeedsRecentStates() throws {
        let m = try model(companion: false)
        m.settings.todayLayout.setVisible(.home, false)
        #expect(m.pollsHome(shown: []))
        let states = [HAEntity(entityID: "light.desk", state: "on")]
        #expect(m.homeGlance(entities: states, fetched: now, failed: false, now: now)?.lightsOn == 1)
        #expect(m.homeGlance(entities: states, fetched: now.addingTimeInterval(-90), failed: false, now: now) != nil)
        #expect(m.homeGlance(entities: states, fetched: now.addingTimeInterval(-HomePoll.fresh - 1), failed: false, now: now) == nil)
        #expect(m.homeGlance(entities: states, fetched: nil, failed: false, now: now) == nil)
        #expect(m.homeGlance(entities: states, fetched: now, failed: true, now: now) == nil)
        #expect(m.homeGlance(entities: [], fetched: now, failed: false, now: now) == nil)
    }

    // MARK: Today without rules doesn't read the states

    @Test func todayWithoutRulesReadsNoStates() throws {
        let m = try model()
        var reads = 0
        let plain = m.todaySections(now: now, homeEntities: { reads += 1; return [] }, fetched: { reads += 1; return nil })
        #expect(reads == 0 && plain.context == nil)
        #expect(plain.sections == m.settings.todayDensity.sections(m.settings.todayLayout))
        m.settings.todayLayout.setRule(.times(.evenings), for: .deals)
        let ruled = m.todaySections(now: now, homeEntities: { reads += 1; return [] }, fetched: { reads += 1; return nil })
        #expect(reads == 2 && ruled.context != nil)
        // Where you are alone builds a context too (its presence goes into it).
        m.settings.todayLayout.setRule(nil, for: .deals)
        m.setPresenceEntity("person.alex")
        #expect(m.todayNeedsContext)
        #expect(m.todaySections(now: now, homeEntities: { [] }, fetched: { nil }).context != nil)
    }

    // MARK: One unreadable key doesn't lose the settings

    func decoded(_ json: String) -> AppSettings? {
        try? Storage.decoder.decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func badQuietHoursKeepsOtherSettings() {
        let s = decoded(#"{"notifyProblems":true,"notifyPending":true,"faceIDLock":true,"personality":"dry","quietHours":{"from":"22:00","to":"07:00"}}"#)
        #expect(s?.faceIDLock == true && s?.notifyProblems == true && s?.notifyPending == true && s?.voice == .dry)
        #expect(s != nil && s?.quietHours == nil)
    }

    @Test func badPresenceEntityKeepsOtherSettings() {
        let s = decoded(#"{"faceIDLock":true,"notifyPending":true,"presenceEntity":{"id":"person.alex"},"quietHours":{"from":1320,"to":420}}"#)
        #expect(s?.faceIDLock == true && s?.presenceEntity == nil)
        #expect(s?.quietHours == AppSettings.defaultQuietHours)
    }

    @Test func badTodayRulesKeepOtherSettings() {
        // An unknown rule kind drops that rule; a layout that can't be read at all falls back to the standard one.
        let rules = decoded(#"{"faceIDLock":true,"today":{"order":["deals","day"],"hidden":[],"rules":{"deals":{"kind":"whenRaining"},"cards":{"kind":"needsMe"}}}}"#)
        #expect(rules?.faceIDLock == true)
        #expect(rules?.todayLayout.rule(for: .deals) == nil && rules?.todayLayout.rule(for: .cards) == .needsMe)
        #expect(rules?.todayLayout.sections.first == .deals)
        let layout = decoded(#"{"faceIDLock":true,"notifyProblems":true,"density":"calm","today":{"order":"deals","rules":7}}"#)
        #expect(layout?.faceIDLock == true && layout?.notifyProblems == true && layout?.todayDensity == .calm)
        #expect(layout?.today == nil)
        // Odd values of the older keys only lose themselves too.
        let odd = decoded(#"{"faceIDLock":true,"density":"loud","leaveActivity":"no","lastBackgroundRun":"never"}"#)
        #expect(odd?.faceIDLock == true && odd?.density == nil && odd?.leaveActivity == nil && odd?.lastBackgroundRun == nil)
    }

    @Test func theModelKeepsSettingsWithABadNewKey() throws {
        let storage = Storage(directory: temporaryDirectory())
        let json = #"{"faceIDLock":true,"notifyPending":true,"quietHours":"22-7","today":{"hidden":["report"],"order":["day","machines","waiting","deals","home","cards","report"]}}"#
        try Data(json.utf8).write(to: storage.url(AppSettings.fileName))
        let (m, _, _, _) = makeModel(storage: storage)
        #expect(m.settings.faceIDLock && m.settings.notifyPending && !m.settings.todayLayout.isVisible(.report))
        #expect(m.settings.quietHours == nil)
    }
}
