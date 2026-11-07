import Foundation
import Testing
@testable import HomelabKit

// M3.3: presence from Home Assistant and quiet hours. Fixed clock and calendar, nothing reads `Date()`.

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

private func at(_ text: String) -> Date { ServerDate.parse(text)! }

/// What `GET /api/states` answers for people and trackers (made up), plus a light that is not a tracker.
private let statesJSON = """
[
  {"entity_id": "person.alex", "state": "home", "attributes": {"friendly_name": "Alex"}},
  {"entity_id": "person.sam", "state": "Work", "attributes": {"friendly_name": "Sam"}},
  {"entity_id": "person.kim", "state": "unknown", "attributes": {"friendly_name": "Kim"}},
  {"entity_id": "device_tracker.phone_router", "state": "not_home", "attributes": {"friendly_name": "Alex's phone (router)"}},
  {"entity_id": "device_tracker.tablet", "state": "unavailable", "attributes": {"friendly_name": "Tablet"}},
  {"entity_id": "light.living_room", "state": "on", "attributes": {"friendly_name": "Living room"}}
]
"""

@Suite struct HomePresenceTests {
    let states: [HAEntity]
    init() throws { states = try decode([HAEntity].self, statesJSON) }

    @Test func homeAwayAndZonesFromStates() {
        let now = at("2026-11-06T12:00:00Z")
        #expect(Presence(entities: states, entityID: "person.alex", fetched: now) == Presence(atHome: true, fetched: now))
        // A zone other than home is away, so is not_home.
        #expect(Presence(entities: states, entityID: "person.sam", fetched: now)?.atHome == false)
        #expect(Presence(entities: states, entityID: "device_tracker.phone_router", fetched: now)?.atHome == false)
    }

    @Test func unknownMissingOrWrongEntityIsNil() {
        let now = at("2026-11-06T12:00:00Z")
        #expect(Presence(entities: states, entityID: "person.kim", fetched: now) == nil)            // unknown
        #expect(Presence(entities: states, entityID: "device_tracker.tablet", fetched: now) == nil)  // unavailable
        #expect(Presence(entities: states, entityID: "person.gone", fetched: now) == nil)           // renamed or removed
        #expect(Presence(entities: states, entityID: "light.living_room", fetched: now) == nil)     // not a tracker
        #expect(Presence(entities: states, entityID: nil, fetched: now) == nil)                     // not set up
        #expect(Presence(entities: states, entityID: "person.alex", fetched: nil) == nil)           // never fetched
        #expect(Presence(entity: HAEntity(entityID: "person.x", state: " "), fetched: now) == nil)
    }

    @Test func candidatesArePeopleFirstThenTrackers() {
        #expect(Presence.candidates(states).map(\.entityID) == [
            "person.alex", "person.kim", "person.sam", "device_tracker.phone_router", "device_tracker.tablet",
        ])
        #expect(Presence.words(states[0]) == "Home" && Presence.words(states[1]) == "Work")
        #expect(Presence.words(states[2]) == "Unknown" && Presence.words(states[3]) == "Away")
        #expect(Presence.words(states[4]) == "Unavailable")
    }

    @Test func staleOrUnknownPresenceLetsBothRulesPass() {
        let fetched = at("2026-11-06T12:00:00Z")
        let away = Presence(entities: states, entityID: "person.sam", fetched: fetched)
        func shows(_ rule: ShowRule, _ minutes: Double, _ p: Presence?) -> Bool {
            rule.shows(.home, in: ShowContext(now: fetched.addingTimeInterval(minutes * 60), calendar: utc(), presence: p))
        }
        #expect(!shows(.atHome, 0, away) && shows(.away, 0, away))
        #expect(!shows(.atHome, 30, away))                          // 30 min: still trusted
        #expect(shows(.atHome, 31, away) && shows(.away, 31, away)) // older: unknown, both pass
        let unknown = Presence(entities: states, entityID: "person.kim", fetched: fetched)
        #expect(shows(.atHome, 0, unknown) && shows(.away, 0, unknown))
    }
}

