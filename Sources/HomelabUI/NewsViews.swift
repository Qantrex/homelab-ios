import HomelabDesign
import HomelabKit
import SafariServices
import SwiftUI

/// News on Today (docs/DESIGN.md "Tiles", docs/API.md "News"): the sheet behind the News tile and the Settings page.
/// The phone never fetches feeds; the server does.

/// An article in SFSafariViewController, in reader mode when the page has one. No blue: the controls are white on
/// black in the dark scheme and black on white in the light one (the bar follows the colour scheme, never forced black).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = true
        let controller = SFSafariViewController(url: url, configuration: config)
        style(controller, dark: context.environment.colorScheme == .dark)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        style(controller, dark: context.environment.colorScheme == .dark)
    }

    private func style(_ controller: SFSafariViewController, dark: Bool) {
        controller.preferredControlTintColor = dark ? .white : .black
        controller.preferredBarTintColor = dark ? .black : .white
    }
}

/// An article to open (a sheet needs an identifiable value).
struct Article: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The News tile's sheet with the EN / DE switch at the top left. The switch is for this session; the start language
/// is Settings → Advanced → Today → News.
struct NewsSheet: View {
    let card: Card
    @State private var language: NewsLanguage

    init(card: Card, defaultLanguage: NewsLanguage) {
        self.card = card
        _language = State(initialValue: defaultLanguage)
    }

    var body: some View {
        TileSheet(title: "News", leading: AnyView(NewsLanguageSwitch(language: $language))) {
            NewsSheetContent(card: card, language: language)
        }
    }
}

/// A two-segment EN / DE control small enough for a toolbar.
struct NewsLanguageSwitch: View {
    @Binding var language: NewsLanguage

