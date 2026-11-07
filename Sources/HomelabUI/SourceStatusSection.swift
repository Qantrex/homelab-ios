import HomelabDesign
import HomelabKit
import SwiftUI

/// Diagnostics → "Sources": how each source of a Homelab Bridge is doing (`sources` in /info, MODULAR.md M2.4).
/// Only for a server that sends the list; a server without sources (the owner's) gets no section.
struct SourceStatusSection: View {
    /// "Sources", or "Sources · <server>" when more than one server sends a list.
    let title: String
    let sources: [SourceStatus]

    var body: some View {
        Section {
            if sources.isEmpty {
                Text("The server lists no sources.").font(.subheadline).foregroundStyle(Palette.secondary)
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                SourceStatusRow(source: source)
            }
        } header: {
            Text(verbatim: title)
        } footer: {
            SettingsFooter("What the Homelab Bridge reads, as of its last /info (asked every 10 minutes). A failing source is also one of its warnings.")
        }
    }
}

/// One source: its name and type, the state in words ("ok", "failing: 401", "not yet"), when it last worked, and a
/// gold warning while it skips the certificate check (owner decision 5).
struct SourceStatusRow: View {
    let source: SourceStatus

    var body: some View {
        let time = source.timeText()
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: source.name).font(.headline).foregroundStyle(Palette.text)
            if let type = source.type {
                Text(verbatim: type).font(.subheadline).foregroundStyle(Palette.secondary)
            }
            stateLabel
            if let time {
                Text(verbatim: time).font(Typo.data(.footnote)).foregroundStyle(Palette.tertiary)
            }
            if source.insecure {
                Label(SourceStatus.insecureText, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Palette.gold)
            }
            if source.plainHTTP {
                Label(SourceStatus.plainHTTPText, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Palette.gold)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken(time)))
    }

    /// Love only for failing (an error); the rest stays grey, like the server rows above it.
    @ViewBuilder private var stateLabel: some View {
        switch source.state {
        case .ok:
            Label(source.stateText, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(Palette.secondary)
        case .failing:
            Label(source.stateText, systemImage: "xmark.circle.fill").font(.footnote).foregroundStyle(Palette.love)
        case .never:
            Label(source.stateText, systemImage: "clock").font(.footnote).foregroundStyle(Palette.tertiary)
        case .unknown:
            Label(source.stateText, systemImage: "questionmark.circle").font(.footnote).foregroundStyle(Palette.tertiary)
        }
    }

    /// "pve1, proxmox, failing: 401, last ok 1 hour ago, Certificate not checked (insecure)".
    private func spoken(_ time: String?) -> String {
        [source.name, source.type, source.stateText, time.map(Format.spoken),
         source.insecure ? SourceStatus.insecureText : nil,
         source.plainHTTP ? SourceStatus.plainHTTPText : nil].compactMap { $0 }.joined(separator: ", ")
    }
}
