import HomelabDesign
import HomelabKit
import LocalAuthentication
import SwiftUI

/// Server text as inline Markdown (bold, code, links). Never HTML, never block elements. Links that aren't
/// http(s) are removed, so a server can't make the app open `tel:` or another app's scheme.
func markdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                          failurePolicy: .returnPartiallyParsedIfPossible)
    var s = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    for run in s.runs {
        if let link = run.link, URLPolicy.webURL(link.absoluteString) == nil {
            s[run.range].link = nil
        }
    }
    return s
}

/// Identity of a polling loop: a new server or a change between foreground and background restarts it.
struct PollKey: Hashable {
    var server: String?   // ServerConfig.target: a new address restarts the loop with fresh data
    var active: Bool
    var kick = 0          // bumped to wake a sleeping loop at once (after sending a chat message)
}

/// "Can't reach … Is Tailscale on?" with a retry.
struct ErrorBanner: View {
    let error: APIError
    let snapshotAge: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error.isTransient ? "wifi.exclamationmark" : "exclamationmark.lock")
                .font(.title3)
                .foregroundStyle(Palette.gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.message).font(.subheadline.weight(.medium))
                if let snapshotAge {
                    Text("Showing data from \(Format.age(snapshotAge)).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.gold.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Shown when there is nothing to show yet.
struct Placeholder: View {
    let title: LocalizedStringKey
    let symbol: String
    let message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

/// Section header: small mono capitals, like a terminal dashboard. An optional action on the right.
struct SectionTitle: View {
    let text: LocalizedStringKey
    var trailing: String?
    var action: (label: LocalizedStringKey, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).textCase(.uppercase).font(Typo.mono(.caption, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Palette.secondary)
            Spacer()
            if let trailing { Text(trailing.uppercased()).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary) }
            if let action {
                Button(action: action.run) { Text(action.label).font(Typo.mono(.caption2, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A plain button that gives way under the finger: it shrinks a little, dims, and springs back. With Reduce Motion
/// it only dims.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        Pressable(label: configuration.label, pressed: configuration.isPressed, scale: scale)
    }

    private struct Pressable: View {
        let label: Configuration.Label
        let pressed: Bool
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label
                .scaleEffect(pressed && !reduceMotion ? scale : 1)
                .opacity(pressed ? 0.75 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: pressed)
        }
    }
}

extension ButtonStyle where Self == PressStyle {
    /// Tiles and panels you tap.
    static var press: PressStyle { PressStyle() }
    /// Big things (Today's headline), which should barely move.
    static var pressLight: PressStyle { PressStyle(scale: 0.985) }
}

/// A panel: slightly lifted from the black background, with a hairline border.
struct CardBackground: ViewModifier {
    var accent: Color?
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent?.opacity(0.55) ?? Palette.line, lineWidth: 1))
    }
}

extension View {
    /// A panel; `accent` colours its border (a problem panel gets a love border). Less `padding` for a small one
    /// (a card inside a chat bubble).
    func card(accent: Color? = nil, padding: CGFloat = 14) -> some View {
        modifier(CardBackground(accent: accent, padding: padding))
    }

    /// The screen background behind scroll views and lists.
    func screenBackground() -> some View {
        scrollContentBackground(.hidden).background(Palette.background.ignoresSafeArea())
    }
}

/// Covers the app while it isn't active (app switcher), when the lock is on.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// Face ID / passcode gate.
struct LockView: View {
    let unlock: () async -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Homelab is locked").font(.title3.weight(.semibold))
            Button {
                Task { await unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(minWidth: 160)
                    .foregroundStyle(Palette.onAccent)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .task { await unlock() }
    }
}

enum Biometrics {
    /// Face ID, Touch ID or the passcode. True when the user got through.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true   // no passcode set at all: a lock would only lock the owner out
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
