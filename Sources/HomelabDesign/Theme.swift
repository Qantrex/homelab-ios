import HomelabKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Colours, icons and small building blocks shared by the app and the widget.
//
// The look (owner, 2026-11-05; rules in docs/DESIGN.md since 2026-11-06): true black, monochrome white/grey type,
// numbers in a mono font, filled panels without borders. Colour only for status, from Rosé Pine Moon: love = problem, gold = warning, iris = links. A
// sleeping machine is plain grey (tapping it doesn't wake it). No blue anywhere. Light mode is the same in white/black. Change colours here only.

/// Every colour the app and the widget use.
public enum Palette {
    /// Screen background: #000000 in dark mode, white in light mode.
    public static let background = dynamic(dark: 0x000000, light: 0xFFFFFF)
    /// Panels on the background: #141414 on black (contrast about 1.2:1, visible on OLED in daylight; research D7).
    public static let surface = dynamic(dark: 0x141414, light: 0xF2F2F2)
    /// Raised things inside a panel (buttons, tiles that are on).
    public static let raised = dynamic(dark: 0x1F1F1F, light: 0xE6E6E6)
    /// Hairlines and meter tracks.
    public static let line = dynamic(dark: 0x2A2A2A, light: 0xD8D8D8)
    /// Main text and the accent (buttons, selected tab): white on black, black on white.
    public static let text = dynamic(dark: 0xF2F2F2, light: 0x0A0A0A)
    public static let secondary = dynamic(dark: 0x9A9A9A, light: 0x5C5C5C)
    public static let tertiary = dynamic(dark: 0x5E5E5E, light: 0x9A9A9A)
    /// Text on an accent-coloured button.
    public static let onAccent = dynamic(dark: 0x000000, light: 0xFFFFFF)
    public static let accent = text

    /// Rosé Pine Moon (dark) and Rosé Pine Dawn (light, readable on white).
    public static let love = dynamic(dark: 0xEB6F92, light: 0xB4637A)
    public static let gold = dynamic(dark: 0xF6C177, light: 0xEA9D34)
    public static let iris = dynamic(dark: 0xC4A7E7, light: 0x907AA9)

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        Color(hex: dark)
        #endif
    }
}

/// Fonts (docs/DESIGN.md §1): system text styles for words, the monospaced design only for values.
public enum Typo {
    /// Values only: numbers, times, ids, arguments. Never labels or titles.
    public static func data(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }

    /// Older name of `data`; new code uses `data`.
    public static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font { data(style, weight: weight) }

    // The type scale (docs/DESIGN.md §1): 48 / 28 / 20 / 17 / 15 / 13, each step at least 1.13x. Max five per screen.

    /// 48 heavy. Today's headline: the one big thing on the first screen. Scales with Dynamic Type.
    public static let hero: Font = .system(size: 48, weight: .heavy, design: .default)
    /// 28 semibold. The one big number in a card (current value in a chart, next stop of the day line).
    public static let display: Font = .title.weight(.semibold)
    /// `display` for values: SF Mono with fixed-width digits.
    public static let displayData: Font = .system(.title, design: .monospaced).weight(.semibold)
    /// 20 bold. Section titles, sentence case, no tracking.
    public static let sectionTitle: Font = .title3.bold()
    /// 17 semibold. The name of a row or card.
    public static let headline: Font = .headline
    /// 17 regular. Text people read.
    public static let body: Font = .body
    /// 15 regular, in `Palette.secondary`. What explains a row.
    public static let secondary: Font = .subheadline
    /// 13 regular, in `Palette.tertiary`. Ages, "checked 2 min ago", footers.
    public static let meta: Font = .footnote
    /// 15 medium mono. A value in a row's right-hand column.
    public static let rowValue: Font = data(.subheadline, weight: .medium)
}

/// Spacing tokens (docs/DESIGN.md §2). Inside a group is clearly smaller than between groups.
public enum Space {
    /// Section title to its panel.
    public static let titleToPanel: CGFloat = 8
    /// Between two sections.
    public static let section: CGFloat = 32
    /// Between rows that are separate things (not in one panel).
    public static let row: CGFloat = 12
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

public extension OverallStatus {
    var color: Color {
        switch self {
        case .ok: Palette.text
        case .warning: Palette.gold
        case .problem: Palette.love
        case .unknown: Palette.tertiary
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .ok: String(localized: "All good")
        case .warning: String(localized: "Warning")
        case .problem: String(localized: "Problem")
        case .unknown: String(localized: "Unknown")
        }
    }
}

public extension HostHealth {
    var color: Color {
        switch self {
        case .ok: Palette.text
        case .warning: Palette.gold
        case .problem: Palette.love
        case .asleep: Palette.secondary
        case .unknown: Palette.tertiary
        }
    }

