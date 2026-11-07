import HomelabDesign
import HomelabKit
import SwiftUI

/// Loads Home Assistant entities and runs taps on them. Used by the tiles on Today.
@MainActor @Observable
final class HomeModel {
    var entities: [HAEntity] = []
    var error: APIError?
    var loading = false
    var busy: Set<String> = []
    var actionError: String?
    private var loadedFor: String?

    /// A different Home Assistant (new address) means the old entities don't exist there.
    func reset(for server: ServerConfig?) {
        guard server?.target != loadedFor else { return }
        loadedFor = server?.target
        entities = []
        error = nil
        busy = []
    }

    func load(_ api: any HomeAssistantAPI, host: String) async {
        let sid = loadedFor
        loading = true
        defer { loading = false }
        do {
            let fresh = try await api.states()
            guard sid == loadedFor else { return }   // another Home Assistant now
            entities = fresh
            error = nil
        } catch {
            guard sid == loadedFor else { return }
            let e = APIError.from(error, host: host)
            if e != .cancelled { self.error = e }
        }
    }

    func tap(_ entity: HAEntity, api: any HomeAssistantAPI, host: String) async {
        let sid = loadedFor
        busy.insert(entity.entityID)
        defer { busy.remove(entity.entityID) }
        do {
            let changed = try await api.call(entity)
            guard sid == loadedFor else { return }
            // VoiceOver hears that it worked; a failure gets the alert below.
            announce(entity.control == .toggle ? String(localized: "\(entity.name): switched") : String(localized: "\(entity.name): ran"))
            for c in changed {
                if let i = entities.firstIndex(where: { $0.entityID == c.entityID }) { entities[i] = c }
            }
            // HA sometimes answers before the device reports its new state.
            if changed.isEmpty || entity.control == .toggle {
                try? await Task.sleep(for: .milliseconds(700))
                if let fresh = try? await api.states(), sid == loadedFor { entities = fresh }
            }
        } catch {
            guard sid == loadedFor else { return }
            actionError = "\(entity.name): \(APIError.from(error, host: host).message)"
        }
    }
}

