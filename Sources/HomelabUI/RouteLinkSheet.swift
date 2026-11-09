import HomelabDesign
import HomelabKit
import SwiftUI

/// The confirmation for a scanned public-route link (`homelab://public-route#v1.…`): nothing is saved before "Add".
/// The keys are never shown; the sheet holds the parsed link in memory only.
struct RouteLinkSheet: View {
    let model: AppModel
    let request: PublicRouteLinkRequest
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: UUID?
    @State private var working = false
    @State private var result: Result<String, APIError>?
    @State private var saveError: String?
    @State private var added = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    switch request.content {
                    case .problem(let text):
                        Section { Label(text, systemImage: "xmark.circle.fill").foregroundStyle(Palette.love) }
                    case .link(let link):
                        linkBody(link)
                    }
                }
                .surfaceRows()
            }
            .screenBackground()
            .navigationTitle("Public route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(added || isProblem ? "Close" : "Cancel") { finish() }
                }
            }
        }
        .interactiveDismissDisabled(working)
        .onDisappear { model.closeRouteLink() }
    }

    private var isProblem: Bool { if case .problem = request.content { true } else { false } }

    private func finish() {
        model.closeRouteLink()
        dismiss()
    }

    @ViewBuilder
    private func linkBody(_ link: PublicRouteLink) -> some View {
        let target = link.target(in: model.servers.servers)
        switch target {
        case .none:
            Section { Text("There is no Homelab server in the app yet. Add the server first, then scan the code again.") }
        case .server(let s):
            confirm(link, server: s, note: nil)
        case .choose(let list, let notFound):
            if let s = list.first(where: { $0.id == chosen }) {
                confirm(link, server: s, note: nil)
            } else {
                Section {
                    ForEach(list) { s in
                        Button { chosen = s.id } label: {
                            HStack { Text(s.name); Spacer(); Text(s.host).foregroundStyle(Palette.secondary).font(.footnote) }
                        }
                    }
                } header: {
                    Text("Which server?")
                } footer: {
                    SettingsFooter(notFound
                        ? "The server named in the code was not found in the app. Pick the one this route belongs to."
                        : "Pick the server this route belongs to.")
                }
            }
        }
    }

    @ViewBuilder
    private func confirm(_ link: PublicRouteLink, server: ServerConfig, note: String?) -> some View {
        Section {
            Text("Add public route to \(server.name)?").font(.headline)
            LabeledContent("Public address", value: link.publicHost)
            LabeledContent("Keys", value: String(localized: "3 keys (hidden)"))
            if server.publicURL != nil && !added {
                Label("\(server.name) already has a public route. It will be replaced.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Palette.gold)
            }
        } footer: {
            SettingsFooter("Only add it if you scanned the code yourself from your own setup script. The keys are stored in the iOS Keychain on this phone only.")
        }
        if !added {
            Section {
                Button("Add") { Task { await add(link, to: server) } }
                    .disabled(working)
                Button("Cancel", role: .cancel) { finish() }
                    .foregroundStyle(Palette.secondary)
            }
        }
        if working { Section { HStack { Text("Testing the public route…"); Spacer(); ProgressView() } } }
        if let saveError { Section { Label(saveError, systemImage: "xmark.circle.fill").foregroundStyle(Palette.love) } }
        if let result {
            Section {
                switch result {
                case .success(let t): Label(t, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.text)
                case .failure(let e): Label(e.message, systemImage: "xmark.circle.fill").foregroundStyle(Palette.love)
                }
            } footer: {
                if case .failure = result { SettingsFooter("The route is saved. Check the keys and the Cloudflare Access policy, or scan a new code.") }
            }
        }
    }

    private func add(_ link: PublicRouteLink, to server: ServerConfig) async {
        working = true
        saveError = nil
        defer { working = false }
        do {
            try model.applyRouteLink(link, to: server)
        } catch {
            saveError = error.localizedDescription
            return
        }
        added = true
        let r = await model.testRouteLink(link)
        result = r
        switch r {
        case .success(let t): AccessibilityNotification.Announcement(t).post()
        case .failure(let e): AccessibilityNotification.Announcement(e.message).post()
        }
    }
}
