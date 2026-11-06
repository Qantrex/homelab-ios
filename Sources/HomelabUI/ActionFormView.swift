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
                            Text(arg).font(Typo.mono(.caption)).foregroundStyle(Palette.tertiary)
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
            .animation(.snappy, value: form.variant)
            .animation(.snappy, value: showProblems)
        }
        .tint(Palette.accent)
    }

    private var confirmMessage: String {
        let lines = form.summary.map { $0.label.isEmpty ? $0.value : "\($0.label): \($0.value)" }
        let what = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
        return what + String(localized: "Runs at once on \(server.name).")
    }

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
                TextField(label, text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing).font(Typo.mono(.body))
            }
        case .word:
            LabeledContent(label) {
                TextField(label, text: text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing).font(Typo.mono(.body))
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
                    Text("\(count)/\(field.max)").font(Typo.mono(.caption2))
                        .foregroundStyle(count > field.max ? Palette.love : Palette.tertiary)
                }
            }
        case .number:
            LabeledContent(field.label) {
                TextField(prompt(field), text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing).font(Typo.mono(.body))
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

/// The "Start" tiles: one per action the server lets the app start.
struct StartGrid: View {
    let actions: [ActionSpec]
    let open: (ActionSpec) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .top)]
                                                        : [GridItem(.flexible(), spacing: 10, alignment: .top),
                                                           GridItem(.flexible(), spacing: 10, alignment: .top)],
                  spacing: 10) {
            ForEach(actions) { spec in
                Button { open(spec) } label: { StartTile(spec: spec, evenRows: !typeSize.isAccessibilitySize) }
                    .buttonStyle(.press)
                    .accessibilityLabel(Text(spec.label))
                    .accessibilityHint(Text(spec.hint ?? String(localized: "Opens its form.")))
            }
        }
    }
}

/// Every tile in a row is the same height, so their tops and texts line up: the icon row has a fixed height (some
/// symbols, like calendar.badge.plus, are taller) and the title always takes two lines (`evenRows`: off in the
/// one-column grid at accessibility sizes, where there is no neighbour to line up with).
struct StartTile: View {
    let spec: ActionSpec
    var evenRows = true
    @ScaledMetric(relativeTo: .title3) private var iconRow: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: Symbols.safe(spec.icon, fallback: "play.circle")).font(.title3)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.tertiary)
            }
            .frame(height: iconRow)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.label).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: evenRows)
                    .multilineTextAlignment(.leading)
                Text(spec.name.uppercased()).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .foregroundStyle(Palette.text)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
