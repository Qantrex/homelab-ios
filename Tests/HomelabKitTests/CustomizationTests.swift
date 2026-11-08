import Foundation
import Testing
@testable import HomelabKit

/// Settings → Advanced: hide and reorder Start tiles, Lab blocks and tabs; chat text size and folding; the page's title
/// by personality. Old settings files decode as before and new fields are left out while they are at their default.
@MainActor @Suite(.serialized) struct CustomizationTests {
    static func specs(_ names: [String]) -> [ActionSpec] { names.map { ActionSpec(name: $0) } }
    static func names(_ specs: [ActionSpec]) -> [String] { specs.map(\.name) }

    // MARK: ItemOrder

    @Test func orderHidesReordersAndAppendsNewOnes() {
        var o = ItemOrder.standard
        #expect(o.ordered(["a", "b", "c"]) == ["a", "b", "c"] && o.isStandard)
        o.move(["a", "b", "c"], fromOffsets: IndexSet(integer: 2), toOffset: 0)   // c to the top
        #expect(o.ordered(["a", "b", "c"]) == ["c", "a", "b"])
        o.setVisible("a", false)
        #expect(o.visible(["a", "b", "c"]) == ["c", "b"])
        // A new id appears last and visible; a gone id is skipped but a hidden one stays hidden if it returns.
        #expect(o.visible(["a", "b", "c", "d"]) == ["c", "b", "d"])
        #expect(o.visible(["b", "c"]) == ["c", "b"])
        o.setVisible("a", true)
        #expect(o.hidden.isEmpty)
    }

