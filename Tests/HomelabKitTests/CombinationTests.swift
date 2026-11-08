import Foundation
import Testing
@testable import HomelabKit

/// The combination test: every detail level x every personality x every demo scene and state fixture. It builds what
/// Today, Lab and Actions would show with the Kit-level functions (no UI) and checks invariants that must hold for
/// all of them: nothing crashes, a personality that is Off says nothing, urgent rows are never folded, the tiles sit
/// evenly, titles are not empty, no text still has a `{placeholder}` or is longer than its place allows.
///
/// Generic on purpose: it walks `Density.allCases` and `Personality.allCases`, so a new level (Hyperdetail) is covered
/// the moment it exists. It is the Kit half of the screenshot matrix (`scripts/sim-smoke --matrix`, docs/CI.md).
/// Fast: no network, no sleeping (the demo backend runs with `delay: .zero`); about a second.
@Suite(.serialized) struct CombinationTests {
    // MARK: Inputs

    /// 2026-11-06 12:00 UTC, and another day: the voice picks its line by the day.
    static let days: [Date] = [0, 7].map { Date(timeIntervalSince1970: 1_793_923_200 + 12 * 3600 + Double($0) * 86400) }
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// One thing to look at: a name for the failure message, the state (nil = first run / nothing loaded), the time
    /// the state counts as "now", the deals and the actions that go with it.
    struct Case {
        var name: String
        var state: HomelabState?
        var now: Date
        var deals: [Deal] = []
        var actions: [ActionSpec] = []
        var messages: [ChatMessage] = []
        var isBridge = false
    }

