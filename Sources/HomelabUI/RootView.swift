import HomelabDesign
import HomelabKit
import SwiftUI

/// The app: onboarding until a server exists, then the tabs. A lock screen covers everything when Face ID is on.
public struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            if model.hasServers {
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
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if model.settings.faceIDLock { model.locked = true }
            case .active:
                model.reloadSettings()
            default:
                break
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $model.tab) {
            Tab("Overview", systemImage: "square.grid.2x2", value: AppTab.overview) {
                OverviewView(model: model)
            }
            if model.selectedStatus.features.contains(.actions) {
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
            if model.homeAssistant != nil {
                Tab("Home", systemImage: "house", value: AppTab.home) {
                    HomeView(model: model)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(model: model)
            }
        }
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
                        Text("See your hosts, approve what your homelab proposes, chat with your agent and switch Home Assistant devices. Everything stays on your network.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        point("checkmark.shield", "Status of every host, problems first")
                        point("hand.thumbsup", "Approve or deny proposed actions")
                        point("bubble.left.and.bubble.right", "Chat with your homelab agent")
                        point("lock.shield", "No account, no cloud, no tracking")
                    }
                    .padding(.horizontal)
                    VStack(spacing: 12) {
                        Button {
                            adding = true
                        } label: {
                            Text("Add a server").frame(maxWidth: .infinity)
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
                    Text("Works with any server that speaks the Homelab API (a reference server is in the project), and with Home Assistant.")
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
