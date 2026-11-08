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

/// Every colour the app and the widget use. With Increase Contrast (Settings > Accessibility) every colour has a
/// stronger twin: lighter panels and lines on black, darker type and status colours on white, tertiary = secondary.
public enum Palette {
    /// Screen background: #000000 in dark mode, white in light mode.
    public static let background = dynamic(dark: 0x000000, light: 0xFFFFFF)
    /// Panels on the background: #141414 on black (contrast about 1.2:1, visible on OLED in daylight; research D7).
    public static let surface = dynamic(dark: 0x141414, light: 0xF2F2F2, darkHigh: 0x262626, lightHigh: 0xE8E8E8)
    /// Raised things inside a panel (buttons, tiles that are on).
    public static let raised = dynamic(dark: 0x1F1F1F, light: 0xE6E6E6, darkHigh: 0x333333, lightHigh: 0xD9D9D9)
    /// Hairlines and meter tracks.
    public static let line = dynamic(dark: 0x2A2A2A, light: 0xD8D8D8, darkHigh: 0x5A5A5A, lightHigh: 0x8C8C8C)
    /// Main text and the accent (buttons, selected tab): white on black, black on white.
    public static let text = dynamic(dark: 0xF2F2F2, light: 0x0A0A0A, darkHigh: 0xFFFFFF, lightHigh: 0x000000)
    public static let secondary = dynamic(dark: 0x9A9A9A, light: 0x5C5C5C, darkHigh: 0xB3B3B3, lightHigh: 0x3D3D3D)
    /// Meta text (ages, footers, column headers): 4.5:1 or more on the panel in both modes. The same as secondary
    /// with Increase Contrast.
    public static let tertiary = dynamic(dark: 0x8A8A8A, light: 0x666666, darkHigh: 0xB3B3B3, lightHigh: 0x3D3D3D)
    /// Text on an accent-coloured button.
    public static let onAccent = dynamic(dark: 0x000000, light: 0xFFFFFF)
    public static let accent = text
    /// Track of a switch that is on: a mid grey, so the white knob stays visible and on/off differ clearly (the knob
    /// sits right when on). Owner review 2026-11-08 row 28.
    public static let toggleOn = dynamic(dark: 0x7A7A7A, light: 0x5C5C5C, darkHigh: 0x8F8F8F, lightHigh: 0x3D3D3D)

    /// Rosé Pine Moon (dark); light mode darker than Rosé Pine Dawn, so it is 4.5:1 or more on raised (#E6E6E6).
    public static let love = dynamic(dark: 0xEB6F92, light: 0x9E4A63, darkHigh: 0xF28BA8, lightHigh: 0x8A3A52)
    /// Light gold is dark enough for text: 4.6:1 on raised (#E6E6E6).
    public static let gold = dynamic(dark: 0xF6C177, light: 0x8F5A00, lightHigh: 0x7A4D00)
    public static let iris = dynamic(dark: 0xC4A7E7, light: 0x735C8C, lightHigh: 0x5E4A75)

    /// `darkHigh` / `lightHigh`: the colour with Increase Contrast (`accessibilityContrast == .high`); the normal
    /// one when nil.
    static func dynamic(dark: UInt32, light: UInt32, darkHigh: UInt32? = nil, lightHigh: UInt32? = nil) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            return traits.userInterfaceStyle == .dark ? UIColor(hex: high ? darkHigh ?? dark : dark)
                                                      : UIColor(hex: high ? lightHigh ?? light : light)
        })
        #else
        Color(hex: dark)
        #endif
    }
}

/// Fonts (docs/DESIGN.md §1): one typeface, SF Pro. Values use its fixed-width digits so columns line up; SF Mono is
/// only for code in chat (`code`). Owner's review 2026-11-06: "too many different fonts and mono font".
public enum Typo {
    /// Values: numbers, times, percentages. SF Pro with fixed-width digits, so it reads like the text around it.
    public static func data(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style).weight(weight).monospacedDigit()
    }

    /// Code only: code blocks and inline code in chat. Never values, labels or commands.
    public static func code(_ style: Font.TextStyle) -> Font { .system(style, design: .monospaced) }

    /// Older name of `data`; new code uses `data`.
    public static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font { data(style, weight: weight) }

    // The type scale (docs/DESIGN.md §1): 48 / 28 / 20 / 17 / 15 / 13, each step at least 1.13x. Max five per screen.

    /// 48 heavy at the default text size. Today's headline: the one big thing on the first screen. Scales with
    /// Dynamic Type like `.largeTitle` (so it stays bigger than the fact line at AX sizes): use it through
    /// `.heroFont()`, which reads the environment's text size; this fixed 48 is for places without one.
    public static let hero: Font = hero(size: 48)
    /// The hero at a given (already scaled) size.
    public static func hero(size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .default) }
    /// 28 semibold. The one big number in a card (current value in a chart, next stop of the day line).
    public static let display: Font = .title.weight(.semibold)
    /// `display` for values: fixed-width digits.
    public static let displayData: Font = Font.title.weight(.semibold).monospacedDigit()
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
    /// 15 medium, fixed-width digits. A value in a row's right-hand column.
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

    /// The colour of a number over its limit: gold from the series' warning limit, love from its problem limit
    /// (`HostHistory.Series.level`), else normal text. The sparkline's dot and the detail chart use the same limits.
    public static func valueColor(_ level: ValueLevel, normal: Color = Palette.text) -> Color {
        switch level {
        case .normal: normal
        case .warning: Palette.gold
        case .problem: Palette.love
        }
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(tint).frame(width: max(geo.size.width * value, value > 0 ? 3 : 0))
            }
        }
        .frame(height: 4)
        .motion(.easeOut(duration: 0.6), value: value)
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
                    .font(.system(size: size * 0.32, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, width)
            }
        }
        .frame(width: size, height: size)
        .motion(.easeOut(duration: 0.6), value: value)
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

/// Every switch in the app: the system switch (same knob, same VoiceOver value) with a grey "on" track instead of the
/// white app tint, which hid the white knob. Set once at the root with `.toggleStyle(HomelabToggleStyle())`.
public struct HomelabToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).tint(Palette.toggleOn)
    }
}
