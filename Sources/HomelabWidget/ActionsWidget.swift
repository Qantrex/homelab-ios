import HomelabDesign
import HomelabKit
import SwiftUI
import WidgetKit

/// The Actions widget (feature `widget-actions`): a grid of rounded tiles, each an icon and a name, like the Philips
/// Hue widgets. Small 1 or 2, medium 4, large 8 and a lock-screen circle with 1. It shows the first Start tiles in the
/// order from Settings → Advanced → Start tiles (hidden ones left out), from the cache the app keeps in the App Group.
///
/// It is a static widget (no Edit menu, no App Intents: xtool writes no `Metadata.appintents`, so those never worked
/// from our IPA). A tap is a link into the app (`homelab://actions/<name>`; a simple action adds `run=1` and the app
/// runs it at once and says "Done"); the rules are `WidgetActions` in HomelabKit. The widget never reads the Keychain
/// or the network.

/// What the widget reads from the App Group.
struct ActionsContext {
    var usage: ActionUsage
    var server: ServerConfig?
    var order: ItemOrder?

    static func load() -> ActionsContext {
        let storage = Storage.shared()
        let settings = storage.read(AppSettings.self, AppSettings.fileName)
        return ActionsContext(usage: storage.read(ActionUsage.self, ActionUsage.fileName) ?? ActionUsage(),
                              server: storage.read(ServerList.self, ServerList.fileName)?.selectedServer,
                              order: settings?.startTiles)
    }
}

struct ActionsEntry: TimelineEntry {
    var date: Date
    var tiles: [ActionUsage.Offered]
    /// There is a server with a cached Start list at all.
    var hasServer: Bool
}

struct ActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActionsEntry { sample(context.family) }

    func getSnapshot(in context: Context, completion: @escaping (ActionsEntry) -> Void) {
        completion(context.isPreview ? sample(context.family) : entry(context.family) ?? sample(context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActionsEntry>) -> Void) {
        // Nothing to fetch: the names come from the cache.
        let now = Date()
        let e = entry(context.family) ?? ActionsEntry(date: now, tiles: [], hasServer: false)
        completion(Timeline(entries: [e], policy: .after(now.addingTimeInterval(30 * 60))))
    }

    /// The real tiles, or nil when there is no server with a Start list (the gallery then shows the samples).
    private func entry(_ family: WidgetFamily) -> ActionsEntry? {
        let ctx = ActionsContext.load()
        let tiles = WidgetActions.tiles(usage: ctx.usage, server: ctx.server?.id, order: ctx.order, size: Self.size(family))
        guard ctx.server != nil, !tiles.isEmpty else { return nil }
        return ActionsEntry(date: Date(), tiles: tiles, hasServer: true)
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

    private func sample(_ family: WidgetFamily) -> ActionsEntry {
        ActionsEntry(date: Date(), tiles: Array(Self.sampleActions.prefix(Self.size(family).capacity)), hasServer: true)
    }
}

let actionsWidgetKind = "HomelabActions"

struct ActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: actionsWidgetKind, provider: ActionsProvider()) { entry in
            ActionsWidgetView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // grows with the text size, but fits the widget
                .containerBackground(Palette.background, for: .widget)
        }
        .configurationDisplayName("Actions")
        .description("Tiles for your first Start actions, in your order. Tap one: it runs, or opens its form.")
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
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: Symbols.safe(tile.icon, fallback: "play.circle")).font(.title3.weight(.semibold)).widgetAccentable()
            }
            .widgetURL(WidgetActions.tapURL(tile))
            .accessibilityLabel(Text(WidgetActions.spoken(tile)))
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
        case 1: link(entry.tiles[0]) { TileView(tile: entry.tiles[0], large: true) }
        default:
            VStack(spacing: 8) {
                ForEach(entry.tiles.prefix(2), id: \.name) { tile in link(tile) { TileView(tile: tile, large: false) } }
            }
        }
    }

    @ViewBuilder
    private func grid(columns: Int, rows: Int) -> some View {
        if entry.tiles.isEmpty {
            empty
        } else {
            let cells = Array(entry.tiles.prefix(columns * rows))
            VStack(spacing: 8) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(0..<columns, id: \.self) { c in
                            let i = r * columns + c
                            if i < cells.count {
                                link(cells[i]) { TileView(tile: cells[i], large: false) }
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

    /// A tap runs a simple action in the app, or opens the form of the others.
    private func link<Content: View>(_ tile: ActionUsage.Offered, @ViewBuilder content: () -> Content) -> some View {
        Link(destination: WidgetActions.tapURL(tile)) { content() }
            .accessibilityLabel(Text(WidgetActions.spoken(tile)))
    }
}

/// A rounded tile: the icon and the name.
private struct TileView: View {
    let tile: ActionUsage.Offered
    let large: Bool

    private var icon: String { Symbols.safe(tile.icon, fallback: "play.circle") }

    var body: some View {
        Group {
            if large {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: icon).font(.title.weight(.semibold)).foregroundStyle(Palette.text)
                    Spacer(minLength: 4)
                    label(.subheadline)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(Palette.text).frame(minWidth: 24)
                    label(.footnote)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func label(_ font: Font) -> some View {
        Text(tile.label).font(font.weight(.medium)).foregroundStyle(Palette.text)
            .lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
    }
}