@MainActor @Suite(.serialized) struct PresenceModelTests {
    func homeAssistant() -> ServerConfig {
        ServerConfig(name: "Home Assistant", kind: .homeAssistant, baseURL: URL(string: "https://ha.tail1234.ts.net")!,
                     auth: .token)
    }

    @Test func offByDefaultAndOnlyWithHomeAssistant() throws {
        let (m, _, _, _) = makeModel()
        let states = try decode([HAEntity].self, statesJSON)
        let now = at("2026-11-06T12:00:00Z")
        #expect(m.settings.presenceEntity == nil && !m.presenceSetUp)
        #expect(m.ruleKinds(for: .deals) == [.always, .needsMe, .times])
        #expect(m.presence(in: states, fetched: now) == nil)

        m.setPresenceEntity("person.alex")
        #expect(!m.presenceSetUp)                                  // no Home Assistant to read it from
        #expect(m.presence(in: states, fetched: now) == nil)

        try m.save(homeAssistant(), token: "t")
        #expect(m.presenceSetUp)
        #expect(m.ruleKinds(for: .deals) == [.always, .needsMe, .times, .atHome, .away])
        #expect(m.ruleKinds(for: .day) == [.always, .times, .atHome, .away])
        #expect(m.presence(in: states, fetched: now) == Presence(atHome: true, fetched: now))
        let c = m.showContext(now: now, homeEntities: states, presence: m.presence(in: states, fetched: now))
        #expect(ShowRule.atHome.shows(.deals, in: c) && !ShowRule.away.shows(.deals, in: c))
    }

    @Test func theDemoHomeAssistantHasNobodyToFollow() {
        let (m, _, _, _) = makeModel(args: ["-HomelabResetState", "YES", "-HomelabDemo", "YES"])
        #expect(m.homeAssistant?.isDemoHomeAssistant == true)
        m.setPresenceEntity("person.alex")
        #expect(!m.presenceSetUp && m.ruleKinds(for: .home) == [.always, .needsMe, .times])
    }

    @Test func savedOnlyOnceSetAndGoneWhenTurnedOff() throws {
        let (m, _, storage, _) = makeModel()
        m.settings.notifyPending = true   // writes the file
        let before = try Data(contentsOf: storage.url(AppSettings.fileName))
        #expect(!String(decoding: before, as: UTF8.self).contains("presenceEntity"))

        m.setPresenceEntity("  person.alex ")
        #expect(m.settings.presenceEntity == "person.alex")
        let on = String(decoding: try Data(contentsOf: storage.url(AppSettings.fileName)), as: UTF8.self)
        #expect(on.contains(#""presenceEntity":"person.alex""#))
        let (again, _, _, _) = makeModel(storage: storage)
        #expect(again.settings.presenceEntity == "person.alex")

        m.setPresenceEntity(nil)
        #expect(try Data(contentsOf: storage.url(AppSettings.fileName)) == before)
        m.setPresenceEntity("")
        #expect(m.settings.presenceEntity == nil)
    }
}

@Suite struct QuietHoursTests {
    /// Two new problems and a new action, from a tracker that knew the calm state.
    func alerts() throws -> [AlertTracker.Alert] {
        var tracker = AlertTracker()
        let start = at("2026-11-06T20:00:00Z")
        _ = tracker.update(with: try fixture(HomelabState.self, "state-ok.json"), server: "lab", now: start)
        let found = tracker.update(with: try fixture(HomelabState.self, "state-problem.json"), server: "lab",
                                   now: start.addingTimeInterval(600))
        #expect(!found.isEmpty)
        return found
    }

    func settings(quiet: TimeWindow?) -> AppSettings {
        var s = AppSettings()
        s.notifyProblems = true
        s.notifyPending = true
        s.quietHours = quiet
        return s
    }

