import HomelabDesign
import HomelabKit
import SwiftUI

/// Home Assistant: the pinned entities, toggles and scripts. Not a dashboard clone; the pins are chosen here.
@MainActor @Observable
final class HomeModel {
    var entities: [HAEntity] = []
    var error: APIError?
    var loading = false
    var busy: Set<String> = []
    var actionError: String?

    func load(_ api: any HomeAssistantAPI, host: String) async {
        loading = true
        do {
            entities = try await api.states()
            error = nil
        } catch {
            let e = APIError.from(error, host: host)
            if e != .cancelled { self.error = e }
        }
        loading = false
    }

    func tap(_ entity: HAEntity, api: any HomeAssistantAPI, host: String) async {
        busy.insert(entity.entityID)
        do {
            let changed = try await api.call(entity)
            for c in changed {
                if let i = entities.firstIndex(where: { $0.entityID == c.entityID }) { entities[i] = c }
            }
            // HA sometimes answers before the device reports its new state.
            if changed.isEmpty || entity.control == .toggle {
                try? await Task.sleep(for: .milliseconds(700))
                if let fresh = try? await api.states() { entities = fresh }
            }
        } catch {
            actionError = "\(entity.name): \(APIError.from(error, host: host).message)"
        }
        busy.remove(entity.entityID)
    }
}

struct HomeView: View {
    let model: AppModel
    @State private var home = HomeModel()
    @State private var picking = false

    private var server: ServerConfig? { model.homeAssistant }

    private var pinned: [HAEntity] {
        guard let server else { return [] }
        let byID = Dictionary(home.entities.map { ($0.entityID, $0) }, uniquingKeysWith: { a, _ in a })
        return server.pinnedEntities.compactMap { byID[$0] }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = home.error {
                    ErrorBanner(error: error, snapshotAge: nil) { Task { await load() } }
                        .listRowBackground(Color.clear)
                }
                let groups = Dictionary(grouping: pinned, by: \.domain)
                ForEach(groups.keys.sorted(by: domainOrder), id: \.self) { domain in
                    Section(domainTitle(domain)) {
                        ForEach(groups[domain] ?? []) { e in
                            EntityRow(entity: e, busy: home.busy.contains(e.entityID)) {
                                guard let server else { return }
                                Task { await home.tap(e, api: model.homeAssistantAPI(for: server), host: server.host) }
                            }
                        }
                    }
                }
            }
            .overlay {
                if pinned.isEmpty, !home.loading, home.error == nil {
                    ContentUnavailableView {
                        Label("No devices pinned", systemImage: "pin")
                    } description: {
                        Text("Pick the lights, switches and scripts you want here.")
                    } actions: {
                        Button("Choose devices") { picking = true }.buttonStyle(.borderedProminent)
                    }
                } else if home.loading && home.entities.isEmpty {
                    ProgressView()
                }
            }
            .refreshable { await load() }
            .navigationTitle(server?.name ?? "Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { picking = true } label: { Label("Edit", systemImage: "pin") }
                        .disabled(home.entities.isEmpty)
                }
            }
            .sheet(isPresented: $picking) {
                if let server {
                    EntityPicker(entities: home.entities, selected: server.pinnedEntities) { model.setPinned($0, for: server.id) }
                }
            }
            .alert("Didn't work", isPresented: Binding(get: { home.actionError != nil }, set: { if !$0 { home.actionError = nil } })) {
                Button("OK") {}
            } message: {
                Text(home.actionError ?? "")
            }
            .task(id: server?.id) {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    private func load() async {
        guard let server else { return }
        await home.load(model.homeAssistantAPI(for: server), host: server.host)
    }

    private func domainOrder(_ a: String, _ b: String) -> Bool {
        let order = ["light", "switch", "fan", "input_boolean", "scene", "script", "button", "input_button", "sensor", "binary_sensor"]
        return (order.firstIndex(of: a) ?? 99, a) < (order.firstIndex(of: b) ?? 99, b)
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

struct EntityRow: View {
    let entity: HAEntity
    let busy: Bool
    let tap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entitySymbol(entity))
                .foregroundStyle(entity.isOn ? Color.yellow : Color.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name)
                if let changed = entity.lastChanged {
                    Text(Format.age(changed)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy {
                ProgressView()
            } else {
                switch entity.control {
                case .toggle:
                    Toggle(entity.name, isOn: Binding(get: { entity.isOn }, set: { _ in tap() }))
                        .labelsHidden()
                        .disabled(!entity.isAvailable)
                case .run:
                    Button("Run", action: tap).buttonStyle(.bordered).disabled(!entity.isAvailable)
                case .none:
                    Text(entity.displayState).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(entity.displayState))
    }
}

/// Choose which entities the Home tab shows.
struct EntityPicker: View {
    let entities: [HAEntity]
    @State var selected: [String]
    let save: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(entities: [HAEntity], selected: [String], save: @escaping ([String]) -> Void) {
        self.entities = entities
        _selected = State(initialValue: selected)
        self.save = save
    }

    private var useful: [HAEntity] {
        let domains: Set<String> = ["light", "switch", "fan", "input_boolean", "scene", "script", "button", "input_button",
                                    "sensor", "binary_sensor", "automation"]
        return entities.filter { domains.contains($0.domain) }.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.entityID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                let groups = Dictionary(grouping: useful, by: \.domain)
                ForEach(groups.keys.sorted(), id: \.self) { domain in
                    Section(domainTitle(domain)) {
                        ForEach(groups[domain] ?? []) { e in
                            Button {
                                if let i = selected.firstIndex(of: e.entityID) { selected.remove(at: i) } else { selected.append(e.entityID) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(e.name).foregroundStyle(.primary)
                                        Text(e.entityID).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected.contains(e.entityID) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .accessibilityAddTraits(selected.contains(e.entityID) ? .isSelected : [])
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Pinned devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(selected)
                        dismiss()
                    }
                }
            }
        }
    }
}