    var label: String {
        switch self {
        case .ok: String(localized: "OK")
        case .warning: String(localized: "Warning")
        case .problem: String(localized: "Problem")
        case .asleep: String(localized: "Asleep")
        case .unknown: String(localized: "Not checked")
        }
    }
}

public extension Tint {
    var color: Color {
        switch self {
        // Server tints map onto the palette: warm ones become status colours, everything else stays monochrome.
        case .gray, .blue, .green, .teal: Palette.secondary
        case .orange, .yellow: Palette.gold
        case .red: Palette.love
        case .purple, .pink: Palette.iris
        }
    }
}

public extension Problem.Severity {
    var color: Color { self == .warning ? Palette.gold : Palette.love }
    var symbol: String { self == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill" }
}

public enum Symbols {
    /// An icon for a host kind (free text from the server).
    public static func host(kind: String?) -> String {
        switch kind?.lowercased() {
        case "raspberry-pi", "pi", "sbc": "cpu"
        case "laptop": "laptopcomputer"
        case "desktop", "pc", "gaming": "desktopcomputer"
        case "nas", "storage": "externaldrive.connected.to.line.below"
        case "vm", "container": "shippingbox"
        case "router", "network": "wifi.router"
        default: "server.rack"
        }
    }

    /// The server's SF Symbol name, or a fallback when it doesn't exist on this iOS.
    public static func safe(_ name: String?, fallback: String = "square.grid.2x2") -> String {
        guard let name, !name.isEmpty else { return fallback }
        #if canImport(UIKit)
        return UIImageExists.check(name) ? name : fallback
        #else
        return name
        #endif
    }
}

#if canImport(UIKit)
enum UIImageExists {
    static func check(_ name: String) -> Bool { UIImage(systemName: name) != nil }
}
#endif

/// The coloured pill with the overall status.
public struct StatusPill: View {
    let status: OverallStatus
    let compact: Bool

    public init(_ status: OverallStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
            Text(status.title.uppercased())
        }
            .font(Typo.mono(compact ? .caption2 : .caption, weight: .semibold))
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 3 : 4)
            .overlay(Capsule().strokeBorder(status.color.opacity(0.6), lineWidth: 1))
            .foregroundStyle(status.color)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Status: \(status.title)"))
    }
}

/// A thin grey bar for 0…1 values (disk, progress). Colour belongs to numbers, not bars (docs/DESIGN.md §3): a bar
/// stays grey and the value next to it takes `Meter.valueColor`. `warns` and `tint` are accepted for old call sites.
public struct Meter: View {
    let value: Double
    let tint: Color

    public init(_ value: Double, tint: Color = Palette.secondary, warns: Bool = false) {
        self.value = min(max(value, 0), 1)
        self.tint = tint
    }

    /// The colour of the number that goes with a share of a limit: gold from 75 %, love from 90 %, else normal text.
    public static func valueColor(_ share: Double?, normal: Color = Palette.text) -> Color {
        guard let share else { return normal }
        return share >= 0.9 ? Palette.love : share >= 0.75 ? Palette.gold : normal
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(tint).frame(width: max(geo.size.width * value, value > 0 ? 3 : 0))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.6), value: value)
        .accessibilityHidden(true)
    }
}

/// A ring for 0…1 progress (a download, an episode), with the percent inside; a check mark when done.
public struct ProgressRing: View {
    let value: Double
    let tint: Color
    let size: CGFloat

    public init(_ value: Double, tint: Color = Palette.text, size: CGFloat = 34) {
        self.value = value.isFinite ? min(max(value, 0), 1) : 0
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        let width = max(size * 0.09, 2.5)
        let percent = Format.ringPercent(value)
        ZStack {
            Circle().stroke(Palette.line, lineWidth: width)
            Circle()
                .trim(from: 0, to: value)
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if percent >= 100 {
                Image(systemName: "checkmark").font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(tint)
            } else {
                Text("\(percent)")
                    .font(.system(size: size * 0.32, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, width)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: value)
        .accessibilityHidden(true)
    }
}

/// Tag-like text: "watchdog", "3 updates".
public struct Chip: View {
    let text: String
    let color: Color
    let symbol: String?

    public init(_ text: String, color: Color = Palette.secondary, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(Typo.mono(.caption2, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
        .foregroundStyle(color)
    }
}
