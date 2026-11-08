import HomelabDesign
import HomelabKit
import SwiftUI
import UserNotifications

/// Settings → Advanced (its title follows the personality: `AdvancedTitle`). The detailed settings live here so the
/// page behind the Settings tab stays short: Today's sections and show rules, Start tiles, Lab, Chat, the tab bar,
/// quiet hours, the lock-screen Leave-by, Diagnostics and Demo servers (docs/DESIGN.md "Settings").
struct AdvancedSettingsView: View {
    @Bindable var model: AppModel

    private var layout: ItemOrder { model.settings.startTileOrder }

    var body: some View {
        Form {
            Group {
                Section {
                    NavigationLink {
                        TodayLayoutEditor(model: model)
                    } label: {
                        LabeledContent("Sections") {
                            Text("\(model.settings.todayLayout.listedVisibleCount) of \(TodaySection.allCases.filter(\.isOnToday).count)")
                                .font(Typo.secondary).foregroundStyle(Palette.secondary)
                        }
                    }
                    PresenceRow(model: model)
                } header: {
                    Text("Today")
                } footer: {
                    SettingsFooter("Which sections Today shows, in which order and when. Where you are lets the At home and Away rules follow you.")
                }

                Section {
                    NavigationLink {
                        StartTilesEditor(model: model)
                    } label: {
                        LabeledContent("Start tiles") { Text(verbatim: startSummary).font(Typo.secondary).foregroundStyle(Palette.secondary) }
                    }
                    NavigationLink {
                        LabLayoutEditor(model: model)
                    } label: {
                        LabeledContent("Lab") { Text(verbatim: labSummary).font(Typo.secondary).foregroundStyle(Palette.secondary) }
                    }
                    NavigationLink {
                        TabBarEditor(model: model)
                    } label: {
                        LabeledContent("Tab bar") { Text(verbatim: tabSummary).font(Typo.secondary).foregroundStyle(Palette.secondary) }
                    }
                } header: {
                    Text("Layout")
                } footer: {
                    SettingsFooter("Hide and reorder the Start tiles on Actions, the blocks in Lab and the tabs. Whatever your server adds later shows up at the end.")
                }

                Section {
                    Picker("Text size", selection: Binding(get: { model.settings.chatSize }, set: { model.settings.chatSize = $0 })) {
                        ForEach(ChatTextSize.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    Picker("Long replies", selection: Binding(get: { model.settings.chatFolding }, set: { model.settings.chatFolding = $0 })) {
                        ForEach(ChatFoldMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                } header: {
                    Text("Chat")
                } footer: {
                    SettingsFooter(verbatim: chatFooter)
                }

                Section {
                    QuietHoursRow(model: model)
                } header: {
                    Text("Notifications")
                } footer: {
                    SettingsFooter("No local notifications inside this window.")
                }

                // Only for a server that sends a commute (or while on, so it can be turned off).
                if model.selectedStatus.snapshot?.state.commute != nil || model.settings.leaveByOn {
                    Section {
                        Toggle("Leave-by on the lock screen", isOn: Binding(
                            get: { model.settings.leaveByOn }, set: { model.settings.leaveByOn = $0 }))
                    } footer: {
                        SettingsFooter("When the server sends a leave-by time for the morning, opening the app puts it on the lock screen (for example \"Leave by 07:26 · U6 07:31\") until you're there. It only starts while the app is open, and needs Live Activities allowed for Homelab in iOS Settings.")
                    }
                }

                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView(model: model) }
                    Toggle("Demo servers", isOn: Binding(get: { model.isDemo }, set: { model.setDemo($0) }))
                } header: {
                    Text("Servers and data")
                } footer: {
                    SettingsFooter("Diagnostics shows connection, storage and background details for a bug report. Demo servers are two servers with made-up example data, marked Demo in the lists; your own servers stay.")
                }

                Section {
                    Button("Reset layout and chat options") { resetCustomization() }
                        .disabled(!model.settings.customizedElsewhere)
                } footer: {
                    SettingsFooter("Back to the standard Start tiles, Lab, tab bar and chat. Today's sections have their own reset.")
                }
            }
            .surfaceRows()
            .headerProminence(.increased)
        }
        .screenBackground()
        .navigationTitle(LocalizedStringKey(AdvancedTitle.text(model.settings.voice)))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resetCustomization() {
        model.settings.startTileOrder = .standard
        model.settings.labOrder = .standard
        model.settings.tabOrder = .standard
        model.settings.chatSize = .standard
        model.settings.chatFolding = .standard
    }

    private var startSummary: String {
        let specs = model.selectedStatus.features.contains(.runActions) ? model.selectedStatus.actions.filter(\.start) : []
        if specs.isEmpty { return String(localized: "None on your server") }
        return String(localized: "\(StartTiles.arrange(specs, model.settings.startTiles).count) of \(specs.count)")
    }

    private var labSummary: String {
        let cards = model.selectedStatus.snapshot?.state.cards.filter { $0.place == .lab } ?? []
        let all = LabBlocks.standardIDs(cards: cards)
        return String(localized: "\(LabBlocks.visibleIDs(cards: cards, model.settings.labBlocks).count) of \(all.count)")
    }

    private var tabSummary: String {
        String(localized: "\(model.shownTabs.count) of \(model.availableTabs.count)")
    }

    private var chatFooter: String {
        String(localized: "Text size is one step from your iPhone's size. Long replies fold after 12 lines by default; Short folds after 6, Never fold shows them whole.")
    }
}

// MARK: Order editors

/// One row of an order editor: the name, an optional second line, a switch to show it. The handle comes from the list's
/// edit mode; VoiceOver gets "Move up" and "Move down" actions. At least 44 pt high.
private struct OrderRow: View {
    let title: String
    var detail: String?
    let isOn: Bool
    var canHide = true
    let set: @MainActor @Sendable (Bool) -> Void
    let nudge: @MainActor @Sendable (Int) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stack = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                 : AnyLayout(HStackLayout(spacing: 12))
        stack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(Typo.body).foregroundStyle(Palette.text)
                if let detail { Text(verbatim: detail).font(Typo.meta).foregroundStyle(Palette.tertiary) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Toggle(isOn: Binding(get: { isOn }, set: set)) { Text(verbatim: title) }
                .labelsHidden()
                .disabled(!canHide)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: title + (isOn ? "" : ", " + String(localized: "hidden"))))
        .accessibilityAction(named: Text("Move up")) { nudge(-1) }
        .accessibilityAction(named: Text("Move down")) { nudge(1) }
    }
}

/// A list that hides and reorders ids in an `ItemOrder` kept in the settings.
private struct OrderEditor<Footer: View>: View {
    let title: LocalizedStringKey
    let ids: [String]
    let order: Binding<ItemOrder>
    let name: (String) -> String
    var detail: (String) -> String? = { _ in nil }
    var canHide: (String) -> Bool = { _ in true }
    var empty: LocalizedStringKey?
    @ViewBuilder var footer: Footer

