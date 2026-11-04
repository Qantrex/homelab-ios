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
                .foregroundStyle(.orange)
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
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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

/// Section header style used on the overview.
struct SectionTitle: View {
    let text: LocalizedStringKey
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.title3.weight(.semibold))
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded card background that works in light and dark mode.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
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
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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