    var body: some View {
        Picker("Language", selection: $language) {
            ForEach(NewsLanguage.allCases) { Text(verbatim: $0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 96)
        .accessibilityLabel(Text("News language"))
    }
}

/// The News tile's sheet: the digest, then one row per headline (title, summary, "Source · age"), newest first; a row
/// opens the article.
struct NewsSheetContent: View {
    let card: Card
    var language: NewsLanguage = .en
    @State private var article: Article?
    @Environment(\.hyper) private var hyper

    var body: some View {
        let list = NewsList(card: card, language: language)
        VStack(alignment: .leading, spacing: 12) {
            if let digest = list.digest {
                Text(verbatim: digest).font(Typo.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            ForEach(list.rows) { row in
                if row.id > 0 || list.digest != nil { TodaySeparator() }
                if let url = row.url {
                    Button { article = Article(url: url) } label: { rowLabel(row) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Opens the article"))
                } else {
                    rowLabel(row)
                }
                if let hyper {
                    HyperNote(lines: Hyper.item(row.item, now: hyper.now, calendar: hyper.calendar),
                              fact: Hyper.fact(item: row.item, in: card, now: hyper.now, calendar: hyper.calendar))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fullScreenCover(item: $article) { SafariView(url: $0.url).ignoresSafeArea() }
    }

    private func rowLabel(_ row: NewsList.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: row.title).font(Typo.headline).foregroundStyle(Palette.text)
                .multilineTextAlignment(.leading)
            if let summary = row.summary {
                Text(verbatim: summary).font(Typo.body).foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !row.meta.isEmpty {
                Text(verbatim: row.meta).font(Typo.secondary).foregroundStyle(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// News in Hyperdetail, where no tile opens a sheet: the card as a titled panel with the same rows as the sheet, so a
/// story opens in the in-app reader and not in Safari. Today draws it instead of the generic `CardView` for a news card
/// (`TodayFold.tileKind(card) == .news`).
struct NewsHyperBlock: View {
    let card: Card
    var language: NewsLanguage = .en
    @Environment(\.hyper) private var hyper

    var body: some View {
        VStack(alignment: .leading, spacing: Space.titleToPanel) {
            SectionTitle(text: card.title.map { LocalizedStringKey($0) } ?? "News")
            if let hyper {
                HyperNote(lines: Hyper.card(card, now: hyper.now, calendar: hyper.calendar), fact: Hyper.fact(card: card))
            }
            NewsSheetContent(card: card, language: language).panel()
        }
    }
}

/// What a tile sheet shows when its kind is no longer in the state (the server dropped the card while the sheet was
/// open): a word instead of an empty sheet.
struct TileGonePlaceholder: View {
    var body: some View {
        Placeholder(title: "Nothing here any more", symbol: "tray", message: "The server stopped sending this.")
    }
}

/// The "News" row of Settings → Today. It exists only when the selected server answers `GET /news/sources`
/// (a 404 or any error hides it, without a word).
struct NewsSettingsRow: View {
    let model: AppModel
    @State private var catalog: NewsCatalog?

    var body: some View {
        Group {
            if let catalog {
                NavigationLink {
                    NewsSettingsView(model: model, catalog: catalog)
                } label: {
                    LabeledContent("News") {
                        Text(verbatim: catalog.prefs.enabled ? String(localized: "\(catalog.prefs.sources.count) sources") : String(localized: "Off"))
                            .font(Typo.secondary).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
        .task(id: model.selected?.id) {
            guard let server = model.selected, server.speaksCompanionAPI else { catalog = nil; return }
            catalog = await NewsAvailability.catalog(model.companion(for: server))
        }
    }
}

/// Settings → Today → News: On/Off, country, sources, summary or headlines, count and window. Every change goes to
/// the server at once (`PUT /news/prefs`): the screen shows it straight away and goes back to what the server
/// keeps if that fails, with the reason underneath. The server is the source of truth; nothing is stored here.
struct NewsSettingsView: View {
    let model: AppModel
    @State var catalog: NewsCatalog
    @State private var confirmed: NewsPrefs
    @State private var error: String?

    init(model: AppModel, catalog: NewsCatalog) {
        self.model = model
        _catalog = State(initialValue: catalog)
        _confirmed = State(initialValue: catalog.prefs)
    }

    private var prefs: NewsPrefs { catalog.prefs }

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle("News on Today", isOn: Binding(get: { prefs.enabled }, set: { v in
                        var p = prefs; p.enabled = v; change(p)
                    }))
                } footer: {
                    SettingsFooter("Your server collects the news and shows it as a tile on Today. This phone never fetches feeds.")
                }

                if prefs.enabled {
                    Section {
                        Picker("Country", selection: Binding(get: { prefs.country }, set: { change(catalog.prefs(prefs, country: $0)) })) {
                            ForEach(catalog.countries) { Text(verbatim: $0.name).tag($0.id) }
                        }
                    }

                    Section {
                        ForEach(catalog.sources(for: prefs.country)) { source in
                            Toggle(isOn: Binding(get: { prefs.sources.contains(source.id) },
                                                 set: { _ in change(catalog.prefs(prefs, toggling: source.id)) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: source.name)
                                    if source.topic != "general" {
                                        Text(verbatim: source.topic.capitalized).font(Typo.secondary).foregroundStyle(Palette.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Sources")
                    } footer: {
                        SettingsFooter("Your country's sources, plus tech and international ones.")
                    }

                    Section {
                        Picker("Show", selection: Binding(get: { prefs.summary }, set: { v in
                            var p = prefs; p.summary = v; change(p)
                        })) {
                            Text("Summaries").tag(true)
                            Text("Headlines").tag(false)
                        }
                        .disabled(!catalog.canSummarize)
                        Picker("Stories", selection: Binding(get: { prefs.count }, set: { v in
                            var p = prefs; p.count = v; change(p)
                        })) {
                            ForEach(NewsPrefs.counts, id: \.self) { Text(verbatim: String($0)).tag($0) }
                        }
                        Picker("From the last", selection: Binding(get: { prefs.windowH }, set: { v in
                            var p = prefs; p.windowH = v; change(p)
                        })) {
                            ForEach(NewsPrefs.windows, id: \.self) { Text(verbatim: "\($0) h").tag($0) }
                        }
                    } footer: {
                        SettingsFooter(catalog.canSummarize
                            ? "Summaries give one sentence for the day and one line per story, in English."
                            : "Your server can't summarise, so the original headlines show.")
                    }
                }

                Section {
                    Picker("Language", selection: Binding(get: { model.settings.newsLang }, set: { model.settings.newsLang = $0 })) {
                        ForEach(NewsLanguage.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                } footer: {
                    SettingsFooter("The language the News sheet starts in. The switch at its top left changes it for that visit.")
                }

                if let error {
                    Section { Text(verbatim: error).foregroundStyle(Palette.love) }
                }
            }
            .surfaceRows()
            .headerProminence(.increased)
        }
        .screenBackground()
        .navigationTitle("News")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Shows `new` at once, sends it, and returns to the server's last answer if that fails.
    private func change(_ new: NewsPrefs) {
        guard let server = model.selected else { return }
        let sent = new.validated(canSummarize: catalog.canSummarize)
        catalog.prefs = sent
        error = nil
        let api = model.companion(for: server)
        let host = server.host
        Task {
            do {
                let stored = try await api.setNewsPrefs(sent)
                confirmed = stored
                // A newer change made while this one was on its way stays; otherwise show what the server stored.
                if catalog.prefs == sent { catalog.prefs = stored }
            } catch {
                catalog.prefs = confirmed
                self.error = String(localized: "Could not save: \(APIError.from(error, host: host).message)")
            }
        }
    }
}
