import HomelabDesign
import HomelabKit
import SwiftUI

// Show rules in the app (docs/plans/MODULAR.md, M3.2): the rule under each row of Settings → Today → Sections, the
// sheet that picks it, and Today's "Hidden now" line. The words and the logic are in the kit (ShowRuleEditing.swift).

/// One row of Settings → Today → Sections: the section's name with its rule in words under it ("Evenings", "Not on
/// your servers"); a tap opens the rule sheet. The switch shows or hides the section, as before.
struct SectionRuleRow: View {
    let model: AppModel
    let section: TodaySection
    @State private var editing = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var layout: TodayLayout { model.settings.todayLayout }

    private var words: String {
        let rule = layout.ruleWords(for: section)
        if model.serversCanFill(section) { return rule }
        return layout.rule(for: section) == nil ? String(localized: "Not on your servers")
                                                : String(localized: "\(rule) · Not on your servers")
    }

    var body: some View {
        // At accessibility sizes the switch goes under the name, so the name and the rule aren't squeezed.
        let stack = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                 : AnyLayout(HStackLayout(spacing: 12))
        stack {
            Button { editing = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(Typo.body).foregroundStyle(Palette.text)
                    Text(words).font(Typo.meta).foregroundStyle(Palette.tertiary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(section.title), \(HiddenNow.spoken(words))"))
            .accessibilityHint(Text("Choose when it shows"))
            .accessibilityAddTraits(.isButton)
            Toggle(isOn: Binding(get: { model.settings.todayLayout.isVisible(section) },
                                 set: { model.settings.todayLayout.setVisible(section, $0) })) {
                Text(section.title)
            }
            .labelsHidden()
        }
        .sheet(isPresented: $editing) { ShowRuleSheet(model: model, section: section) }
    }
}

/// When one section shows: Always, When it needs me, a named time (Mornings … Weekends), Custom (from, to, days),
/// and At home or Away once Settings → Today → Where you are is set (`AppModel.ruleKinds(for:)`). Done saves, Cancel
/// keeps the old rule.
struct ShowRuleSheet: View {
    let model: AppModel
    let section: TodaySection
    /// The rule being edited and whether Custom is chosen (Custom stays Custom on a named window's times).
    @State private var choice: RuleChoice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: AppModel, section: TodaySection) {
        self.model = model
        self.section = section
        _choice = State(initialValue: RuleChoice(model.settings.todayLayout.rule(for: section), for: section))
    }

    private var chosen: RuleOption { choice.chosen }

    /// The kinds the app allows, plus the stored rule's own (an At home rule stays visible after Where you are is
    /// turned off, so it can be changed).
    private var options: [RuleOption] {
        let offered = RuleOption.options(for: section, kinds: model.ruleKinds(for: section))
        return offered.contains(chosen) ? offered : offered + [chosen]
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        ForEach(options) { optionRow($0) }
                    } header: {
                        Text("Show")
                    } footer: {
                        SettingsFooter("Overkill shows every section. In Calm, a section set to \"When it needs me\" joins the day and Home while it needs you.")
                    }
                    if let w = choice.custom {
                        Section {
                            DatePicker("From", selection: time(w.from) { w.with(from: $0) }, displayedComponents: .hourAndMinute)
                            DatePicker("To", selection: time(w.to) { w.with(to: $0) }, displayedComponents: .hourAndMinute)
                            dayChips(w)
                        } header: {
                            Text("Custom")
                        } footer: {
                            SettingsFooter("A time that ends before it starts runs past midnight. The days are the ones it starts on.")
                        }
                    }
                }
                .surfaceRows()
            }
            .screenBackground()
            // The sections list is always in edit mode (drag handles); the sheet would inherit it.
            .environment(\.editMode, .constant(.inactive))
            .navigationTitle(section.shortTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.settings.todayLayout.setRule(choice.rule, for: section)
                        dismiss()
                    }
                }
            }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
    }

    private func optionRow(_ option: RuleOption) -> some View {
        let on = option == chosen
        let detail = option == .custom && on ? choice.customWords(calendar: calendar) : option.detail(for: section)
        return Button { choice.choose(option) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(Typo.body).foregroundStyle(Palette.text)
                    if let detail { Text(detail).font(Typo.meta).foregroundStyle(Palette.tertiary) }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if on {
                    Image(systemName: "checkmark").font(Typo.headline).foregroundStyle(Palette.text).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [option.title, detail.map(HiddenNow.spoken)].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// A time picker's value: `minutes` on the picker's fixed day (2:30 stays 2:30 on the day the clocks go forward);
    /// a new time edits the Custom window through `change`.
    private func time(_ minutes: Int, _ change: @escaping @Sendable (Int) -> TimeWindow) -> Binding<Date> {
        Binding(get: { TimeWindow.pickerDate(minutes: minutes, calendar: calendar) },
                set: { choice.edit(change(TimeWindow.minutes(of: $0, calendar: calendar))) })
    }

    /// Monday to Friday in the first row, Saturday and Sunday in the second; filled = on.
    private func dayChips(_ w: TimeWindow) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 2 : 5)
        return VStack(alignment: .leading, spacing: 8) {
            Text("On these days").font(Typo.meta).foregroundStyle(Palette.tertiary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(TimeWindow.mondayFirst, id: \.self) { day in
                    let on = w.includes(day: day)
                    Button { choice.edit(w.toggling(day: day)) } label: {
                        Text(verbatim: calendar.shortWeekdaySymbols[day - 1])
                            .font(Typo.secondary.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(on ? Palette.onAccent : Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(on ? Palette.text : Palette.raised, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: calendar.weekdaySymbols[day - 1]))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Under Today's sections while a rule hides something that has content: "Hidden now: Deals (evenings) · Show".
/// "Show" lets those sections through until the app closes. Nothing at all without rules.
struct HiddenNowLine: View {
    let model: AppModel
    let context: ShowContext
    let now: Date

    var body: some View {
        let hidden = model.hiddenOnToday(context, now: now)
        if let text = HiddenNow.text(hidden, layout: model.settings.todayLayout, calendar: context.calendar) {
            Button {
                model.showAnyway(hidden)
            } label: {
                Text("\(Text(verbatim: text).foregroundStyle(Palette.tertiary)) · \(Text("Show").fontWeight(.semibold).foregroundStyle(Palette.text))")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.tertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: HiddenNow.spoken(text)))
            .accessibilityHint(Text("Shows them until you close the app"))
            .transition(.opacity)
        }
    }
}
