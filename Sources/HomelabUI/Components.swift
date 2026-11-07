import HomelabDesign
import HomelabKit
import LocalAuthentication
import SwiftUI

/// Server text as inline Markdown (bold, code, links). Never HTML, never block elements. Links that aren't
/// http(s) are removed, so a server can't make the app open `tel:` or another app's scheme. Links are iris and
/// underlined (docs/DESIGN.md §3: iris means a link, never colour alone). Text ignores a run's colour on links on
/// some iOS versions: a view showing markdown also sets `.tint(Palette.iris)`.
func markdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                          failurePolicy: .returnPartiallyParsedIfPossible)
    var s = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    for run in s.runs {
        guard let link = run.link else { continue }
        if URLPolicy.webURL(link.absoluteString) == nil {
            s[run.range].link = nil
        } else {
            s[run.range].foregroundColor = Palette.iris
            s[run.range].underlineStyle = Text.LineStyle.single
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

/// "Can't reach … Is Tailscale on?" with a retry. At accessibility text sizes Retry goes under the text: next to
/// it the text got one word per line (CI screenshot, 2026-11-06). VoiceOver: the texts are one element, Retry its
/// own (44 pt), and the message is announced when the banner appears.
struct ErrorBanner: View {
    let error: APIError
    let snapshotAge: Date?
    let retry: () -> Void
    /// "Edit server" for a setup error (token, address, certificate): Retry alone can't fix those.
    var edit: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    private var showsEdit: Bool { edit != nil && !error.isTransient }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    icon
                    texts
                    retryButton
                    if showsEdit { editButton }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        icon
                        texts
                        Spacer(minLength: 0)
                        retryButton
                    }
                    if showsEdit { editButton.padding(.leading, 34) }
                }
            }
        }
        .padding(16)   // a panel like every other (DESIGN.md §2); the gold icon carries the status
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .onAppear { announce(error.message) }
        .onChange(of: error.message) { _, message in announce(message) }
    }

    private var icon: some View {
        Image(systemName: error.isTransient ? "wifi.exclamationmark" : "exclamationmark.lock")
            .font(.title3)
            .foregroundStyle(Palette.gold)
            .accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(error.message).font(.subheadline.weight(.medium))
            if let snapshotAge {
                Text("Showing data from \(Format.age(snapshotAge)).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var editButton: some View {
        Button { edit?() } label: {
            Text("Edit server")
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 16)
                .frame(minWidth: 44, minHeight: 44)
                .background(Palette.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .accessibilityHint(Text("Opens this server's settings"))
    }

    private var retryButton: some View {
        Button(action: retry) {
            Text("Retry")
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 16)
                .frame(minWidth: 44, minHeight: 44)
                .background(Palette.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.press)
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

/// Section header (docs/DESIGN.md §1): a bold sentence-case title, an optional count in the data font, an optional
/// action on the right. Put it in a `VStack(spacing: Space.titleToPanel)` with its panel (8 pt), and sections in a
/// stack with `Space.section` (32 pt) between them (§2). VoiceOver: title and count are one heading; the action is
/// its own button with a 44 pt target (the layout keeps the title's height).
struct SectionTitle: View {
    let text: LocalizedStringKey
    var trailing: String?
    var action: (label: LocalizedStringKey, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text).font(Typo.sectionTitle).foregroundStyle(Palette.text)
                if let trailing {
                    Text(trailing).font(Typo.data(.subheadline)).foregroundStyle(Palette.secondary)
                        .numberMotion(trailing)
                        .accessibilityLabel(Format.spoken(trailing))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(action: action.run) {
                    Text(action.label).font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondary)
                .padding(.vertical, -12)   // the 44 pt target reaches over the 8 pt gap, the title row stays as high
            }
        }
    }
}

/// A plain button that gives way under the finger: it shrinks a little, dims, and springs back. With Reduce Motion
/// it only dims.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PressFeel(pressed: configuration.isPressed, scale: scale))
    }
}

/// How a pressed button gives way (`PressStyle`, `CapsuleButtonStyle`): smaller and dimmer while held, springing
/// back; only dimmer with Reduce Motion.
struct PressFeel: ViewModifier {
    let pressed: Bool
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .opacity(pressed ? 0.75 : 1)
            .motion(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    /// Tiles and panels you tap.
    static var press: PressStyle { PressStyle() }
    /// Big things (Today's headline), which should barely move.
    static var pressLight: PressStyle { PressStyle(scale: 0.985) }
}

/// A panel (docs/DESIGN.md §2): filled, slightly lifted from the black background, no border. Status is never the
/// panel's colour: the item inside shows its own status dot or icon.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    /// A panel. `accent` is accepted for old call sites and ignored (status belongs on the item, not the panel).
    /// Less `padding` for a small one (a card inside a chat bubble).
    func card(accent: Color? = nil, padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// The panel of docs/DESIGN.md §2.
    func panel(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }

    /// A panel whose rows bring their own padding and are split by separators (inset 16).
    func rowsPanel() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The screen background behind scroll views and lists.
    func screenBackground() -> some View {
        scrollContentBackground(.hidden).background(Palette.background.ignoresSafeArea())
    }

    /// A grouped list or form in the app's look: the screen background around it, rows on `Palette.surface`
    /// (instead of the system's blue-grey #F2F2F7 / #1C1C1E). Put it on the list's content (a Group around the
    /// sections), and `screenBackground()` on the list.
    func surfaceRows() -> some View {
        listRowBackground(Palette.surface)
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
