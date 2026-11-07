import HomelabDesign
import HomelabKit
import SwiftUI

/// The form for one action the owner starts (GET /actions). Rules and defaults live in `ActionForm` (HomelabKit);
/// this view only binds controls to it, asks once, runs, and hands the result back.
struct ActionFormView: View {
    let model: AppModel
    let server: ServerConfig
    let finished: (Result<ActionResult, APIError>) -> Void

    @State private var form: ActionForm
    @State private var confirming = false
    @State private var running = false
    @State private var showProblems = false
    @State private var blocked = 0
    @Environment(\.dismiss) private var dismiss

    /// `prefill`: a card's action (its `payload` and `arg` fill the form, e.g. the list for "Add").
    init(model: AppModel, server: ServerConfig, spec: ActionSpec, prefill: ItemAction? = nil,
         finished: @escaping (Result<ActionResult, APIError>) -> Void) {
        self.model = model
        self.server = server
        self.finished = finished
        _form = State(initialValue: ActionForm(spec, prefill: prefill))
    }

    private var spec: ActionSpec { form.spec }
    private var inputParts: [(index: Int, part: ActionSpec.ArgPart)] {
        form.parts.enumerated().compactMap { i, p in
            if case .literal = p { return nil }
            return (i, p)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if spec.variants.count > 1 {
                    Section {
                        Picker("Kind", selection: $form.variant) {
                            ForEach(spec.variants.indices, id: \.self) { i in Text(spec.variants[i].label).tag(i) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if !inputParts.isEmpty {
                    Section {
                        ForEach(inputParts, id: \.index) { item in partRow(item.index, item.part) }
                    } footer: {
                        if let arg = form.arg, !arg.isEmpty {
                            Text(arg).font(Typo.meta).foregroundStyle(Palette.tertiary)
                                .accessibilityLabel(Text("Sends \(arg)"))
                        }
                    }
                    .surfaceRows()
                }
                if !form.visibleFields.isEmpty {
                    Section {
                        ForEach(form.visibleFields) { field in fieldRow(field) }
                    }
                    .surfaceRows()
                }
                if showProblems, !form.problems.isEmpty {
                    Section {
                        ForEach(form.problems, id: \.self) { p in
                            Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.gold)
                        }
                    }
                    .surfaceRows()
                }
                if let hint = spec.hint {
                    Section { EmptyView() } footer: { Text(hint) }
                }
            }
            .screenBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(spec.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if running {
                        ProgressView()
                    } else {
                        Button("Run") {
                            if form.isReady { confirming = true } else { showProblems = true; blocked += 1 }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .confirmationDialog(spec.label, isPresented: $confirming, titleVisibility: .visible) {
                Button(spec.destructive ? String(localized: "Run it") : String(localized: "Run now"),
                       role: spec.destructive ? .destructive : nil) { Task { await run() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
            .sensoryFeedback(.warning, trigger: blocked)
            .interactiveDismissDisabled(running)
            .motion(.snappy, value: form.variant)
            .motion(.snappy, value: showProblems)
        }
        .tint(Palette.accent)
        .labeledContentStyle(.adaptive)
    }

    private var confirmMessage: String { confirmText(form, server: server.name) }

    private func run() async {
        running = true
        let result = await model.run(form, on: server)
        running = false
        finished(result)
        dismiss()
    }

    // MARK: Argument parts

    @ViewBuilder
    private func partRow(_ i: Int, _ part: ActionSpec.ArgPart) -> some View {
        let text = Binding(get: { form.value(part: i) }, set: { form.set(part: i, $0) })
        let label = part.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Value")
        switch part {
        case .literal:
            EmptyView()
        case .date:
            DatePicker(label, selection: dayBinding(text), displayedComponents: .date)
        case .time:
            DatePicker(label, selection: timeBinding(text), displayedComponents: .hourAndMinute)
        case .choice(_, let options) where options.count <= 3:
            // Few options: all visible at once (Duke | U6).
            Picker(label, selection: text) {
                ForEach(options) { o in Text(o.label).tag(o.value) }
            }
            .pickerStyle(.segmented)
        case .choice(_, let options):
            Picker(label, selection: text) {
                ForEach(options) { o in Text(o.label).tag(o.value) }
            }
            .pickerStyle(.menu)
        case .number:
            LabeledContent(label) {
                TextField(label, text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing).font(Typo.data(.body))
            }
        case .word:
            LabeledContent(label) {
                TextField(label, text: text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing).font(Typo.data(.body))
            }
        }
    }

    // MARK: Payload fields

    @ViewBuilder
    private func fieldRow(_ field: ActionSpec.Field) -> some View {
        let text = Binding(get: { form.fieldValues[field.name] ?? "" },
                           set: { form.fieldValues[field.name] = $0.isEmpty ? nil : $0 })
        switch field.kind {
        case .text, .multiline:
            VStack(alignment: .trailing, spacing: 2) {
                TextField(field.label, text: text, prompt: Text(prompt(field)), axis: field.kind == .multiline ? .vertical : .horizontal)
                    .lineLimit(field.kind == .multiline ? 3...8 : 1...1)
                let count = ActionForm.length(text.wrappedValue)
                if count > field.max * 4 / 5 {
                    Text("\(count)/\(field.max)").font(Typo.data(.caption2))
                        .foregroundStyle(count > field.max ? Palette.love : Palette.tertiary)
                }
            }
        case .number:
            LabeledContent(field.label) {
                TextField(prompt(field), text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing).font(Typo.data(.body))
            }
        case .choice:
            Picker(field.label, selection: text) {
                if !field.required { Text("–").tag("") }
                ForEach(field.options) { o in Text(o.label).tag(o.value) }
            }
        case .date, .datetime, .dateOrDatetime:
            dateField(field, text)
        }
    }

    @ViewBuilder
    private func dateField(_ field: ActionSpec.Field, _ text: Binding<String>) -> some View {
        let on = !text.wrappedValue.isEmpty
        if !field.required {
            Toggle(field.label, isOn: Binding(get: { on }, set: {
                text.wrappedValue = $0 ? (ActionForm.defaultValue(field) ?? "") : ""
            }))
        }
        if on {
            let hasTime = text.wrappedValue.contains("T")
            switch field.kind {
            case .date:
                DatePicker(field.required ? field.label : String(localized: "Day"), selection: dayBinding(text), displayedComponents: .date)
            case .datetime:
                DatePicker(field.required ? field.label : String(localized: "When"), selection: dayTimeBinding(text),
                           displayedComponents: [.date, .hourAndMinute])
            default:
                DatePicker(field.required ? field.label : String(localized: "Day"),
                           selection: hasTime ? dayTimeBinding(text) : dayBinding(text),
                           displayedComponents: hasTime ? [.date, .hourAndMinute] : .date)
                Toggle("At a time", isOn: Binding(get: { hasTime }, set: { timed in
                    let day = String(text.wrappedValue.prefix(10))
                    text.wrappedValue = timed ? day + "T09:00" : day
                }))
            }
        }
    }

    private func prompt(_ field: ActionSpec.Field) -> String {
        field.placeholder ?? (field.required ? field.label : String(localized: "\(field.label) (optional)"))
    }

    // MARK: Date bindings: the form keeps the server's text ("2026-11-07", "07:30", "2026-11-07T07:30")

    private func dayBinding(_ text: Binding<String>) -> Binding<Date> {
        Binding(get: { ActionForm.date(String(text.wrappedValue.prefix(10))) ?? Date() },
                set: { d in
                    let rest = text.wrappedValue.count > 10 ? String(text.wrappedValue.dropFirst(10)) : ""
                    text.wrappedValue = ActionForm.day(d) + rest
                })
    }

    private func timeBinding(_ text: Binding<String>) -> Binding<Date> {
        Binding(get: { ActionForm.date(text.wrappedValue) ?? ActionForm.date("07:00") ?? Date() },
                set: { text.wrappedValue = ActionForm.time($0) })
    }

    private func dayTimeBinding(_ text: Binding<String>) -> Binding<Date> {
        Binding(get: { ActionForm.date(text.wrappedValue) ?? Date() },
                set: { text.wrappedValue = ActionForm.dayTime($0) })
    }
}

/// The "Start" tiles (docs/DESIGN.md §2, research #7): compact, two columns of 56 pt tiles (symbol and a one-line
/// label; a long label takes a second line instead of being cut), one per action the server lets the app start, and
/// the Search and Scan tiles where the server offers them. Tiles in a row have the same height; the grid's edges line up
/// with the panels around it. One column at accessibility sizes.
struct StartGrid: View {
    let actions: [ActionSpec]
    /// Waiting scans and shares in the outbox; nil = no Scan tile.
    var scanWaiting: Int?
    /// Overkill density: the action's id as tertiary meta under its label.
    var showIds = false
    let open: (ActionSpec) -> Void
    var scan: () -> Void = {}
    /// Feature `search`: a tile that opens the search screen; nil = no tile.
    var search: (() -> Void)?
    /// Feature `deals`: a tile that opens the Deals screen; nil = no tile. `dealsToAct` is the number of fresh "act
    /// now" deals (a gold dot and its words under the label), 0 = none.
    var deals: (() -> Void)?
    var dealsToAct = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A tile: an action (its index in `actions`), the Search tile or the Scan tile.
    private enum Tile: Hashable { case action(Int), search, deals, scan }

    private var tiles: [Tile] {
        actions.indices.map(Tile.action) + (search == nil ? [] : [.search]) + (deals == nil ? [] : [.deals])
            + (scanWaiting == nil ? [] : [.scan])
    }

    var body: some View {
        let tiles = tiles
        if typeSize.isAccessibilitySize {
            VStack(spacing: Space.row) {
                ForEach(tiles, id: \.self) { tile($0) }
            }
        } else {
            // Grid, not LazyVGrid: a row is as tall as its tallest tile, and both tiles fill it.
            Grid(horizontalSpacing: Space.row, verticalSpacing: Space.row) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { i in
                    GridRow {
                        tile(tiles[i])
                        if i + 1 < tiles.count {
                            tile(tiles[i + 1])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ tile: Tile) -> some View {
        switch tile {
        case .action(let i):
            let spec = actions[i]
            Button { open(spec) } label: {
                StartTile(icon: spec.icon, label: Text(verbatim: spec.label), meta: showIds ? spec.name : nil)
            }
            .buttonStyle(.press)
            .accessibilityLabel(Text(spec.label))
            .accessibilityHint(Text(spec.hint ?? String(localized: "Opens its form.")))
        case .search:
            Button { search?() } label: {
                StartTile(icon: "magnifyingglass", label: Text("Find a movie or show"))
            }
            .buttonStyle(.press)
            .accessibilityLabel(Text("Find a movie or show"))
            .accessibilityHint(Text("Searches the server and lets you request what is missing."))
        case .deals:
            Button { deals?() } label: {
                StartTile(icon: "tag", label: Text("Deals"),
                          status: dealsToAct > 0 ? "\(dealsToAct) to act on" : nil, statusValue: dealsToAct)
            }
            .buttonStyle(.press)
            .accessibilityLabel(Text("Deals"))
            .accessibilityValue(dealsToAct > 0 ? Text("\(dealsToAct) to act on") : Text(""))
            .accessibilityHint(Text("Used-market ads far below their value, with the server's verdict."))
        case .scan:
            let waiting = scanWaiting ?? 0
            Button(action: scan) {
                StartTile(icon: "doc.viewfinder", label: Text("Scan a document"),
                          status: waiting > 0 ? "\(waiting) waiting" : nil, statusValue: waiting)
            }
            .buttonStyle(.press)
            .accessibilityLabel(Text("Scan a document"))
            .accessibilityValue(waiting > 0 ? Text("\(waiting) waiting to be sent") : Text(""))
            .accessibilityHint(Text("Opens the camera and sends the PDF to Paperless."))
        }
    }
}

/// A Start tile: the symbol (20) and the label (15 semibold) side by side, at least 56 pt high, and at most one
/// line of meta (an id, tertiary, data font) or status (a gold dot and its words) under the label.
struct StartTile: View {
    let icon: String?
    let label: Text
    var meta: String?
    var status: LocalizedStringKey?
    /// The number in `status`, for its rolling digits.
    var statusValue = 0
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Symbols.safe(icon, fallback: "play.circle")).font(.title3)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                label.font(Typo.secondary.weight(.semibold)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    HStack(spacing: 4) {
                        Circle().fill(Palette.gold).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(status).font(Typo.meta).foregroundStyle(Palette.secondary).lineLimit(1)
                            .numberMotion(statusValue)
                    }
                } else if let meta {
                    Text(meta).font(Typo.meta).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(Palette.text)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
