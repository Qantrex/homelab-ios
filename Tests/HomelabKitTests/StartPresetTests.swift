import Foundation
import Testing
@testable import HomelabKit

/// Start presets (docs/plans/MODULAR.md, M2.2): what found servers suggest, and what each preset writes.
@Suite struct StartPresetTests {
    typealias F = ServerInfo.Feature

    /// What the reference server offers with nothing configured, and with everything it can do.
    static let bareBridge: Set<F> = [.status, .hosts]
    static let fullBridge: Set<F> = [.status, .hosts, .actions, .chat, .cards, .services]
    static let all = Set(F.allCases)

    func sections(_ l: StartLayout) -> [String] { l.today.sections.map(\.rawValue) }

    // MARK: Suggested

    @Test func suggestedPerSetup() {
        #expect(StartPreset.suggested(features: [], hasHA: true) == .home)              // HA only
        #expect(StartPreset.suggested(features: [], hasHA: false) == .watch)            // nothing found
        #expect(StartPreset.suggested(features: Self.bareBridge, hasHA: false) == .watch)
        #expect(StartPreset.suggested(features: Self.fullBridge, hasHA: false) == .watch)
        #expect(StartPreset.suggested(features: Self.bareBridge, hasHA: true) == .watch)
        #expect(StartPreset.suggested(features: Self.fullBridge, hasHA: true) == .watch)
        #expect(StartPreset.suggested(features: [.status], hasHA: true) == .watch)
        // Anything only an agent does means more to show.
        for f in [F.deals, .search, .documents, .share] {
            #expect(StartPreset.suggested(features: Self.bareBridge.union([f]), hasHA: false) == .everything, "\(f)")
            #expect(StartPreset.suggested(features: [f], hasHA: true) == .everything, "\(f)")
        }
        #expect(StartPreset.suggested(features: Self.all, hasHA: false) == .everything)
        #expect(StartPreset.suggested(features: Self.all, hasHA: true) == .everything)
    }

