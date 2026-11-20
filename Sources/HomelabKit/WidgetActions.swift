import Foundation

/// The Actions widget (feature `widget-actions`): which Start actions it shows and where a tap goes. Pure logic,
/// tested on Linux; the widget only draws it. The widget is static (no App Intents: xtool writes no
/// `Metadata.appintents`), so a tap is only a link into the app; the app does the rest.
///
/// Rules:
/// - The widget never reads the Keychain or the network: the names come from the cache the app keeps
///   (`action-usage.json`) and the order from Settings → Advanced → Start tiles (hidden ones left out).
/// - A tap is `homelab://actions/<name>`. For a simple action (no fields, no argument, not destructive) the link adds
///   `run=1` and the run key from the cache (`ActionUsage.runKey`, a secret only the app and the widget can read); the
///   app then runs it at once, but only when the key matches and after checking the server's own list
///   (`AppModel.takeOpenActionForm`). Without a key (an older cache, or a timeline drawn before the app made one) the
///   link has no `run`. Every other action opens its form, which asks before anything runs.
public enum WidgetActions {
    /// Actions per widget family: small 2, medium 4, large 8, lock screen 1.
    public enum Size: Sendable, CaseIterable {
        case small, medium, large, circular
        public var capacity: Int {
            switch self {
            case .small: 2
            case .medium: 4
            case .large: 8
            case .circular: 1
            }
        }
    }

    /// The Start actions the app cached for `server`, the visible ones in the owner's order (hidden ones left out).
    public static func visible(_ usage: ActionUsage, server: UUID?, order: ItemOrder?) -> [ActionUsage.Offered] {
        guard let server else { return [] }
        let offered = usage.offered[ActionUsage.key(server)] ?? []
        // The run key travels only in memory, from the cache to the tap link (`ActionUsage.Offered.runKey`).
        return (order ?? .standard).arrange(offered, id: \.name).map { var o = $0; o.runKey = usage.runKey; return o }
    }

    /// The tiles to draw: the first visible Start tiles, as many as the size holds.
    public static func tiles(usage: ActionUsage, server: UUID?, order: ItemOrder?, size: Size) -> [ActionUsage.Offered] {
        Array(visible(usage, server: server, order: order).prefix(size.capacity))
    }

    /// A simple action by the cache: it says so (an older cache, which doesn't, counts as not simple).
    public static func isSimple(_ action: ActionUsage.Offered) -> Bool {
        action.destructive == false && action.needsInput == false
    }

    /// Where a tap goes: `homelab://actions/<name>`, with `run=1` and the run key for a simple action when the tile
    /// has the key; the Actions tab when the name is not one the server could have sent.
    public static func tapURL(_ action: ActionUsage.Offered) -> URL {
        let key = action.runKey ?? ""
        let run = isSimple(action) && !key.isEmpty
        // Only a valid action name becomes a deep link (newer Foundation accepts spaces in URL(string:)).
        return (ActionSpec.isValidName(action.name) ? ActionLink(name: action.name, run: run, runKey: run ? key : "").url : nil)
            ?? URL(string: "homelab://actions")!
    }

    /// "Wake Minecraft, runs it" / "Add a to-do, opens the form".
    public static func spoken(_ action: ActionUsage.Offered) -> String {
        "\(action.label), \(isSimple(action) ? "runs it" : "opens the form")"
    }
}
