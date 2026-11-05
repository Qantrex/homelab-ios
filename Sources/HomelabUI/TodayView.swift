import HomelabDesign
import HomelabKit
import SwiftUI

/// Today: the first screen. My day first (the server's "today" card, what waits for me, Home tiles, the other cards,
/// the last report), the machines only as one status line that opens Lab.
struct TodayView: View {
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: ServerStatus { model.selectedStatus }
    private var state: HomelabState? { status.snapshot?.state }

    /// The card shown big at the top: the server's "today" card, else the first metrics card.
    private var hero: Card? {
        guard let cards = state?.cards else { return nil }
        return cards.first { $0.id == "today" } ?? cards.first { $0.style == .metrics }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    header
                    if model.selected != nil {
                        if let error = status.error {
                            ErrorBanner(error: error, snapshotAge: status.snapshot?.fetched) { Task { await model.refresh() } }
                        }
                        if let state {
                            statusLine(state)
                            content(state)
                        } else if status.loading {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        } else if status.error == nil {
                            Placeholder(title: "No data yet", symbol: "tray", message: "Pull down to load.")
                        }
                    }
                    if let ha = model.homeAssistant {
                        HomeTiles(model: model, server: ha)
                    }
                    if let state, model.selected != nil {
                        otherCards(state)
                        lastReport(state)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .refreshable { await model.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .pollingState(model)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now, format: .dateTime.weekday(.wide))
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(Typo.mono(.caption))
                .tracking(1)
                .foregroundStyle(Palette.secondary)
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var subtitle: String {
        var parts = [Date.now.formatted(.dateTime.day().month(.wide).year()).uppercased()]
        if let name = status.snapshot?.serverName ?? model.selected?.name { parts.append(name.uppercased()) }
        if status.loading { parts.append(String(localized: "UPDATING…")) }
        return parts.joined(separator: " · ")
    }

    /// One line for the machines: "All fine · 3/4 up" or "2 problems: sonarr unhealthy". Tap opens Lab.
    private func statusLine(_ state: HomelabState) -> some View {
        let s = state.status
        let up = state.hosts.filter { $0.reachable == true }.count
        return Button {
            model.tab = .lab
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(s.color).frame(width: 8, height: 8).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusHeadline(state)).font(Typo.mono(.subheadline, weight: .semibold))
                    if let first = state.problems.first {
                        Text(first.text).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                    }
                    Text(statusFacts(state, up: up)).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.tertiary).padding(.top, 4)
            }
            .card(accent: s == .ok || s == .unknown ? nil : s.color)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens Lab"))
    }

    private func statusHeadline(_ state: HomelabState) -> String {
        switch state.status {
        case .ok: String(localized: "All fine")
        case .unknown: String(localized: "Status unknown")
        case .warning, .problem:
            state.problems.count == 1 ? String(localized: "1 problem") : String(localized: "\(state.problems.count) problems")
        }
    }

    private func statusFacts(_ state: HomelabState, up: Int) -> String {
        var parts: [String] = []
        if !state.hosts.isEmpty { parts.append(String(localized: "\(up)/\(state.hosts.count) up")) }
        if let checked = state.checked { parts.append(String(localized: "checked \(Format.age(checked))")) }
        if let fetched = status.snapshot?.fetched, status.snapshot?.isStale() == true {
            parts.append(String(localized: "updated \(Format.age(fetched))"))
        }
        return parts.joined(separator: " · ").uppercased()
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ state: HomelabState) -> some View {
        if let hero {
            CardView(card: hero, hero: true)
        }
        if !state.pending.isEmpty {
            waiting(state.pending)
        }
    }

    /// Actions the agent proposed, so they are seen first thing. Tap opens Actions (with the confirm step there).
    private func waiting(_ pending: [PendingAction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Waiting for you", trailing: "\(pending.count)")
            Button {
                model.tab = .actions
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pending.prefix(3)) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.shield").foregroundStyle(Palette.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text([p.action, p.arg].compactMap { $0 }.joined(separator: " "))
                                    .font(Typo.mono(.subheadline, weight: .semibold)).lineLimit(1)
                                if let reason = p.reason {
                                    Text(reason).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            if let created = p.created {
                                Text(Format.age(created)).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                            }
                        }
                    }
                    if pending.count > 3 {
                        Text("and \(pending.count - 3) more").font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
                    }
                }
                .card(accent: Palette.gold)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens Actions"))
        }
    }

    @ViewBuilder
    private func otherCards(_ state: HomelabState) -> some View {
        ForEach(state.cards.filter { $0.id != hero?.id }) { CardView(card: $0) }
    }

    @ViewBuilder
    private func lastReport(_ state: HomelabState) -> some View {
        if let m = state.lastMessage, !m.text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Last report", trailing: m.ts.map { Format.age($0) })
                Button {
                    model.tab = .chat
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let job = m.job { Chip(job, color: statusColor(m.status)) }
                        Text(markdown(m.text)).font(.subheadline).lineLimit(10).multilineTextAlignment(.leading)
                    }
                    .card()
                }
                .buttonStyle(.plain)
                .disabled(!model.availableTabs.contains(.chat))
            }
        }
    }
}
