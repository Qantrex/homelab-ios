import HomelabKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Colours, icons and small building blocks shared by the app and the widget. No UIKit, so the widget can use it.

public extension OverallStatus {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .unknown: .gray
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
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .asleep: .indigo
        case .unknown: .gray
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
        case .gray: .gray
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .teal: .teal
        case .yellow: .yellow
        case .pink: .pink
        }
    }
}

public extension Problem.Severity {
    var color: Color { self == .warning ? .orange : .red }
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
        Label(status.title, systemImage: status.symbol)
            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(status.color.opacity(0.18), in: Capsule())
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

    public init(_ value: Double, tint: Color = .accentColor, warns: Bool = false) {
        self.value = min(max(value, 0), 1)
        self.tint = tint
        self.warns = warns
    }

    var color: Color {
        guard warns else { return tint }
        return value >= 0.9 ? .red : value >= 0.75 ? .orange : tint
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: max(geo.size.width * value, value > 0 ? 3 : 0))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// Tag-like text: "watchdog", "3 updates".
public struct Chip: View {
    let text: String
    let color: Color
    let symbol: String?

    public init(_ text: String, color: Color = .secondary, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}