    @Test func suggestedFromDecodedInfo() throws {
        // An old or minimal server without a features list counts as status and hosts: Watch.
        let minimal = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"api": 1}"#.utf8))
        #expect(StartPreset.suggested(features: minimal.features, hasHA: false) == .watch)
        // Unknown features are dropped on decode and change nothing.
        let odd = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"api": 1, "features": ["status", "teleport"]}"#.utf8))
        #expect(StartPreset.suggested(features: odd.features, hasHA: true) == .watch)
    }

    @Test func demoSuggestsEverythingAndWritesOnlyTheDensity() async throws {
        let info = try await DemoBackend(delay: .zero).info()
        #expect(ServerConfig.demoHomeAssistant().showsHomeTab)   // the demo comes with a Home Assistant
        #expect(StartPreset.suggested(features: info.features, hasHA: true) == .everything)
        let l = StartPreset.everything.layout(features: info.features, hasHA: true)
        #expect(l == StartLayout(today: .standard, density: .overkill))
        var s = AppSettings()
        l.apply(to: &s)
        #expect(s.today == nil && s.density == .overkill)
    }

    // MARK: Home

    @Test func homeForHomeAssistantOnly() {
        let l = StartPreset.home.layout(features: [], hasHA: true)
        #expect(l.density == .calm)
        #expect(sections(l) == ["home", "day", "waiting", "cards", "deals", "report", "machines"])
        #expect(l.today.hidden == ["deals", "report", "machines"])
        #expect(Density.calm.sections(l.today) == [.home, .day])
        #expect(Density.standard.sections(l.today) == [.home, .day, .waiting, .cards])
    }

    @Test func homeWithACompanionServer() {
        // What the server offers moves to the front, in Home's order; the rest keeps that order behind it.
        let bare = StartPreset.home.layout(features: Self.bareBridge, hasHA: true)
        #expect(sections(bare) == ["home", "report", "machines", "day", "waiting", "cards", "deals"])
        #expect(bare.today.hidden == ["report", "machines", "deals"])
        #expect(Density.calm.sections(bare.today) == [.home, .day])
        let full = StartPreset.home.layout(features: Self.fullBridge, hasHA: true)
        #expect(sections(full) == ["home", "day", "waiting", "cards", "report", "machines", "deals"])
        // Without Home Assistant the tiles still come first in Home, and stay on for when one is added.
        let noHA = StartPreset.home.layout(features: Self.fullBridge, hasHA: false)
        #expect(sections(noHA) == ["day", "waiting", "cards", "report", "machines", "home", "deals"])
        #expect(noHA.today.isVisible(.home))
    }

    // MARK: Watch

    @Test func watchForCompanionOnly() {
        let bare = StartPreset.watch.layout(features: Self.bareBridge, hasHA: false)
        #expect(bare.density == .standard)
        #expect(sections(bare) == ["report", "machines", "waiting", "day", "cards", "home", "deals"])
        #expect(bare.today.hidden == ["deals"])
        let full = StartPreset.watch.layout(features: Self.fullBridge, hasHA: false)
        #expect(sections(full) == ["waiting", "day", "cards", "report", "machines", "home", "deals"])
        #expect(Density.standard.sections(full.today) == [.waiting, .day, .cards, .report, .home])
        // Cards without actions: nothing waits, so the day leads.
        let cards = StartPreset.watch.layout(features: [.status, .hosts, .cards], hasHA: false)
        #expect(sections(cards) == ["day", "cards", "report", "machines", "waiting", "home", "deals"])
    }

    @Test func watchWithHomeAssistant() {
        let l = StartPreset.watch.layout(features: Self.fullBridge, hasHA: true)
        #expect(sections(l) == ["waiting", "day", "cards", "home", "report", "machines", "deals"])
        let haOnly = StartPreset.watch.layout(features: [], hasHA: true)
        #expect(sections(haOnly) == ["home", "waiting", "day", "cards", "report", "deals", "machines"])
        #expect(Density.standard.sections(haOnly.today) == [.home, .waiting, .day, .cards, .report])
    }

    @Test func watchKeepsDealsOffEvenWhenOffered() {
        let l = StartPreset.watch.layout(features: Self.all, hasHA: true)
        #expect(l.today.hidden == ["deals"])
        #expect(sections(l) == ["waiting", "day", "cards", "home", "report", "deals", "machines"])
    }

    // MARK: Everything

    @Test func everythingShowsEverySection() {
        for (features, hasHA) in [(Set<F>(), true), (Self.bareBridge, false), (Self.fullBridge, true), (Self.all, true)] {
            let l = StartPreset.everything.layout(features: features, hasHA: hasHA)
            #expect(l.density == .overkill)
            #expect(l.today.hidden.isEmpty)
            #expect(Set(l.today.sections) == Set(TodaySection.allCases))
            #expect(Density.overkill.sections(l.today).count == TodaySection.allCases.count)
        }
        // Offered first, in the standard order.
        let haOnly = StartPreset.everything.layout(features: [], hasHA: true)
        #expect(sections(haOnly) == ["home", "day", "waiting", "deals", "cards", "report", "machines"])
        let full = StartPreset.everything.layout(features: Self.fullBridge, hasHA: true)
        #expect(sections(full) == ["day", "waiting", "home", "cards", "report", "machines", "deals"])
    }

    // MARK: Every preset, every setup

    @Test func everyLayoutIsCompleteAndStable() throws {
        let setups: [(Set<F>, Bool)] = [([], true), ([], false), (Self.bareBridge, false), (Self.bareBridge, true),
                                        (Self.fullBridge, false), (Self.fullBridge, true), (Self.all, false), (Self.all, true)]
        for preset in StartPreset.allCases {
            for (features, hasHA) in setups {
                let l = preset.layout(features: features, hasHA: hasHA)
                // Every section once, written out in full, nothing unknown.
                #expect(l.today.order == l.today.sections.map(\.rawValue))
                #expect(l.today.order.count == TodaySection.allCases.count)
                #expect(Set(l.today.hidden).isSubset(of: Set(l.today.order)))
                #expect(l.density == preset.density)
                // Same input, same output; and it survives the settings file.
                #expect(preset.layout(features: features, hasHA: hasHA) == l)
                var s = AppSettings()
                l.apply(to: &s)
                let back = try Storage.decoder.decode(AppSettings.self, from: Storage.encoder.encode(s))
                #expect(back.todayLayout == l.today && back.todayDensity == l.density)
                // The Home tiles are never turned off by a preset.
                #expect(l.today.isVisible(.home))
            }
        }
    }

    @Test func offersReadsTheRightFeature() {
        let none = Set<F>()
        for s in TodaySection.allCases {
            #expect(!StartPreset.offers(s, features: none, hasHA: false), "\(s)")
            #expect(StartPreset.offers(s, features: Self.all, hasHA: true), "\(s)")
        }
        #expect(StartPreset.offers(.home, features: none, hasHA: true))
        #expect(!StartPreset.offers(.home, features: Self.all, hasHA: false))
        #expect(StartPreset.offers(.day, features: [.cards], hasHA: false) && StartPreset.offers(.cards, features: [.cards], hasHA: false))
        #expect(StartPreset.offers(.waiting, features: [.actions], hasHA: false))
        #expect(StartPreset.offers(.deals, features: [.deals], hasHA: false))
        #expect(StartPreset.offers(.report, features: [.status], hasHA: false))
        #expect(StartPreset.offers(.machines, features: [.hosts], hasHA: false))
    }

    // MARK: Writing the settings

    @Test func applyWritesOnlyLayoutAndDensity() throws {
        var s = AppSettings()
        s.notifyProblems = true
        s.personality = .dry
        s.leaveActivity = false
        let before = s
        StartPreset.home.layout(features: [], hasHA: true).apply(to: &s)
        var expected = before
        expected.today = TodayLayout(order: ["home", "day", "waiting", "cards", "deals", "report", "machines"],
                                     hidden: ["deals", "report", "machines"])
        expected.density = .calm
        #expect(s == expected)
        // Picking another preset afterwards replaces both; one matching the defaults stores nothing for them.
        StartPreset.everything.layout(features: Self.all, hasHA: true).apply(to: &s)
        #expect(s.today == nil && s.density == .overkill)
        StartLayout(today: .standard, density: .standard).apply(to: &s)
        #expect(s == before)
        let json = try JSONSerialization.jsonObject(with: Storage.encoder.encode(s)) as? [String: Any] ?? [:]
        #expect(json["today"] == nil && json["density"] == nil)
    }

    @Test func titlesAndSummaries() {
        #expect(StartPreset.allCases.map(\.title) == ["Home", "Watch", "Everything"])
        #expect(StartPreset.allCases.map(\.id) == ["home", "watch", "everything"])
        for p in StartPreset.allCases { #expect(!p.summary.isEmpty && p.summary.count <= 60, "\(p)") }
    }
}
