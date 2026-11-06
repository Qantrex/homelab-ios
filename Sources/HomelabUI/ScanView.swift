import HomelabDesign
import HomelabKit
import SwiftUI

/// The "Scan" tile under the Start grid (only when the server has the feature `documents`). It looks like the Start
/// tiles; a number in gold says how many scans or shares wait in the outbox.
struct ScanStartRow: View {
    let waiting: Int
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var iconRow: CGFloat = 26

    var body: some View {
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .top)]
                                                        : [GridItem(.flexible(), spacing: 10, alignment: .top),
                                                           GridItem(.flexible(), spacing: 10, alignment: .top)],
                  spacing: 10) {
            Button(action: open) { tile }
                .buttonStyle(.press)
                .accessibilityLabel(Text("Scan a document"))
                .accessibilityValue(waiting > 0 ? Text("\(waiting) waiting to be sent") : Text(""))
                .accessibilityHint(Text("Opens the camera and sends the PDF to Paperless."))
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.viewfinder").font(.title3)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.tertiary)
            }
            .frame(height: iconRow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan a document").font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                if waiting > 0 {
                    Text("\(waiting) WAITING").font(Typo.mono(.caption2)).foregroundStyle(Palette.gold).lineLimit(1)
                } else {
                    Text("SCAN").font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
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

/// Scan a document with the camera, check it, and send it to the server's Paperless inbox (`POST /documents`).
/// Where the server can't be reached the PDF waits in the outbox and the app sends it later.
struct ScanView: View {
    let model: AppModel
    let server: ServerConfig
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case idle
        case making
        case ready(pdf: Data, pages: Int)
        case sending(Int)
    }

    private struct Message: Identifiable {
        let id = UUID()
        let title: String
        let text: String
        let finishes: Bool
    }

    @State private var phase = Phase.idle
    @State private var title = ShareRouter.defaultScanTitle()
    @State private var camera = false
    @State private var message: Message?
    @State private var outcome: ShareOutcome?
    @State private var sheetToken = UUID()
    @State private var openedCamera = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .idle: idle
                    case .making: progress("Making the PDF…")
                    case .ready(let pdf, let pages): ready(pdf: pdf, pages: pages)
                    case .sending(let bytes): progress("Sending \(Self.size(bytes))…")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.background)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSending)
                }
            }
            .fullScreenCover(isPresented: $camera) {
                DocumentScanner(onPages: make, onCancel: { camera = false }).ignoresSafeArea()
            }
            .alert(item: $message) { m in
                Alert(title: Text(m.title), message: Text(m.text), dismissButton: .default(Text("OK")) {
                    if m.finishes { dismiss() }
                })
            }
            .sensoryFeedback(trigger: outcome) { _, new in
                switch new { case .sent?: .success; case .failed?: .error; default: nil }
            }
            .onAppear {
                model.formSheet(sheetToken, open: true)
                // The camera opens by itself, once, where there is one.
                if DocumentScanner.isSupported, !openedCamera {
                    openedCamera = true
                    camera = true
                }
            }
            .onDisappear { model.formSheet(sheetToken, open: false) }
        }
        .tint(Palette.accent)
        .interactiveDismissDisabled(isSending)
    }

    private var isSending: Bool {
        if case .sending = phase { return true }
        return false
    }

    // MARK: Phases

    @ViewBuilder private var idle: some View {
        if DocumentScanner.isSupported {
            Button { camera = true } label: {
                Label("Scan pages", systemImage: "doc.viewfinder").frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Scan needs a camera", systemImage: "camera.slash").font(.headline)
                Text("This device has no document camera. The simulator has none either.")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            }
        }
        if !DocumentScanner.isSupported || server.kind == .demo {
            Button {
                if let pdf = PageEncoder.samplePDF() { phase = .ready(pdf: pdf, pages: 1) }
            } label: {
                Text("Use a sample page").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func ready(pdf: Data, pages: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                stat(String(pages), pages == 1 ? "PAGE" : "PAGES")
                stat(Self.size(pdf.count), "SIZE")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("To \(server.name), into Paperless.").font(.footnote).foregroundStyle(Palette.secondary)
            Button { Task { await send(pdf, pages: pages) } } label: {
                Text("Send").frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if DocumentScanner.isSupported {
                Button { camera = true } label: { Text("Scan again").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Typo.mono(.title2, weight: .semibold))
            Text(label).font(Typo.mono(.caption2)).foregroundStyle(Palette.tertiary)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) { ProgressView(); Text(text).font(Typo.mono(.subheadline)) }
    }

    // MARK: Work

    /// The camera is done: every page becomes a small JPEG (off the main thread), the JPEGs one PDF.
    private func make(_ pages: ScannedPages) {
        camera = false
        guard !pages.images.isEmpty else { return }
        phase = .making
        Task {
            let made = await Task.detached(priority: .userInitiated) { () -> (Data, Int)? in
                let jpegs = pages.images.compactMap { PageEncoder.jpeg(from: $0) }
                guard let pdf = PDFWriter.pdf(jpegs: jpegs) else { return nil }
                return (pdf, jpegs.count)
            }.value
            if let made {
                phase = .ready(pdf: made.0, pages: made.1)
            } else {
                phase = .idle
                message = Message(title: "No PDF", text: "The pages couldn't be turned into a PDF. Scan again.", finishes: false)
            }
        }
    }

    private func send(_ pdf: Data, pages: Int) async {
        let item: ShareItem
        do {
            item = try ShareRouter.item(pdf: pdf, title: title)
        } catch let refusal as ShareRefusal {
            message = Message(title: "Can't send this", text: refusal.message, finishes: false)
            return
        } catch {
            return
        }
        phase = .sending(pdf.count)
        let result = await ShareSender.send(item, server: server, api: model.companion(for: server),
                                            features: model.selectedStatus.knownInfo?.features, outbox: model.outbox)
        model.outboxChanged()
        outcome = result
        switch result {
        case .sent(let text): message = Message(title: "Sent", text: text, finishes: true)
        case .queued: message = Message(title: "Saved", text: ShareOutcome.queuedText, finishes: true)
        case .failed(let text):
            phase = .ready(pdf: pdf, pages: pages)
            message = Message(title: "Not sent", text: text, finishes: false)
        }
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(1, bytes / 1024)) KB"
    }
}
