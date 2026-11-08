import AppIntents
import HomelabDesign
import HomelabKit
import SwiftUI
import WidgetKit

/// The configurable Actions widget (feature `widget-actions`): a grid of rounded tiles, each an icon and a name, like
/// the Philips Hue widgets. Small 1 or 2, medium 4, large 8 and a lock-screen circle with 1. The Edit menu picks the
/// actions from the server's Start actions as the app cached them (no network); with nothing picked the widget shows
/// the first visible Start tiles.
///
/// A tap runs an action right here (an App Intent in the widget process) when it has no fields, is not destructive and
/// the server is reached by identity (Tailscale); else it opens the action's form in the app (`homelab://actions/<name>`).
/// The widget never reads the Keychain; the rules and the run are `WidgetActions` in HomelabKit. With the app lock on
/// the run asks for Face ID / the passcode first.

// MARK: - Configuration (the Edit menu)

struct ActionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Action")
    static let defaultQuery = ActionEntityQuery()

    var id: String
    var label: String
    var icon: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", image: .init(systemName: Symbols.safe(icon, fallback: "play.circle")))
    }

    init(_ offered: ActionUsage.Offered) {
        id = offered.name; label = offered.label; icon = offered.icon
    }
}

/// Lists the selected server's Start actions from the App Group cache (`action-usage.json`, `settings.json`): no
/// network, so the Edit menu opens at once. Hidden Start tiles come last; they can still be picked.
struct ActionEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ActionEntity] {
        let all = Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ActionEntity] { Self.all() }

    static func all() -> [ActionEntity] {
        let ctx = ActionsContext.load()
        return WidgetActions.choices(ctx.usage, server: ctx.server?.id, order: ctx.order).map(ActionEntity.init)
    }
}

struct ActionsConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Actions"
    static let description = IntentDescription("Pick the actions this widget shows. Leave it empty for the first Start tiles.")

    @Parameter(title: "Actions", size: [.systemSmall: 2, .systemMedium: 4, .systemLarge: 8, .accessoryCircular: 1])
    var actions: [ActionEntity]?

    init() {}
}

/// What the widget reads from the App Group. Nothing here touches the network or the Keychain.
struct ActionsContext {
    var usage: ActionUsage
    var server: ServerConfig?
    var order: ItemOrder?
    var locked: Bool

    static func load() -> ActionsContext {
        let storage = Storage.shared()
        let settings = storage.read(AppSettings.self, AppSettings.fileName)
        return ActionsContext(usage: storage.read(ActionUsage.self, ActionUsage.fileName) ?? ActionUsage(),
                              server: storage.read(ServerList.self, ServerList.fileName)?.selectedServer,
                              order: settings?.startTiles, locked: settings?.faceIDLock ?? false)
    }
}

// MARK: - Running (the tap)

/// Runs one action from the widget. `perform` re-checks everything against the server's own list.
struct RunActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run action"
    static let description = IntentDescription("Runs a Homelab action that needs no input.")
    static let openAppWhenRun = false

    @Parameter(title: "Action") var name: String

    init() { name = "" }
    init(name: String) { self.name = name }

    func perform() async throws -> some IntentResult {
        let ctx = ActionsContext.load()
        _ = await WidgetActions.run(name, server: ctx.server, transport: URLSessionTransport.widget, storage: Storage.shared())
        WidgetCenter.shared.reloadTimelines(ofKind: actionsWidgetKind)
        return .result()
    }
}

/// The same with the app lock on: iOS asks for Face ID or the passcode before `perform` runs, also on the Lock Screen.
/// (The policy is static, so the widget picks this intent when the lock is on.)
struct RunActionLockedIntent: AppIntent {
    static let title: LocalizedStringResource = "Run action (locked)"
    static let description = IntentDescription("Runs a Homelab action that needs no input, after Face ID.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Action") var name: String

    init() { name = "" }
    init(name: String) { self.name = name }

    func perform() async throws -> some IntentResult {
        let ctx = ActionsContext.load()
        _ = await WidgetActions.run(name, server: ctx.server, transport: URLSessionTransport.widget, storage: Storage.shared())
        WidgetCenter.shared.reloadTimelines(ofKind: actionsWidgetKind)
        return .result()
    }
}

