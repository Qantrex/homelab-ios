import HomelabDesign
import HomelabKit
import SwiftUI
import UIKit

/// The app: the first run until a server exists (and until that run ends), then the tabs. A lock screen covers everything when Face ID is on.
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
            } else if model.showsFirstRun {
                // No server yet, or a first run that goes on after its first save (FirstRun): never the owner.
                WelcomeView(model: model)
            } else {
                tabs
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
        .onChange(of: model.shownTabs) { _, _ in model.validateTab() }
        .task { await model.drainOutbox() }
        .tint(Palette.accent)
        .toggleStyle(HomelabToggleStyle())   // grey "on" track for every switch (review 2026-11-08 row 28)
        .labeledContentStyle(.adaptive)
        // Hyperdetail only (nil elsewhere): the views below add every field and a remark to what they draw.
        .environment(\.hyper, model.hyper)
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
            // The owner's order, without the tabs they hid (Settings -> Advanced -> Tab bar); the feature checks live in
            // `AppModel.availableTabs`: proposals to approve or actions the app starts itself for Actions, and so on.
            ForEach(model.shownTabs, id: \.self) { tab in
                Tab(LocalizedStringKey(tab.title), systemImage: tab.symbol, value: tab) {
                    content(of: tab)
                }
                .badge(tab == .actions ? model.pendingCount : 0)
            }
        }
        .alert(hiddenTitle, isPresented: Binding(get: { model.hiddenTabNotice != nil },
                                                 set: { if !$0 { model.dismissHiddenTabNotice() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You hid it under Settings → \(AdvancedTitle.text(model.settings.voice)) → Tab bar. Show it there to open it.")
        }
        // A new problem on a refresh is felt on every tab (Motion).
        .newProblemFeedback(model)
    }

    private var hiddenTitle: String {
        String(localized: "\(model.hiddenTabNotice?.title ?? "") is hidden")
    }

    @ViewBuilder
    private func content(of tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView(model: model)
        case .actions: ActionsView(model: model)
        case .chat: ChatView(model: model)
        case .lab: LabView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

/// The first run (`FirstRun`, docs/plans/MODULAR.md M2.3). The welcome: "Add Home Assistant", "Add a Homelab
/// server", "Try the demo" (one tap). Once a server is saved: Found and "Start with" (`FoundView`). The server editor
/// and the tile picker are sheets over it. Shown only while `AppModel.showsFirstRun`, never for someone with servers.
struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.firstRun?.showsFound == true {
                    FoundView(model: model)
                } else {
                    welcome
                }
            }
            // The editor for the kind the run adds. Save moves the run on to Found; Cancel goes back (FirstRun).
            .sheet(isPresented: Binding(get: { model.firstRun?.adding != nil },
                                        set: { if !$0 { model.firstRunEditorClosed() } })) {
                ServerEditor(model: model, server: nil, kind: model.firstRun?.adding) { model.firstRunSaved($0) }
            }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "server.rack")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Your homelab, in your pocket").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("The lights and scenes you use most, your machines and their problems, at a glance. Everything stays on your network.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    point("house", "Home Assistant: your lights and scenes as tiles")
                    point("checkmark.shield", "Status of every machine, problems first")
                    point("hand.thumbsup", "Approve what your server proposes (if it offers it)")
                    point("lock.shield", "No account, no cloud, no tracking")
                }
                .padding(.horizontal)
                VStack(spacing: 12) {
                    Button {
                        model.beginFirstRun(adding: .homeAssistant)
                    } label: {
                        Text("Add Home Assistant").frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        model.beginFirstRun(adding: .companion)
                    } label: {
                        Text("Add a Homelab server").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
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
                    Text(verbatim: FirstRun.vpnNote)
                    Text("A Homelab server is anything that speaks the Homelab API, like the small Homelab Bridge for any Linux box:")
                    Link("Set up a Homelab Bridge", destination: URL(string: "https://github.com/Qantrex/homelab-ios/blob/main/docs/GETTING-STARTED.md#b-homelab-bridge")!)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
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