    /// Every `state-*.json` in the Fixtures folder (found from this file, so a new one is covered by itself).
    static func stateFixtureNames() -> [String] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/HomelabKit/Fixtures", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("state-") && $0.hasSuffix(".json") }.sorted()
    }

    static func cases() async -> [Case] {
        var all: [Case] = []
        // The demo's scenes through the backend, as the app shows them (times moved to now).
        for scene in DemoBackend.Scene.allCases {
            let demo = DemoBackend(scene: scene, delay: .zero)
            let state = try? await demo.state()
            let deals = scene == .bridge ? [] : ((try? await demo.deals())?.deals ?? [])
            let actions = (try? await demo.actions()) ?? []
            let messages = (try? await demo.messages(after: 0))?.messages ?? []
            all.append(Case(name: "scene \(scene.rawValue)", state: state, now: state?.time ?? Date(), deals: deals,
                            actions: actions, messages: messages, isBridge: scene == .bridge))
        }
        // The raw state fixtures, at their own time.
        for name in stateFixtureNames() {
            let state = Fixtures.decode(HomelabState.self, name)
            all.append(Case(name: name, state: state, now: state?.time ?? days[0]))
        }
        // First run, a failed first fetch, and a server that sent a state with nothing in it.
        all.append(Case(name: "first run (no state)", state: nil, now: days[0]))
        all.append(Case(name: "empty state", state: HomelabState(), now: days[0]))
        return all
    }

    // MARK: Text checks

    /// Every string a screen would show must be real text: not empty, no `{placeholder}`, no Swift leftovers.
    static func checkText(_ text: String?, _ label: String, max: Int? = nil, allowEmpty: Bool = false) {
        guard let text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmpty { #expect(!trimmed.isEmpty, "empty text: \(label)") }
        // (Cheap tests first: this runs for thousands of strings.)
        if text.contains("{") || text.contains("}") {
            #expect(text.firstMatch(of: /\{[A-Za-z_]+\}/) == nil, "unresolved placeholder in '\(text)': \(label)")
        }
        if text.contains("Optional(") || text.contains("nil)") { #expect(Bool(false), "Swift leftover in '\(text)': \(label)") }
        if let max { #expect(text.count <= max, "\(text.count) > \(max) characters in '\(text)': \(label)") }
    }

    /// The owner's own words. None of them may show in the neutral bridge scene (its data, not the personality's
    /// jokes: Ultrakill's satire has its own tests).
    nonisolated(unsafe) static let ownerWords = try! Regex(
        #"(?i)\b(u6|school|schule|lessons?|grades?|deals?|willhaben|commute|tgm|moodle|webuntis|matura|homework|orf|heise|wien|vienna)\b"#)

    static func checkNeutral(_ text: String?, _ label: String) {
        guard let text else { return }
        #expect(text.firstMatch(of: ownerWords) == nil, "owner word in '\(text)': \(label)")
    }

    // MARK: The matrix

    @Test func everyLevelEveryVoiceEveryScene() async throws {
        let cases = await Self.cases()
        #expect(cases.count >= DemoBackend.Scene.allCases.count + 10)
        #expect(Density.allCases.count >= 3 && Personality.allCases.count >= 4)
        var combinations = 0
        for c in cases {
            for density in Density.allCases {
                Self.checkToday(c, density)
                for personality in Personality.allCases {
                    Self.checkVoice(c, density, personality)
                    combinations += 1
                }
            }
            Self.checkLab(c)
            Self.checkActionsAndChat(c)
            Self.checkWidget(c)
        }
        // Not a limit, a guard against the loops quietly doing nothing.
        #expect(combinations == cases.count * Density.allCases.count * Personality.allCases.count)
    }

    // MARK: Today

    static func checkToday(_ c: Case, _ density: Density) {
        let label = "\(c.name) / \(density.rawValue)"

        // The sections: every level shows at least what Calm shows, once each, all from the layout.
        let layout = TodayLayout.standard
        let sections = density.sections(layout)
        let calm = Density.calm.sections(layout)
        #expect(Set(sections).count == sections.count, "duplicate sections: \(label)")
        #expect(Set(calm).isSubset(of: Set(sections)), "\(density.rawValue) shows less than Calm: \(label)")
        #expect(Set(sections).isSubset(of: Set(layout.sections)), "section outside the layout: \(label)")
        #expect(!sections.isEmpty, "no sections: \(label)")
        checkText(density.title, "title of \(density.rawValue)")
        checkText(density.summary, "summary of \(density.rawValue)")
        #expect(Density.explanation.contains(density.title), "explanation misses \(density.rawValue)")
        #expect(TodayFold.cap(density) >= 1 && TodayFold.approvals(density) >= 1 && TodayFold.textLines(density) >= 1)

        // The headline.
        let mood = TodayMood(state: c.state)
        checkText(mood.headline, "headline: \(label)", max: 40)
        checkText(mood.detail, "detail: \(label)")
        checkText(mood.warningText, "warning text: \(label)")
        if c.isBridge { checkNeutral(mood.headline, "headline: \(label)"); checkNeutral(mood.detail, "detail: \(label)") }
        guard let state = c.state else { return }

        // The cards: one plan, folds, tiles.
        let day = state.cards.first { $0.id == "today" }
        let plan = TodayFold.plan(state.cards, dayCardID: day?.id)
        for block in plan.blocks {
            switch block {
            case let .card(card):
                checkText(card.title ?? (card.id.isEmpty ? nil : card.id), "title of card '\(card.id)': \(label)")
                #expect(!(card.title ?? card.id).trimmingCharacters(in: .whitespaces).isEmpty, "card without a title: \(label)")
                if c.isBridge { checkNeutral(card.title, "card title: \(label)") }
            case let .line(card, line):
                checkText(line, "one-liner of '\(card.id)': \(label)")
                if c.isBridge { checkNeutral(line, "one-liner: \(label)") }
            }
        }
        for card in state.cards where card.place != .lab {
            checkFold(card, density, state: state, now: c.now, label: label)
        }
        let tiles = TodayFold.tiles(cards: plan.tileCards, deals: c.deals, density: density)
        for tile in tiles {
            checkText(tile.kind.title, "tile title: \(label)")
            checkText(tile.line, "tile line of \(tile.kind.title): \(label)", max: tile.kind == .news ? 120 : 60, allowEmpty: true)
            checkText(tile.spoken, "tile spoken: \(label)")
            #expect(tile.count > 0, "empty tile \(tile.kind.title): \(label)")
            if c.isBridge { checkNeutral(tile.line, "tile line: \(label)"); #expect(tile.kind != .deals && tile.kind != .grades) }
        }
        #expect(Set(tiles.map(\.kind)).count == tiles.count, "a tile kind twice: \(label)")
        for stacked in [false, true] {
            let rows = TodayFold.tileRows(count: tiles.count, stacked: stacked)
            #expect(rows.reduce(0, +) == tiles.count, "tile rows \(rows) do not add up to \(tiles.count): \(label)")
            #expect(Set(rows).count <= 1, "uneven tile rows \(rows): \(label)")
            #expect(rows.allSatisfy { (1...3).contains($0) }, "tile row too wide \(rows): \(label)")
        }
    }

    /// Urgent rows are never folded; the fold hides at least two rows (one for deadlines); counts add up.
    static func checkFold(_ card: Card, _ density: Density, state: HomelabState, now: Date, label: String) {
        let items = card.style == .countdown ? card.sortedForCountdown : card.items
        let folded = TodayFold.rows(card, density: density, expanded: false, now: now)
        let open = TodayFold.rows(card, density: density, expanded: true, now: now)
        let urgent = items.filter { TodayFold.isUrgent($0, in: card, now: now) }
        let name = "card '\(card.id)': \(label)"
        for item in urgent { #expect(folded.items.contains(item), "urgent row folded away in \(name): \(item.title ?? "?")") }
        #expect(folded.items.count + folded.hidden == items.count, "rows lost in \(name)")
        #expect(open.hidden == 0 && open.items.count == items.count, "expanded card hides rows: \(name)")
        if folded.hidden > 0 {
            #expect(folded.folds && folded.hidden >= (card.style == .countdown ? 1 : TodayFold.minHidden), "silly fold in \(name)")
            #expect(TodayFold.foldLabel(folded, expanded: false).hasPrefix("Show \(folded.hidden) more"), "fold label: \(name)")
            if card.style != .countdown { #expect(folded.items.count <= max(TodayFold.cap(density), urgent.count), "cap exceeded in \(name)") }
        } else {
            #expect(folded.items == items, "nothing hidden but rows differ in \(name)")
        }
        // The order of the rows stays.
        var rest = items[...]
        for shown in folded.items {
            guard let i = rest.firstIndex(of: shown) else { #expect(Bool(false), "rows reordered in \(name)"); break }
            rest = rest[(i + 1)...]
        }
        for item in items {
            checkText(item.title, "row title in \(name)", allowEmpty: true)
            checkText(item.subtitle, "row subtitle in \(name)", allowEmpty: true)
            checkText(item.value, "row value in \(name)", allowEmpty: true)
        }
    }

    // MARK: The voice

    static func checkVoice(_ c: Case, _ density: Density, _ personality: Personality) {
        let label = "\(c.name) / \(density.rawValue) / \(personality.rawValue)"
        let mood = TodayMood(state: c.state)
        checkText(personality.title, "title of \(personality.rawValue)")
        for now in days {
            let take = Voice.take(for: c.state, personality: personality, now: now, calendar: utc)
            let sample = Voice.sample(for: c.state, level: mood.level, personality: personality, now: now, calendar: utc)
            let line = Voice.line(Voice.moment(mood.level), personality, on: now, calendar: utc)
            let spots: [Voice.Spot] = [LabMoodSpot(c.state), .actionDone(ok: true), .actionDone(ok: false)]
                .compactMap { $0 } + Voice.Empty.allCases.map { .empty($0) } + Voice.Notice.allCases.map { .notice($0) }
            if personality == .off {
                // Plain: the voice adds nothing anywhere.
                #expect(take == nil && sample == nil && line == nil, "remark with the personality Off: \(label)")
                #expect(Voice.takeCount(for: c.state, personality: personality, now: now, calendar: utc) == 0, "take count Off: \(label)")
                #expect(Voice.preview(for: c.state, personality: personality, now: now, calendar: utc).isEmpty, "preview Off: \(label)")
                for spot in spots { #expect(Voice.line(for: spot, personality: .off, now: now, calendar: utc) == nil, "line Off \(spot): \(label)") }
                for problem in c.state?.problems ?? [] {
                    #expect(Voice.aside(for: problem, in: c.state, personality: .off, now: now, calendar: utc) == nil, "aside Off: \(label)")
                    #expect(Voice.take(for: problem, host: nil, personality: .off, now: now, calendar: utc) == nil, "problem take Off: \(label)")
                }
                let report = ActionReport(ok: true, title: "Done", text: "Ran it.")
                #expect(report.voiced(.off, now: now, calendar: utc) == report, "action report changed Off: \(label)")
                continue
            }
            // A voice: the headline's line exists and fits one line; a take, when there is one, fits two.
            checkText(line, "mood line: \(label)", max: Voice.Moment.calm.spot.place.maxLength)
            #expect(line != nil, "no line under the headline: \(label)")
            checkText(sample, "sample: \(label)", max: 90)
            let takes = Voice.takeCount(for: c.state, personality: personality, now: now, calendar: utc)
            if let take {
                checkText(take.text, "take: \(label)", max: 90)
                #expect(takes > 0, "take without count: \(label)")
            }
            for variant in 0..<max(takes, 1) {
                checkText(Voice.take(for: c.state, personality: personality, now: now, calendar: utc, variant: variant)?.text,
                          "take variant \(variant): \(label)", max: 90)
            }
            for spot in spots {
                let text = Voice.line(for: spot, personality: personality, now: now, calendar: utc)
                checkText(text, "line \(spot): \(label)", max: spot.place.maxLength)
                #expect(text != nil, "no line for \(spot): \(label)")
            }
            for problem in c.state?.problems ?? [] {
                let host = problem.host.flatMap { id in c.state?.hosts.first { $0.id == id } }
                checkText(Voice.aside(for: problem, in: c.state, personality: personality, now: now, calendar: utc),
                          "aside for '\(problem.id)': \(label)", max: 64)
                checkText(Voice.take(for: problem, host: host, personality: personality, now: now, calendar: utc)?.text,
                          "problem take '\(problem.id)': \(label)", max: 90)
            }
            for row in Voice.preview(for: c.state, personality: personality, now: now, calendar: utc) {
                checkText(row, "preview: \(label)")
            }
            let voiced = ActionReport(ok: true, title: "Done", text: "Ran it.").voiced(personality, now: now, calendar: utc)
            #expect(voiced.text.hasPrefix("Ran it.") && voiced.title == "Done", "action report body changed: \(label)")
            checkText(voiced.text, "voiced report: \(label)")
        }
    }

    static func LabMoodSpot(_ state: HomelabState?) -> Voice.Spot? { Voice.LabMood(state).map { .lab($0) } }

    // MARK: Lab

    static func checkLab(_ c: Case) {
        guard let state = c.state else { return }
        let label = c.name
        for host in state.hosts {
            checkText(host.name, "host name '\(host.id)': \(label)")
            if c.isBridge { checkNeutral(host.name, "host name: \(label)") }
            if let history = host.history {
                for series in HostHistory.Series.allCases {
                    #expect(history[series].count <= HostHistory.maxPoints, "history too long: \(host.id) \(label)")
                }
            }
            for container in host.containerList { checkText(container.name, "container name on \(host.id): \(label)") }
        }
        for problem in state.problems {
            checkText(problem.text, "problem text '\(problem.id)': \(label)")
            if c.isBridge { checkNeutral(problem.text, "problem text: \(label)") }
        }
        for card in state.cards where card.place == .lab {
            #expect(!(card.title ?? card.id).trimmingCharacters(in: .whitespaces).isEmpty, "lab card without a title: \(label)")
            let folded = LabRows.shown(card, expanded: false)
            let open = LabRows.shown(card, expanded: true)
            #expect(open == card.items, "expanded lab card hides rows: '\(card.id)' \(label)")
            #expect(folded.count == (LabRows.folds(card) ? LabRows.folded : card.items.count), "lab fold: '\(card.id)' \(label)")
            #expect(LabRows.folds(card) == (card.style == .list && card.items.count > LabRows.folded))
            checkText(LabRows.subtitle(card), "lab subtitle '\(card.id)': \(label)")
            for item in card.items {
                checkText(item.title, "lab row title in '\(card.id)': \(label)", allowEmpty: true)
                checkText(LabRows.value(item, in: card), "lab row value in '\(card.id)': \(label)")
                if c.isBridge { checkNeutral(item.title, "lab row: \(label)"); checkNeutral(item.subtitle, "lab row: \(label)") }
            }
        }
        if c.isBridge {
            // Made-up data and nothing of the owner in the whole scene, cards included.
            for card in state.cards {
                for text in [card.title, card.subtitle, card.text] + card.items.flatMap({ [$0.title, $0.subtitle, $0.value] }) {
                    checkNeutral(text, "card '\(card.id)' text")
                }
            }
            #expect(state.commute == nil, "the bridge scene has a commute")
            #expect(state.hosts.contains { $0.history != nil && !($0.history?.isEmpty ?? true) }, "bridge hosts have no history")
            #expect(state.hosts.contains { !$0.containerList.isEmpty }, "bridge has no containers")
            #expect(!state.problems.isEmpty, "bridge has no Uptime Kuma problem")
        }
    }

    // MARK: Actions and chat

    static func checkActionsAndChat(_ c: Case) {
        let label = c.name
        #expect(Set(c.actions.map(\.name)).count == c.actions.count, "action twice: \(label)")
        for action in c.actions {
            checkText(action.label, "action label '\(action.name)': \(label)")
            checkText(action.hint, "action hint '\(action.name)': \(label)", allowEmpty: true)
            if c.isBridge { checkNeutral(action.label, "action: \(label)"); checkNeutral(action.hint, "action hint: \(label)") }
        }
        for message in c.messages {
            checkText(message.text, "chat message \(message.id): \(label)")
            if c.isBridge {
                checkNeutral(message.text, "chat: \(label)")
                for card in message.cards { checkNeutral(card.title, "chat card: \(label)") }
            }
        }
    }

    // MARK: Widget

    static func checkWidget(_ c: Case) {
        guard let state = c.state else { return }
        let snapshot = Snapshot(serverID: UUID(), serverName: "x", state: state, fetched: c.now)
        guard let data = try? Storage.encoder.encode(snapshot),
              let back = try? Storage.decoder.decode(Snapshot.self, from: data) else {
            #expect(Bool(false), "the widget copy does not survive its own encoder: \(c.name)")
            return
        }
        // (Dates are saved to the second, so compare what the widget shows, not the bytes.)
        #expect(back.serverID == snapshot.serverID && back.state.status == state.status
                && back.state.hosts.map(\.id) == state.hosts.map(\.id) && back.state.problems.map(\.id) == state.problems.map(\.id)
                && back.state.cards.map(\.id) == state.cards.map(\.id), "the widget copy changed on the way: \(c.name)")
        let mood = TodayMood(state: back.state)
        checkText(mood.headline, "widget headline: \(c.name)")
        let deadlines = back.state.deadlinesCard
        #expect(Deadlines.urgency(deadlines, now: c.now).isFinite, "widget urgency: \(c.name)")
        #expect(Deadlines.dueThisWeek(deadlines, now: c.now) <= Deadlines.list(deadlines).count, "widget week count: \(c.name)")
    }

    // MARK: Launch arguments and the model

    /// The launch arguments the screenshot matrix passes work for every level and voice.
    @Test func launchArgumentsCoverEveryLevelAndVoice() {
        for density in Density.allCases {
            #expect(LaunchArguments(["-HomelabDensity", density.rawValue]).density == density)
            #expect(LaunchArguments(["-HomelabDensity", density.title.uppercased()]).density == density)
        }
        for personality in Personality.allCases {
            #expect(LaunchArguments(["-HomelabPersonality", personality.rawValue]).personality == personality)
        }
        for scene in DemoBackend.Scene.allCases {
            #expect(LaunchArguments(["-HomelabDemoScene", scene.rawValue]).demoScene == scene)
        }
        #expect(LaunchArguments(["-HomelabDemoScene", "bridge"]).demoScene == .bridge)
    }

    /// Through the app model, as the app loads it: the bridge scene is a Companion server without the owner's extras,
    /// the first run has nothing, every tab the model offers has a title.
    @MainActor @Test func modelShowsTheBridgeSceneAndTheFirstRun() async throws {
        let (m, _, _, _) = makeModel(args: ["app", "-HomelabResetState", "YES", "-HomelabDemo", "YES",
                                            "-HomelabDemoScene", "bridge", "-HomelabPersonality", "snarky"])
        await m.refresh()
        let state = try #require(m.selectedStatus.snapshot?.state)
        #expect(state.hosts.map(\.id).contains("pve1") && state.commute == nil)
        #expect(m.settings.voice == .snarky)
        for tab in m.availableTabs { CombinationTests.checkText(tab.title, "tab title \(tab.rawValue)") }
        #expect(m.availableTabs.contains(.today) && m.availableTabs.contains(.lab))
        let widget = try Data(contentsOf: m.storage.url(Snapshot.widgetFileName))
        try CombinationTests.checkNeutral(#require(String(data: widget, encoding: .utf8)), "widget copy of the bridge scene")

        let (first, _, _, _) = makeModel(args: ["app", "-HomelabResetState", "YES"])
        #expect(!first.hasServers)
        for tab in first.availableTabs { CombinationTests.checkText(tab.title, "first run tab \(tab.rawValue)") }
    }

    // MARK: The bridge fixtures

    @Test func bridgeSceneLoadsAndIsNeutral() async throws {
        let scene = DemoBackend.Scene.bridge
        #expect(scene.rawValue == "bridge" && scene.hasHomelab)
        for file in [scene.stateFixture, scene.messagesFixture, scene.actionsFixture, scene.infoFixture] {
            let data = try #require(Fixtures.data(file), "\(file) is missing")
            Self.checkNeutral(String(data: data, encoding: .utf8), file)
        }
        let demo = DemoBackend(scene: scene, delay: .zero)
        let info = try await demo.info()
        #expect(info.name == "Bridge homelab")
        let state = try await demo.state()
        #expect(state.status == .problem && state.problems.count >= 2 && state.pending.count == 1)
        #expect(state.hosts.count >= 3 && state.hosts.allSatisfy { $0.history != nil })
        // History ends now (the demo moves it), 24 h of 5-minute points.
        for host in state.hosts { #expect(host.history?[.load].count == 288 && host.history?.end != nil) }
        let ids = Set(state.cards.map(\.id))
        #expect(ids.isSuperset(of: ["dns", "dns-top", "kuma", "backups", "gameserver", "news", "downloads"]))
        #expect(!ids.contains("today") && !ids.contains("grades") && !ids.contains("deadlines") && !ids.contains("tailnet"))
        // No deals, search or share: the features list is what a Bridge without those sources sends.
        #expect(info.features.isDisjoint(with: [.deals, .search, .share, .documents]))
        let actions = try await demo.actions()
        #expect(Set(actions.map(\.name)) == ["dns-pause", "restart-container"])
        // The calm demo is untouched by it.
        let calm = try await DemoBackend(scene: .calm, delay: .zero).state()
        #expect(calm.cards.contains { $0.id == "today" } && calm.commute != nil)
    }
}
