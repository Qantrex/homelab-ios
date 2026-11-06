import HomelabDesign
import HomelabKit
import SwiftUI
import UIKit

/// A picture from the selected server (docs/API.md, `image`): a quiet placeholder (the card's icon on a raised
/// surface) until `ImageLoader` has it, and when it can't be loaded. 2:3, rounded. Pictures never come from anywhere
/// but the server: the loader refuses everything else.
struct PosterImage: View {
    let model: AppModel?
    let path: String?
    let icon: String?
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .background(Palette.raised)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: Symbols.safe(icon, fallback: "film")).font(.title2).foregroundStyle(Palette.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .reducedMotionAnimation(.easeOut(duration: 0.2), value: image == nil)
            .accessibilityIgnoresInvertColors()   // Smart Invert keeps photos as they are
            .accessibilityHidden(true)
            .task(id: (model?.selected?.id.uuidString ?? "") + "|" + (path ?? "")) { await load() }
    }

    private func load() async {
        guard let model, let server = model.selected, let path else { image = nil; return }
        guard let data = await model.imageLoader(for: server).data(for: path), !Task.isCancelled else { return }
        image = UIImage(data: data)
    }
}

/// Find and request (feature `search`): a search field, 400 ms after the last key it asks the server, and the answer's
/// cards (a poster grid) below. A poster's Request button uses the same confirm as every card action.
struct SearchView: View {
    let model: AppModel
    let server: ServerConfig
    @State private var query: String
    @State private var found: SearchResult?
    @State private var failure: APIError?
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, server: ServerConfig, query: String = "") {
        self.model = model
        self.server = server
        _query = State(initialValue: query)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    if let failure {
                        ErrorBanner(error: failure, snapshotAge: nil) { Task { await run(wait: false) } }
                    }
                    results
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Find and request")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Title"))
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { if loading { ProgressView() } }
            }
            .task(id: query) { await run(wait: true) }
        }
        .tint(Palette.accent)
    }

    @ViewBuilder private var results: some View {
        if SearchQuery.clean(query) == nil {
            Placeholder(title: "Find a movie or show", symbol: "magnifyingglass",
                        message: "Type at least 2 letters. The server looks it up and you can request what is missing.")
                .padding(.top, 40)
        } else if let found {
            if found.shown.isEmpty {
                if !loading {
                    Placeholder(title: "Nothing found", symbol: "film", message: "Try another spelling or a shorter title.")
                        .padding(.top, 40)
                }
            } else {
                ForEach(found.shown) { CardView(card: $0, model: model) }
            }
        } else if failure == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    /// Debounced: the task restarts with every key, so only a pause in typing reaches the server.
    private func run(wait: Bool) async {
        guard let q = SearchQuery.clean(query) else {
            loading = false; failure = nil; found = nil
            return
        }
        if wait {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        loading = true
        let r = await model.search(q, on: server)
        guard !Task.isCancelled else { return }
        loading = false
        switch r {
        case .success(let result):
            found = result; failure = nil
            // VoiceOver hears what came back, without leaving the search field.
            let n = result.shown.count
            announce(n == 0 ? String(localized: "Nothing found")
                            : n == 1 ? String(localized: "1 result") : String(localized: "\(n) results"))
        case .failure(let error): failure = error
        }
    }
}