/// Home Assistant on Today: only the few pinned things I use often (owner, 2026-11-05: living room lamps and
/// "stop the morning routine"), as tiles. Everything else stays in the HA app. The pins are chosen with "Edit".
struct HomeTiles: View {
    let model: AppModel
    let server: ServerConfig
    @State private var home = HomeModel()
    @State private var picking = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private var pinned: [HAEntity] {
        let byID = Dictionary(home.entities.map { ($0.entityID, $0) }, uniquingKeysWith: { a, _ in a })
        return server.pinnedEntities.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Home", action: home.entities.isEmpty ? nil : ("Edit", { picking = true }))
            if let error = home.error {
                ErrorBanner(error: error, snapshotAge: nil, retry: { Task { await load() } }, edit: { model.requestEdit(server.id) })
            }
            if pinned.isEmpty {
                if home.loading && home.entities.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).panel()
                } else if home.error == nil {
                    Button { picking = true } label: {
                        Label("Pin the lights or scripts you use most", systemImage: "pin")
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondary)
                            .panel()
                    }
                    .buttonStyle(.press)
                    .disabled(home.entities.isEmpty)
                }
            } else {
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())]
                                                                : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(pinned) { e in
                        HomeTile(entity: e, customName: server.tileName(for: e.entityID), customIcon: server.tileIcon(for: e.entityID), busy: home.busy.contains(e.entityID)) {
                            Task { await home.tap(e, api: model.homeAssistantAPI(for: server), host: server.host) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $picking) {
            EntityPicker(entities: home.entities, selected: server.pinnedEntities, names: server.tileNames, icons: server.tileIcons) {
                model.setPinned($0, names: $1, icons: $2, for: server.id)
            }
        }
        .alert("Didn't work", isPresented: Binding(get: { home.actionError != nil }, set: { if !$0 { home.actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(home.actionError ?? "")
        }
        .task(id: PollKey(server: server.target, active: scenePhase == .active)) {
            home.reset(for: server)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        await home.load(model.homeAssistantAPI(for: server), host: server.host)
    }
}

/// One Home Assistant tile: icon, name, state. Tap toggles a light/switch or runs a script/scene. A tile that is on
/// is filled (white on black), so the state reads without colour.
struct HomeTile: View {
    let entity: HAEntity
    /// The name set in Today → Edit; nil shows Home Assistant's friendly name.
    var customName: String?
    /// The icon set in Today → Edit (an SF Symbol from `TileIcon.choices`); nil shows the icon by domain.
    var customIcon: String?
    let busy: Bool
    let tap: () -> Void

    @State private var taps = 0
    /// The icon column grows with the text, so a big symbol isn't clipped at large sizes.
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 28

    private var on: Bool { entity.control == .toggle && entity.isOn }

    var body: some View {
        Button {
            taps += 1
            tap()
        } label: {
            // Design research #3: an "on" tile is not a white block (it outshone the hero): a lifted panel, a filled
            // white symbol and "On" in white; "off" stays a plain panel with an outline symbol and grey words.
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: customIcon.flatMap { TileIcon.shown($0, on: on) } ?? entitySymbol(entity))
                    .font(.title3).foregroundStyle(on ? Palette.text : Palette.secondary)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TileName.shown(custom: customName, haName: entity.name)).font(Typo.secondary.weight(.semibold)).foregroundStyle(Palette.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(stateText).font(Typo.meta).foregroundStyle(on ? Palette.text : Palette.tertiary).lineLimitAtStandardSizes(1)
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small).tint(Palette.text) }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(on ? Palette.raised : Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .motion(.snappy, value: on)
        }
        .buttonStyle(.press)
        .selectionFeedback(trigger: taps)
        .disabled(busy || !entity.isAvailable || entity.control == .none)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(TileName.spoken(custom: customName, haName: entity.name)))
        .accessibilityValue(Text(spokenState))
        .accessibilityHint(hint)
        // A sensor can't be tapped: plain text for VoiceOver, not a "dimmed button".
        .accessibilityAddTraits(entity.control == .toggle ? [.isButton, .isToggle] : entity.control == .run ? .isButton : .isStaticText)
    }

    /// What the tile shows, in words ("On", "ran 3 hours ago"), and "busy" while a tap is on its way.
    private var spokenState: String {
        let state = Format.spoken(stateText)
        return busy ? state + ", " + String(localized: "busy") : state
    }

    private var hint: Text {
        switch entity.control {
        case .toggle: on ? Text("Turns it off") : Text("Turns it on")
        case .run: Text("Runs it")
        case .none: Text("")
        }
    }

    private var stateText: String {
        switch entity.control {
        case .toggle: entity.isAvailable ? (entity.isOn ? String(localized: "On") : String(localized: "Off")) : entity.displayState
        case .run: entity.lastChanged.map { String(localized: "ran \(Format.age($0))") } ?? String(localized: "Tap to run")
        case .none: entity.displayState
        }
    }
}

func domainTitle(_ domain: String) -> String {
    switch domain {
    case "light": String(localized: "Lights")
    case "switch": String(localized: "Switches")
    case "fan": String(localized: "Fans")
    case "input_boolean": String(localized: "Toggles")
    case "scene": String(localized: "Scenes")
    case "script": String(localized: "Scripts")
    case "button", "input_button": String(localized: "Buttons")
    case "sensor": String(localized: "Sensors")
    case "binary_sensor": String(localized: "Contacts and motion")
    case "automation": String(localized: "Automations")
    default: domain.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

func entitySymbol(_ e: HAEntity) -> String {
    switch e.domain {
    case "light": e.isOn ? "lightbulb.fill" : "lightbulb"
    case "switch", "input_boolean": e.isOn ? "power.circle.fill" : "power.circle"
    case "fan": "fan"
    case "script": "play.circle"
    case "scene": "theatermasks"
    case "button", "input_button": "button.programmable"
    case "automation": "gearshape.2"
    case "binary_sensor":
        switch e.deviceClass {
        case "door", "garage_door": e.isOn ? "door.left.hand.open" : "door.left.hand.closed"
        case "window": "window.vertical.closed"
        case "motion", "occupancy", "presence": "figure.walk"
        default: "circle.dotted"
        }
    case "sensor":
        switch e.deviceClass {
        case "temperature": "thermometer.medium"
        case "humidity": "humidity"
        case "power", "energy": "bolt"
        case "battery": "battery.75percent"
        default: "gauge.with.dots.needle.33percent"
        }
    default: "circle"
    }
}

/// Choose which entities Today shows as tiles. "On Today" at the top holds the pinned ones in tile order, each with
/// its name and icon, and can be reordered; the sections below list everything by kind to pin or unpin.
struct EntityPicker: View {
    let entities: [HAEntity]
    @State var selected: [String]
    /// "Name on the tile" by entity id; empty or missing = Home Assistant's friendly name.
    @State var names: [String: String]
    /// Icon by entity id (an SF Symbol from `TileIcon.choices`); missing = the icon by domain.
    @State var icons: [String: String]
    let save: ([String], [String: String], [String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editMode: EditMode = .inactive

    init(entities: [HAEntity], selected: [String], names: [String: String] = [:], icons: [String: String] = [:],
         save: @escaping ([String], [String: String], [String: String]) -> Void) {
        self.entities = entities
        _selected = State(initialValue: selected)
        _names = State(initialValue: names)
        _icons = State(initialValue: icons)
        self.save = save
    }

    private var byID: [String: HAEntity] { Dictionary(entities.map { ($0.entityID, $0) }, uniquingKeysWith: { a, _ in a }) }

    private var useful: [HAEntity] {
        let domains: Set<String> = ["light", "switch", "fan", "input_boolean", "scene", "script", "button", "input_button",
                                    "sensor", "binary_sensor", "automation"]
        return entities.filter { domains.contains($0.domain) }.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.entityID.localizedCaseInsensitiveContains(query)
        }
    }

    /// Typing keeps one line of at most 24 characters; the saved name is cleaned again by the app model.
    private func nameBinding(_ id: String) -> Binding<String> {
        Binding(get: { names[id] ?? "" },
                set: { names[id] = String($0.replacingOccurrences(of: "\n", with: " ").prefix(TileName.maxLength)) })
    }

    private func toggle(_ id: String) {
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) } else { selected.append(id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty && !selected.isEmpty {
                    Section {
                        ForEach(selected, id: \.self) { id in
                            if let e = byID[id] { pinnedRow(e) }
                        }
                        .onMove { selected.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { selected.remove(atOffsets: $0) }
                    } header: {
                        HStack {
                            Text("On Today")
                            Spacer()
                            Button(editMode.isEditing ? "Done ordering" : "Order") {
                                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            }
                            .font(Typo.secondary)
                            .textCase(nil)
                        }
                    } footer: {
                        SettingsFooter("Tiles show in this order, two per row. Empty name: Home Assistant's name. Automatic icon: the one for the kind of entity.")
                    }
                }
                let groups = Dictionary(grouping: useful, by: \.domain)
                ForEach(groups.keys.sorted(), id: \.self) { domain in
                    Section(domainTitle(domain)) {
                        ForEach(groups[domain] ?? []) { e in
                            Button { toggle(e.entityID) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(e.name).foregroundStyle(.primary)
                                        Text(e.entityID).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected.contains(e.entityID) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(e.name))
                            .accessibilityHint(Text(selected.contains(e.entityID) ? "On Today. Removes the tile" : "Adds a tile to Today"))
                            .accessibilityAddTraits(selected.contains(e.entityID) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
                .surfaceRows()
            }
            .environment(\.editMode, $editMode)
            .screenBackground()
            .searchable(text: $query)
            .navigationTitle("Tiles on Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(selected, names, icons)
                        dismiss()
                    }
                }
            }
        }
    }

    /// A pinned entity: its name, then "Name on the tile" (a visible label above the field) and "Icon on the tile".
    private func pinnedRow(_ e: HAEntity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icons[e.entityID].flatMap { TileIcon.shown($0, on: false) } ?? entitySymbol(e))
                    .foregroundStyle(Palette.secondary).frame(width: 26).accessibilityHidden(true)
                Text(e.name).foregroundStyle(Palette.text)
            }
            if !editMode.isEditing {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name on the tile").font(Typo.meta).foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                    TextField("Name on the tile", text: nameBinding(e.entityID),
                              prompt: Text(e.name).foregroundStyle(Palette.tertiary))
                        .font(Typo.secondary)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(Text("Name on the tile for \(e.name)"))
                        .accessibilityHint(Text("Optional. Empty shows Home Assistant's name."))
                }
                iconMenu(e)
            }
        }
        .padding(.vertical, 4)
    }

    /// "Icon on the tile": Automatic (by Home Assistant domain) or one of `TileIcon.choices`.
    private func iconMenu(_ e: HAEntity) -> some View {
        let current = icons[e.entityID].flatMap(TileIcon.choice)
        return Menu {
            Picker("Icon on the tile", selection: Binding(get: { icons[e.entityID] ?? "" },
                                                          set: { icons[e.entityID] = $0.isEmpty ? nil : $0 })) {
                Label("Automatic", systemImage: entitySymbol(e)).tag("")
                ForEach(TileIcon.choices) { c in
                    Label(LocalizedStringKey(c.label), systemImage: c.symbol).tag(c.symbol)
                }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Icon on the tile").foregroundStyle(Palette.text)
                    Spacer()
                    Text(current.map { LocalizedStringKey($0.label) } ?? "Automatic").foregroundStyle(Palette.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Palette.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Icon on the tile").foregroundStyle(Palette.text)
                    Text(current.map { LocalizedStringKey($0.label) } ?? "Automatic").foregroundStyle(Palette.secondary)
                }
            }
            .font(Typo.secondary)
        }
        .accessibilityLabel(Text("Icon on the tile for \(e.name)"))
        .accessibilityValue(Text(current.map { LocalizedStringKey($0.label) } ?? "Automatic"))
    }
}
