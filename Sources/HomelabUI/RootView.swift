import HomelabDesign
import HomelabKit
import SwiftUI
import UIKit

/// The app: onboarding until a server exists, then the tabs. A lock screen covers everything when Face ID is on.
public struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            // While locked, nothing behind the lock exists: no tab, sheet or dialog can be reached (or read by VoiceOver).
            if model.locked {
                Palette.background.ignoresSafeArea()
            } else if model.hasServers {
                tabs
            } else {
                WelcomeView(model: model)
            }
            if model.locked {
                LockView {
                    if await Biometrics.authenticate(reason: String(localized: "Unlock your homelab")) {
                        model.locked = false
                    }
                }
                .transition(.opacity)
            } else if model.settings.faceIDLock && scenePhase != .active {
                // App switcher snapshot and Control Center: cover the content without asking for Face ID yet.
                PrivacyCover()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if model.settings.faceIDLock {
                    Self.dismissPresentedScreens()
                    model.lock()   // also forgets the open form sheets: none is open after the lock
                }
            case .active:
                model.reloadSettings()
                model.validateTab()
                Task { await model.drainOutbox() }   // what the share extension or a scan couldn't send
            default:
                break
            }
        }
        .onChange(of: model.availableTabs) { _, _ in model.validateTab() }
        .task { await model.drainOutbox() }
        .tint(Palette.accent)
        .labeledContentStyle(.adaptive)
    }

    /// Sheets, alerts and confirmation dialogs live above the root view; close them all before locking.
    static func dismissPresentedScreens() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.dismiss(animated: false)
            }
        }
    }

    private var tabs: some View {
        // The tab bar is the user's own pick: it ends a link's request that still waits (AppModel.pick). Only this
        // setter, not every change of `tab`: validateTab and links set it too.
        TabView(selection: Binding(get: { model.tab }, set: { model.pick($0) })) {
            Tab("Today", systemImage: "sun.horizon", value: AppTab.today) {
                TodayView(model: model)
            }
            // Proposals to approve, or actions the app starts itself (like AppModel.availableTabs).
            if model.selectedStatus.features.contains(.actions) || model.selectedStatus.features.contains(.runActions)
                || model.selectedStatus.features.contains(.documents) || model.selectedStatus.features.contains(.search) {
                Tab("Actions", systemImage: "checkmark.shield", value: AppTab.actions) {
                    ActionsView(model: model)
                }
                .badge(model.pendingCount)
            }
            if model.selectedStatus.features.contains(.chat) {
                Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: AppTab.chat) {
                    ChatView(model: model)
                }
            }
            if model.selected != nil {
                Tab("Lab", systemImage: "server.rack", value: AppTab.lab) {
                    LabView(model: model)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(model: model)
            }
        }
        // A new problem on a refresh is felt on every tab (Motion).
        .newProblemFeedback(model)
    }
}

/// First start: add a server, or look around in demo mode.
struct WelcomeView: View {
    let model: AppModel
    @State private var adding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.top, 40)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Your homelab, in your pocket").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        Text("See your hosts and problems at a glance. If your server offers it, approve what it proposes and chat with it. Home Assistant devices work too. Everything stays on your network.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        point("checkmark.shield", "Status of every host, problems first")
                        point("hand.thumbsup", "Approve or deny actions your server asks about (if offered)")
                        point("bubble.left.and.bubble.right", "Chat with your homelab agent (if offered)")
                        point("lock.shield", "No account, no cloud, no tracking")
                    }
                    .padding(.horizontal)
                    VStack(spacing: 12) {
                        Button {
                            adding = true
                        } label: {
                            Text("Add a server").frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button {
                            model.setDemo(true)
                        } label: {
                            Text("Try the demo").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    VStack(spacing: 4) {
                        Text("Works with any server that speaks the Homelab API, and with Home Assistant. A small reference server for any Linux box is in the project:")
                        Link("github.com/Qantrex/homelab-ios", destination: URL(string: "https://github.com/Qantrex/homelab-ios/blob/main/docs/SERVER-SETUP.md")!)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $adding) {
                ServerEditor(model: model, server: nil)
            }
        }
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 28)
        }
    }
}
