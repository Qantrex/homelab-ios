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

/// The share sheet (docs/DESIGN.md): what it got, where it goes, one filled Send button; the result as a status
/// icon with words. One column, 16 pt margins, one panel with separators.
struct ShareView: View {
    @Bindable var model: ShareModel
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch model.phase {
                    case .loading:
                        progress(String(localized: "Reading what you shared…"))
                    case .refused(let text):
                        result(symbol: "xmark.circle.fill", color: Palette.love, title: "Can't send this", text: text)
                    case .ready(let share):
                        ready(share)
                    case .sending(let text):
                        progress(text)
                    case .done(let outcome):
                        finished(outcome)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.background.ignoresSafeArea())
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

    private func progress(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).font(.body).foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder private func ready(_ share: LoadedShare) -> some View {
        let destination = ShareRouter.destination(for: share.item)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(destination)).font(.title3).foregroundStyle(Palette.text)
                    .frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.label).font(.headline).foregroundStyle(Palette.text)
                    Text(share.detail).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            separator
            row("To") { Text(model.server?.name ?? String(localized: "your server")).foregroundStyle(Palette.text) }
            if case .willhaben(let ad) = destination {
                separator
                row("Ad") { Text(ad).font(Typo.data(.body)).foregroundStyle(Palette.text) }
            }
            if share.editableTitle {
                separator
                // The label stays above the field: a placeholder alone is gone once something is typed.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title").font(.footnote).foregroundStyle(Palette.secondary).accessibilityHidden(true)
                    TextField("Title", text: $model.title)
                        .font(.body)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        Button {
            Task { await model.send() }
        } label: {
            Text("Send").font(.headline).frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var separator: some View {
        Rectangle().fill(Palette.line).frame(height: 1 / 3).padding(.leading, 16)
    }

    private func row<V: View>(_ label: LocalizedStringKey, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.body).foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            value().font(.body).lineLimit(1)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func finished(_ outcome: ShareOutcome) -> some View {
        Group {
            switch outcome {
            case .sent(let text): result(symbol: "checkmark.circle.fill", color: Palette.text, title: "Sent", text: text)
            case .queued: result(symbol: "tray.and.arrow.up.fill", color: Palette.gold, title: "Saved", text: ShareOutcome.queuedText)
            case .failed(let text): result(symbol: "xmark.circle.fill", color: Palette.love, title: "Not sent", text: text)
            }
        }
        .onAppear { announce(Self.announcement(outcome)) }
        Button(action: done) {
            Text("Done").font(.headline).frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// What VoiceOver says when the send is over: "Sent", "Saved", "Not sent", with the reason.
    static func announcement(_ outcome: ShareOutcome) -> String {
        switch outcome {
        case .sent(let text): String(localized: "Sent") + ". " + text
        case .queued: String(localized: "Saved") + ". " + ShareOutcome.queuedText
        case .failed(let text): String(localized: "Not sent") + ". " + text
        }
    }

    /// Status icon, a title (white) and the reason in words. Close (when refused) is its own VoiceOver stop.
    private func result(symbol: String, color: Color, title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(color).accessibilityHidden(true)
                Text(title).font(Typo.sectionTitle).foregroundStyle(Palette.text)
                Text(text).font(.body).foregroundStyle(Palette.secondary)
            }
            .accessibilityElement(children: .combine)
            if case .refused = model.phase {
                Button("Close", action: cancel).buttonStyle(.bordered).padding(.top, 8)
                    .onAppear { announce(String(localized: "Can't send this") + ". " + text) }
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