// MARK: - Widget

struct ActionsEntry: TimelineEntry {
    struct Tile: Identifiable {
        var action: ActionUsage.Offered
        var tap: WidgetActions.Tap
        var shown: WidgetActions.Shown?
        var id: String { action.name }
    }

    var date: Date
    var tiles: [Tile]
    var locked: Bool
    /// There is a server with a cached Start list at all.
    var hasServer: Bool
}

struct ActionsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ActionsEntry {
        sample(Array(Self.sampleActions.prefix(Self.size(context.family).capacity)))
    }

    func snapshot(for configuration: ActionsConfiguration, in context: Context) async -> ActionsEntry {
        if context.isPreview { return placeholder(in: context) }
        return entries(configuration, context, now: Date()).first ?? placeholder(in: context)
    }

    func timeline(for configuration: ActionsConfiguration, in context: Context) async -> Timeline<ActionsEntry> {
        let now = Date()
        let list = entries(configuration, context, now: now)
        // Nothing to fetch: the names come from the cache. A result tile reverts by itself after `resultLife`.
        return Timeline(entries: list, policy: .after(now.addingTimeInterval(list.count > 1 ? WidgetActions.resultLife + 1 : 30 * 60)))
    }

    private func entries(_ configuration: ActionsConfiguration, _ context: Context, now: Date) -> [ActionsEntry] {
        let ctx = ActionsContext.load()
        let size = Self.size(context.family)
        let picked = (configuration.actions ?? []).map(\.id)
        let offered = WidgetActions.tiles(picked: picked, usage: ctx.usage, server: ctx.server?.id, order: ctx.order, size: size)
        let shown = Storage.shared().read(WidgetActions.Shown.self, WidgetActions.Shown.fileName)
        func entry(at date: Date, with result: WidgetActions.Shown?) -> ActionsEntry {
            ActionsEntry(date: date, tiles: offered.map { a in
                ActionsEntry.Tile(action: a, tap: WidgetActions.tap(a, server: ctx.server),
                                  shown: result?.name == a.name ? result : nil)
            }, locked: ctx.locked, hasServer: ctx.server != nil && !ctx.usage.offered.isEmpty)
        }
        guard let shown, shown.isFresh(at: now), offered.contains(where: { $0.name == shown.name }) else {
            return [entry(at: now, with: nil)]
        }
        return [entry(at: now, with: shown), entry(at: shown.date.addingTimeInterval(WidgetActions.resultLife), with: nil)]
    }

    static func size(_ family: WidgetFamily) -> WidgetActions.Size {
        switch family {
        case .systemMedium: .medium
        case .systemLarge: .large
        case .accessoryCircular: .circular
        default: .small
        }
    }

    static let sampleActions = [
        ActionUsage.Offered(name: "wake-pc", label: "Wake PC", icon: "power", destructive: false, needsInput: false),
        ActionUsage.Offered(name: "todo-add", label: "Add a to-do", icon: "checklist", destructive: false, needsInput: true),
        ActionUsage.Offered(name: "lights", label: "Lights", icon: "lightbulb", destructive: false, needsInput: false),
        ActionUsage.Offered(name: "silence", label: "Silence", icon: "speaker.slash", destructive: false, needsInput: false),
        ActionUsage.Offered(name: "night", label: "Night", icon: "moon.stars", destructive: false, needsInput: false),
        ActionUsage.Offered(name: "tv", label: "TV", icon: "tv", destructive: false, needsInput: false),
        ActionUsage.Offered(name: "alarm", label: "Wake-up", icon: "alarm", destructive: false, needsInput: true),
        ActionUsage.Offered(name: "radio", label: "Radio", icon: "radio", destructive: false, needsInput: false),
    ]

    private func sample(_ actions: [ActionUsage.Offered]) -> ActionsEntry {
        ActionsEntry(date: Date(), tiles: actions.map { .init(action: $0, tap: $0.needsInput == true ? .opensApp : .runs) },
                     locked: false, hasServer: true)
    }
}

let actionsWidgetKind = "HomelabActions"

