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
    /// Panels on the background.
    public static let surface = dynamic(dark: 0x0B0B0B, light: 0xF6F6F6)
    /// Raised things inside a panel (buttons, tiles that are on).
    public static let raised = dynamic(dark: 0x1A1A1A, light: 0xE9E9E9)
    /// Hairlines and meter tracks.
    public static let line = dynamic(dark: 0x262626, light: 0xDDDDDD)
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

    /// Today's headline: the one big thing on the first screen. Scales with Dynamic Type from 48 pt.
    public static let hero: Font = .system(size: 48, weight: .heavy, design: .default)

    /// Section titles: sentence case, bold, no tracking.
    public static let sectionTitle: Font = .title3.bold()
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

/// A thin bar for 0…1 values (disk, progress). Colour turns orange/red near full when `warns` is set.
public struct Meter: View {
    let value: Double
    let tint: Color
    let warns: Bool

    public init(_ value: Double, tint: Color = Palette.text, warns: Bool = false) {
        self.value = min(max(value, 0), 1)
        self.tint = tint
        self.warns = warns
    }

    var color: Color {
        guard warns else { return tint }
        return value >= 0.9 ? Palette.love : value >= 0.75 ? Palette.gold : tint
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(color).frame(width: max(geo.size.width * value, value > 0 ? 3 : 0))
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