    @Test func moveLikeSwiftUIAndNudge() {
        var o = ItemOrder.standard
        let ids = ["a", "b", "c", "d"]
        o.move(ids, fromOffsets: IndexSet(integer: 0), toOffset: 3)               // a between c and d
        #expect(o.ordered(ids) == ["b", "c", "a", "d"])
        o.move(ids, fromOffsets: IndexSet([1, 2]), toOffset: 0)                   // two at once
        #expect(o.ordered(ids) == ["c", "a", "b", "d"])
        #expect(o.nudge("c", in: ids, by: 1) && o.ordered(ids) == ["a", "c", "b", "d"])
        #expect(o.nudge("c", in: ids, by: -1) && o.ordered(ids) == ["c", "a", "b", "d"])
        #expect(!o.nudge("c", in: ids, by: -1) && !o.nudge("d", in: ids, by: 1) && !o.nudge("x", in: ids, by: 1))
        // Ids that are not listed now keep their place behind the listed ones.
        o.move(["a", "b"], fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(Array(o.ordered(["a", "b", "c", "d"]).prefix(2)) == ["b", "a"])
    }

    @Test func oddDataIsHarmless() throws {
        let o = try JSONDecoder().decode(ItemOrder.self, from: Data(#"{"order":["a","a"],"hidden":"x"}"#.utf8))
        #expect(o.ordered(["a", "b"]) == ["a", "b"] && o.hidden.isEmpty)
    }

    // MARK: Start tiles

    @Test func startTilesFollowTheOrderByName() {
        let all = Self.specs(["wake-set", "calendar-event", "pc-on", "note"])
        #expect(Self.names(StartTiles.arrange(all, nil)) == ["wake-set", "calendar-event", "pc-on", "note"])
        var o = ItemOrder.standard
        o.setVisible("calendar-event", false)
        o.move(all.map(\.name), fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(Self.names(StartTiles.arrange(all, o)) == ["note", "wake-set", "pc-on"])
        #expect(Self.names(StartTiles.editable(all, o)) == ["note", "wake-set", "calendar-event", "pc-on"])
        // A tile the server adds later shows up at the end, visible.
        let more = all + Self.specs(["new"])
        #expect(Self.names(StartTiles.arrange(more, o)) == ["note", "wake-set", "pc-on", "new"])
        // A tile the server dropped is simply gone.
        #expect(Self.names(StartTiles.arrange(Self.specs(["pc-on"]), o)) == ["pc-on"])
    }

    // MARK: Lab

    @Test func labBlocksHideAndReorder() {
        let cards = ["tailnet", "dns", "backups"].map { Card(id: $0, title: $0.capitalized, style: .list) }
        #expect(LabBlocks.visibleIDs(cards: cards, nil) == ["@hosts", "tailnet", "dns", "backups", "@services"])
        var o = ItemOrder.standard
        o.setVisible("dns", false)
        o.setVisible(LabBlocks.services, false)
        o.move(LabBlocks.ids(cards: cards, o), fromOffsets: IndexSet(integer: 3), toOffset: 0)   // backups first
        #expect(LabBlocks.visibleIDs(cards: cards, o) == ["backups", "@hosts", "tailnet"])
        let more = cards + [Card(id: "minecraft", title: "Minecraft", style: .list)]
        #expect(LabBlocks.visibleIDs(cards: more, o) == ["backups", "@hosts", "tailnet", "minecraft"])
        #expect(LabBlocks.title("@hosts", cards: cards) == "Hosts" && LabBlocks.title("dns", cards: cards) == "Dns")
        #expect(LabBlocks.title("gone", cards: cards) == "gone")
    }

    // MARK: Tabs

    @Test func tabBarOrderHidingAndSettingsAlwaysThere() {
        let all: Set<AppTab> = Set(AppTab.allCases)
        #expect(TabBar.shown(available: all, nil) == [.today, .actions, .chat, .lab, .settings])
        var o = ItemOrder.standard
        o.setVisible("chat", false)
        o.move(AppTab.allCases.map(\.rawValue), fromOffsets: IndexSet(integer: 3), toOffset: 0)   // lab first
        #expect(TabBar.shown(available: all, o) == [.lab, .today, .actions, .settings])
        #expect(TabBar.editable(available: all, o) == [.lab, .today, .actions, .chat, .settings])
        // Settings can't be hidden, not even by a hand-edited file.
        o.setVisible("settings", false)
        #expect(TabBar.shown(available: all, o).contains(.settings) && !TabBar.canHide(.settings))
        // Without a server there is no Lab tab to show.
        #expect(TabBar.shown(available: [.today, .settings], o) == [.today, .settings])
    }

    @Test func hiddenTabsAndTheirLinks() async throws {
        let (m, _, _, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        try m.save(lab, token: nil)
        await m.refresh()
        #expect(m.shownTabs == [.today, .actions, .chat, .lab, .settings])
        m.settings.tabOrder = ItemOrder(order: [], hidden: ["today", "chat"])
        #expect(m.shownTabs == [.actions, .lab, .settings])
        m.validateTab()
        #expect(m.tab == .actions)                                  // Today is gone: the first shown tab
        // A link to a hidden tab stays on a shown one and says the tab is hidden.
        m.open(URL(string: "homelab://chat")!)
        #expect(m.tab == .actions && m.hiddenTabNotice == .chat)
        m.dismissHiddenTabNotice()
        #expect(m.hiddenTabNotice == nil)
        m.open(URL(string: "homelab://lab")!)
        #expect(m.tab == .lab && m.hiddenTabNotice == nil)
        #expect(!m.go(.today) && m.hiddenTabNotice == .today && m.tab == .lab)
        // Tabs in a new order still open by link.
        m.settings.tabOrder = ItemOrder(order: ["settings", "lab"], hidden: [])
        #expect(Array(m.shownTabs.prefix(2)) == [.settings, .lab])
    }

    // MARK: Chat

    @Test func chatTextSizeShiftsOneStepAndStopsAtTheEnds() {
        #expect(ChatTextSize.small.shifted(3, count: 12) == 2 && ChatTextSize.large.shifted(3, count: 12) == 4)
        #expect(ChatTextSize.standard.shifted(3, count: 12) == 3)
        #expect(ChatTextSize.small.shifted(0, count: 12) == 0 && ChatTextSize.large.shifted(11, count: 12) == 11)
        #expect(ChatTextSize.allCases.map(\.title) == ["Small", "Default", "Large"])
    }

    @Test func chatFoldModes() {
        #expect(ChatFold.folds(lines: 16, mode: .standard) == ChatFold.folds(lines: 16))
        #expect(ChatFold.folds(lines: 15, mode: .standard) == ChatFold.folds(lines: 15))
        #expect(!ChatFold.folds(lines: 9, mode: .short) && ChatFold.folds(lines: 10, mode: .short))   // 6 + 4
        #expect(!ChatFold.folds(lines: 10_000, mode: .never))
        #expect(ChatFold.foldedHeight(lineHeight: 22, mode: .short) == 132)
        #expect(ChatFold.foldedHeight(lineHeight: 22, mode: .standard) == ChatFold.foldedHeight(lineHeight: 22))
        #expect(ChatFold.folds(height: 22 * 30, lineHeight: 22, mode: .short))
    }

    // MARK: Advanced title

    @Test func advancedTitleFollowsThePersonality() {
        #expect(AdvancedTitle.text(.off) == "Advanced" && AdvancedTitle.text(.dry) == "Advanced")
        #expect(AdvancedTitle.text(.snarky) == "Nerd section")
        #expect(AdvancedTitle.text(.ultrakill) != "Advanced")
        for p in Personality.allCases { #expect(!AdvancedTitle.text(p).isEmpty) }
    }

    // MARK: Settings file

    @Test func defaultsAreOmittedAndOldFilesDecodeAsToday() throws {
        var s = AppSettings()
        s.startTileOrder = .standard
        s.labOrder = .standard
        s.tabOrder = .standard
        s.chatSize = .standard
        s.chatFolding = .standard
        #expect(s == AppSettings() && !s.customizedElsewhere)
        let text = String(decoding: try Storage.encoder.encode(s), as: UTF8.self)
        for key in ["startTiles", "labBlocks", "tabs", "chatText", "chatFold"] { #expect(!text.contains(key)) }
        let old = try Storage.decoder.decode(AppSettings.self, from: Data(#"{"faceIDLock":true,"notifyPending":true,"notifyProblems":false}"#.utf8))
        #expect(old.faceIDLock && old.startTiles == nil && old.tabs == nil && old.chatText == nil)
    }

    @Test func customSettingsRoundTripAndAnOddValueFallsBackAlone() throws {
        var s = AppSettings()
        s.faceIDLock = true
        s.startTileOrder = ItemOrder(order: ["b", "a"], hidden: ["c"])
        s.labOrder = ItemOrder(order: [], hidden: ["dns"])
        s.tabOrder = ItemOrder(order: ["lab"], hidden: ["chat"])
        s.chatSize = .large
        s.chatFolding = .never
        #expect(s.customizedElsewhere)
        let data = try Storage.encoder.encode(s)
        #expect(try Storage.decoder.decode(AppSettings.self, from: data) == s)
        #expect(try Storage.encoder.encode(Storage.decoder.decode(AppSettings.self, from: data)) == data)
        let odd = try Storage.decoder.decode(AppSettings.self, from: Data(#"{"faceIDLock":true,"chatText":"huge","tabs":5,"chatFold":"never"}"#.utf8))
        #expect(odd.faceIDLock && odd.chatText == nil && odd.tabs == nil && odd.chatFold == .never)
    }
}