struct ActionsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: actionsWidgetKind, intent: ActionsConfiguration.self, provider: ActionsProvider()) { entry in
            ActionsWidgetView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // grows with the text size, but fits the widget
                .containerBackground(Palette.background, for: .widget)
        }
        .configurationDisplayName("Actions")
        .description("Tiles for your Start actions. Tap to run one, or to open its form.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular])
    }
}

// MARK: - Views

struct ActionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ActionsEntry

    private static let fallback = URL(string: "homelab://actions")!

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .systemMedium: grid(columns: 2, rows: 2)
        case .systemLarge: grid(columns: 2, rows: 4)
        default: small
        }
    }

    // MARK: Lock screen

    @ViewBuilder
    private var circular: some View {
        if let tile = entry.tiles.first {
            control(tile) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: glyph(tile, fallback: "play.circle")).font(.title3.weight(.semibold)).widgetAccentable()
                }
            }
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.grid.2x2").font(.title3)
            }
            .widgetURL(Self.fallback)
            .accessibilityLabel(Text("Actions: open the app"))
        }
    }

    // MARK: Home screen

    @ViewBuilder
    private var small: some View {
        switch entry.tiles.count {
        case 0: empty
        case 1: control(entry.tiles[0]) { TileView(tile: entry.tiles[0], large: true) }
        default:
            VStack(spacing: 8) {
                ForEach(entry.tiles.prefix(2)) { tile in control(tile) { TileView(tile: tile, large: false) } }
            }
        }
    }

    @ViewBuilder
    private func grid(columns: Int, rows: Int) -> some View {
        if entry.tiles.isEmpty {
            empty
        } else {
            let slots = columns * rows
            let cells = Array(entry.tiles.prefix(slots))
            VStack(spacing: 8) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(0..<columns, id: \.self) { c in
                            let i = r * columns + c
                            if i < cells.count {
                                control(cells[i]) { TileView(tile: cells[i], large: false) }
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private var empty: some View {
        Link(destination: Self.fallback) {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.title2).foregroundStyle(Palette.secondary)
                Text(entry.hasServer ? "No actions to show" : "Open the app once")
                    .font(.footnote.weight(.medium)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: One tile

    private func glyph(_ tile: ActionsEntry.Tile, fallback: String) -> String {
        if let shown = tile.shown { return shown.ok ? "checkmark" : "exclamationmark.triangle.fill" }
        return Symbols.safe(tile.action.icon, fallback: fallback)
    }

    /// A button that runs the action here, or a link that opens its form in the app.
    @ViewBuilder
    private func control<Content: View>(_ tile: ActionsEntry.Tile, @ViewBuilder content: () -> Content) -> some View {
        let label = WidgetActions.spoken(tile.action, tap: tile.tap, result: tile.shown?.text)
        switch tile.tap {
        case .runs:
            if entry.locked {
                Button(intent: RunActionLockedIntent(name: tile.action.name)) { content() }
                    .buttonStyle(.plain).accessibilityLabel(Text(label))
            } else {
                Button(intent: RunActionIntent(name: tile.action.name)) { content() }
                    .buttonStyle(.plain).accessibilityLabel(Text(label))
            }
        case .opensApp:
            Link(destination: WidgetActions.openURL(tile.action.name)) { content() }.accessibilityLabel(Text(label))
        }
    }
}

/// A rounded tile: the icon and the name; for a moment after a run, its result instead of the name.
private struct TileView: View {
    let tile: ActionsEntry.Tile
    let large: Bool

    private var icon: String {
        if let shown = tile.shown { return shown.ok ? "checkmark" : "exclamationmark.triangle.fill" }
        return Symbols.safe(tile.action.icon, fallback: "play.circle")
    }

    private var failed: Bool { tile.shown?.ok == false }
    private var tint: Color { failed ? Palette.love : Palette.text }
    private var name: String { tile.shown?.text ?? tile.action.label }

    var body: some View {
        Group {
            if large {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: icon).font(.title.weight(.semibold)).foregroundStyle(tint)
                    Spacer(minLength: 4)
                    label(.subheadline)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(tint).frame(minWidth: 24)
                    label(.footnote)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(failed ? Palette.love.opacity(0.6) : Palette.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func label(_ font: Font) -> some View {
        Text(name).font(font.weight(.medium)).foregroundStyle(failed ? Palette.love : Palette.text)
            .lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
    }
}