    @Test func quietAcrossMidnight() {
        let s = settings(quiet: AppSettings.defaultQuietHours)   // 22:00–07:00
        let c = utc()
        #expect(!s.isQuiet(at: at("2026-11-06T21:59:00Z"), calendar: c))
        #expect(s.isQuiet(at: at("2026-11-06T22:00:00Z"), calendar: c))
        #expect(s.isQuiet(at: at("2026-11-07T00:30:00Z"), calendar: c))
        #expect(s.isQuiet(at: at("2026-11-07T06:59:00Z"), calendar: c))
        #expect(!s.isQuiet(at: at("2026-11-07T07:00:00Z"), calendar: c))
        #expect(!s.isQuiet(at: at("2026-11-07T12:00:00Z"), calendar: c))
        // By the phone's time zone: 22:00 in Vienna is 21:00 UTC in winter.
        var vienna = c
        vienna.timeZone = TimeZone(identifier: "Europe/Vienna")!
        #expect(s.isQuiet(at: at("2026-11-06T21:00:00Z"), calendar: vienna))
        #expect(!settings(quiet: nil).isQuiet(at: at("2026-11-07T00:30:00Z"), calendar: c))
    }

    @Test func notificationsHeldBackOnlyInTheWindow() throws {
        let found = try alerts()
        let c = utc()
        let quiet = settings(quiet: AppSettings.defaultQuietHours)
        #expect(quiet.notificationsToPost(found, now: at("2026-11-06T23:00:00Z"), calendar: c).isEmpty)
        #expect(quiet.notificationsToPost(found, now: at("2026-11-07T06:30:00Z"), calendar: c).isEmpty)
        #expect(quiet.notificationsToPost(found, now: at("2026-11-07T07:00:00Z"), calendar: c) == found)
        #expect(quiet.notificationsToPost(found, now: at("2026-11-06T18:00:00Z"), calendar: c) == found)
        // Without quiet hours: every hour of the day, all of them, as before.
        let plain = settings(quiet: nil)
        for hour in 0..<24 {
            let now = at("2026-11-06T00:00:00Z").addingTimeInterval(Double(hour) * 3600)
            #expect(plain.notificationsToPost(found, now: now, calendar: c) == found)
        }
        // Notifications off: none, quiet hours or not.
        #expect(AppSettings().notificationsToPost(found, now: at("2026-11-06T12:00:00Z"), calendar: c).isEmpty)
    }

    @Test func resultLineSaysWhenQuietHoursHeldAlertsBack() {
        let c = utc()
        let night = at("2026-11-06T23:00:00Z"), noon = at("2026-11-06T12:00:00Z")
        let quiet = settings(quiet: AppSettings.defaultQuietHours)
        #expect(quiet.backgroundResult(problems: 2, pending: 1, alerts: 2, now: night, calendar: c)
                == "ok, 2 problems, 1 pending, 2 alerts, quiet hours")
        #expect(quiet.backgroundResult(problems: 2, pending: 1, alerts: 0, now: night, calendar: c)
                == "ok, 2 problems, 1 pending, 0 alerts")
        #expect(quiet.backgroundResult(problems: 2, pending: 1, alerts: 2, now: noon, calendar: c)
                == "ok, 2 problems, 1 pending, 2 alerts")
        #expect(settings(quiet: nil).backgroundResult(problems: 0, pending: 0, alerts: 1, now: night, calendar: c)
                == "ok, 0 problems, 0 pending, 1 alerts")
    }

    @Test func savedOnlyOnceSet() throws {
        let plain = try Storage.encoder.encode(settings(quiet: nil))
        #expect(!String(decoding: plain, as: UTF8.self).contains("quietHours"))
        let quiet = try Storage.encoder.encode(settings(quiet: TimeWindow(from: 22 * 60 + 30, to: 6 * 60)))
        #expect(String(decoding: quiet, as: UTF8.self).contains(#""quietHours":{"from":1350,"to":360}"#))
        let back = try Storage.decoder.decode(AppSettings.self, from: quiet)
        #expect(back.quietHours == TimeWindow(from: 1350, to: 360) && back.quietHours?.words(calendar: utc()) == "22:30–6")
        #expect(try Storage.encoder.encode(back) == quiet)
    }
}