    var body: some View {
        List {
            Group {
                Section {
                    if ids.isEmpty, let empty {
                        Text(empty).font(Typo.secondary).foregroundStyle(Palette.secondary)
                    }
                    ForEach(ids, id: \.self) { id in
                        OrderRow(title: name(id), detail: detail(id), isOn: order.wrappedValue.isVisible(id) || !canHide(id),
                                 canHide: canHide(id),
                                 set: { order.wrappedValue.setVisible(id, $0) },
                                 nudge: { order.wrappedValue.nudge(id, in: ids, by: $0) })
                    }
                    .onMove { order.wrappedValue.move(ids, fromOffsets: $0, toOffset: $1) }
                } footer: {
                    footer
                }
                Section {
                    Button("Standard order") { order.wrappedValue = .standard }
                        .disabled(order.wrappedValue.isStandard)
                }
            }
            .surfaceRows()
            .headerProminence(.increased)
        }
        .screenBackground()
        .environment(\.editMode, .constant(.active))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Actions tab: the server's Start tiles, by the action's name.
struct StartTilesEditor: View {
    let model: AppModel

    private var specs: [ActionSpec] {
        model.selectedStatus.features.contains(.runActions) ? model.selectedStatus.actions.filter(\.start) : []
    }

    var body: some View {
        let editable = StartTiles.editable(specs, model.settings.startTiles)
        OrderEditor(title: "Start tiles", ids: editable.map(\.name),
                    order: Binding(get: { model.settings.startTileOrder }, set: { model.settings.startTileOrder = $0 }),
                    name: { id in editable.first { $0.name == id }?.label ?? id },
                    detail: { $0 },
                    empty: "Your server has no Start tiles yet.") {
            SettingsFooter("These are the tiles of Start on the Actions tab, from your server. A hidden tile can still be opened by a homelab:// link. New tiles from the server appear at the end.")
        }
    }
}

/// Lab: Hosts, the server's lab cards and Services. Problems stay on top and can't be hidden.
struct LabLayoutEditor: View {
    let model: AppModel

    private var cards: [Card] { model.selectedStatus.snapshot?.state.cards.filter { $0.place == .lab } ?? [] }

    var body: some View {
        let cards = cards
        OrderEditor(title: "Lab", ids: LabBlocks.ids(cards: cards, model.settings.labBlocks),
                    order: Binding(get: { model.settings.labOrder }, set: { model.settings.labOrder = $0 }),
                    name: { LabBlocks.title($0, cards: cards) },
                    detail: { $0.hasPrefix("@") ? nil : $0 }) {
            SettingsFooter("Problems always stay at the top of Lab. Cards come from your server; new ones appear at the end.")
        }
    }
}

/// The tab bar. Settings can never be hidden.
struct TabBarEditor: View {
    let model: AppModel

    var body: some View {
        let tabs = TabBar.editable(available: model.availableTabs, model.settings.tabs)
        OrderEditor(title: "Tab bar", ids: tabs.map(\.rawValue),
                    order: Binding(get: { model.settings.tabOrder }, set: { model.settings.tabOrder = $0 }),
                    name: { AppTab(rawValue: $0)?.title ?? $0 },
                    detail: { $0 == AppTab.settings.rawValue ? String(localized: "Always on") : nil },
                    canHide: { AppTab(rawValue: $0).map(TabBar.canHide) ?? true }) {
            SettingsFooter("The first tab is where the app opens. A link to a hidden tab (a widget, a notification) says the tab is hidden instead of opening it. Settings stays, so you can always come back here.")
        }
    }
}
