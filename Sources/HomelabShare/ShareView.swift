import HomelabDesign
import HomelabKit
import SwiftUI

/// The extension's state: what it got, where it goes, and how the send ended.
@MainActor @Observable
final class ShareModel {
    enum Phase {
        case loading
        case ready(LoadedShare)
        case refused(String)
        case sending(String)
        case done(ShareOutcome)
    }

    var phase = Phase.loading
    var title = ""
    /// One id per shared item: a retry (or the outbox later) is the same item for the server, never a second one.
    private let itemID = UUID().uuidString.lowercased()
    private(set) var server: ServerConfig?
    private var features: Set<ServerInfo.Feature>?
    private let storage = Storage.shared()

    init() {
        // The app's selected Companion server, from the App Group (the extension has no account of its own).
        server = storage.read(ServerList.self, ServerList.fileName)?.selectedServer
        if let server { features = storage.read(Snapshot.self, Snapshot.fileName(server.id))?.info?.features }
    }

    func load(_ items: [NSExtensionItem]) async {
        guard server != nil else {
            phase = .refused("Open Homelab and add a server first.")
            return
        }
        switch await ShareLoader.load(SharedItems(items: items)) {
        case .success(let share):
            if let features, !features.contains(ShareRouter.destination(for: share.item).feature) {
                let what = ShareRouter.destination(for: share.item) == .paperless ? "documents" : "shared links"
                phase = .refused("\(server?.name ?? "The server") doesn't take \(what).")
                return
            }
            title = share.item.title ?? ""
            phase = .ready(share)
        case .failure(let refusal):
            phase = .refused(refusal.message)
        }
    }

    func send() async {
        guard case .ready(var share) = phase, let server else { return }
        if share.editableTitle, case .pdf(let data, _) = share.item {
            share.item = .pdf(data, title: ShareRouter.cleanTitle(title, max: ShareLimits.maxPDFTitle))
        }
        phase = .sending(Self.sendingText(share))
        // Identity servers (Tailscale) are sent to directly. A token server can't be: the Keychain is not shared with
        // the extension, so its items wait in the outbox and the app sends them.
        let api: (any CompanionAPI)? = switch (server.kind, server.auth) {
        case (.demo, _): DemoBackend(delay: .zero)
        case (_, .identity): CompanionClient(baseURL: server.baseURL, token: nil)
        default: nil
        }
        let outcome = await ShareSender.send(share.item, id: itemID, server: server, api: api, features: features,
                                             outbox: Outbox(directory: storage.url("outbox")))
        phase = .done(outcome)
    }

    static func sendingText(_ share: LoadedShare) -> String {
        if case .pdf(let data, _) = share.item { return "Sending \(ShareLoader.size(data.count))…" }
        return "Sending…"
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.phase {
                    case .loading:
                        HStack(spacing: 10) { ProgressView(); Text("Reading what you shared…").foregroundStyle(Palette.secondary) }
                    case .refused(let text):
                        result(symbol: "xmark.circle", color: Palette.love, title: "Can't send this", text: text)
                    case .ready(let share):
                        ready(share)
                    case .sending(let text):
                        HStack(spacing: 10) { ProgressView(); Text(text).font(Typo.mono(.subheadline)) }
                    case .done(let outcome):
                        finished(outcome)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.background)
            .navigationTitle("Send to Homelab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = model.phase {} else { Button("Cancel", action: cancel) }
                }
            }
        }
        .tint(Palette.accent)
    }

    @ViewBuilder private func ready(_ share: LoadedShare) -> some View {
        let destination = ShareRouter.destination(for: share.item)
        VStack(alignment: .leading, spacing: 6) {
            Label(destination.label, systemImage: symbol(destination)).font(.headline)
            Text(share.detail).font(Typo.mono(.subheadline)).foregroundStyle(Palette.secondary).lineLimit(2)
            if case .willhaben(let ad) = destination {
                Text("AD \(ad)").font(Typo.mono(.caption)).foregroundStyle(Palette.tertiary)
            }
            Text("To \(model.server?.name ?? "your server")").font(.subheadline).foregroundStyle(Palette.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        if share.editableTitle {
            TextField("Title", text: $model.title)
                .textFieldStyle(.roundedBorder)
        }
        Button {
            Task { await model.send() }
        } label: {
            Text("Send").frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ViewBuilder private func finished(_ outcome: ShareOutcome) -> some View {
        switch outcome {
        case .sent(let text): result(symbol: "checkmark.circle", color: Palette.text, title: "Sent", text: text)
        case .queued: result(symbol: "tray.and.arrow.up", color: Palette.gold, title: "Saved", text: ShareOutcome.queuedText)
        case .failed(let text): result(symbol: "xmark.circle", color: Palette.love, title: "Not sent", text: text)
        }
        Button(action: done) {
            Text("Done").frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func result(symbol: String, color: Color, title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(title).font(.headline) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            Text(text).font(.subheadline).foregroundStyle(Palette.secondary)
            if case .refused = model.phase {
                Button("Close", action: cancel).buttonStyle(.bordered).padding(.top, 6)
            }
        }
    }

    private func symbol(_ d: ShareDestination) -> String {
        switch d {
        case .willhaben: "tag"
        case .readLater: "text.badge.plus"
        case .paperless: "doc.text"
        }
    }
}
