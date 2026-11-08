import HomelabDesign
import HomelabKit
import SwiftUI

/// Scan a document with the camera, check it, and send it to the server's document inbox (Paperless) (`POST /documents`).
/// Where the server can't be reached the PDF waits in the outbox and the app sends it later.
struct ScanView: View {
    let model: AppModel
    let server: ServerConfig
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case idle
        case making
        /// `id` is made with the PDF, so a second tap or a resend of the same scan can't file it twice.
        case ready(pdf: Data, pages: Int, id: String)
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
                VStack(alignment: .leading, spacing: Space.section) {
                    switch phase {
                    case .idle: idle
                    case .making: progress("Making the PDF…")
                    case .ready(let pdf, let pages, let id): ready(pdf: pdf, pages: pages, id: id)
                    case .sending(let bytes): progress("Sending \(Self.size(bytes))…")
                    }
                }
                .padding(16)
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
        .labeledContentStyle(.adaptive)
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
                if let pdf = PageEncoder.samplePDF() { phase = .ready(pdf: pdf, pages: 1, id: UUID().uuidString.lowercased()) }
            } label: {
                Text("Use a sample page").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func ready(pdf: Data, pages: Int, id: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                stat(String(pages), pages == 1 ? "Page" : "Pages")
                    .accessibilityLabel(pages == 1 ? Text("1 page") : Text("\(pages) pages"))
                stat(Self.size(pdf.count), "Size")
                    .accessibilityLabel(Text("Size \(Self.size(pdf.count))"))
            }
            .panel()
            VStack(alignment: .leading, spacing: 8) {
                // The field's own label: VoiceOver reads it with the field.
                Text("Title").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                TextField("Title", text: $title)
                    .padding(12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(verbatim: ScanTarget.footnote(server: server.name, features: model.selectedStatus.knownInfo?.features)).font(.footnote).foregroundStyle(Palette.tertiary)
            }
            Button {
                guard !isSending else { return }
                phase = .sending(pdf.count)   // at once: a second tap in the same frame finds it sending
                Task { await send(pdf, pages: pages, id: id) }
            } label: {
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

    /// One number and its word; one VoiceOver element ("1 page"), the label is set by the caller.
    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Typo.data(.title2, weight: .semibold))
            Text(label).font(.footnote).foregroundStyle(Palette.tertiary)
        }
        .accessibilityElement(children: .ignore)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) { ProgressView(); Text(text).font(.subheadline).foregroundStyle(Palette.secondary) }
    }

    // MARK: Work

    /// The camera is done: every page becomes a small JPEG (off the main thread), the JPEGs one PDF.
    private func make(_ pages: ScannedPages) {
        camera = false
        guard pages.count > 0 else { return }
        phase = .making
        Task {
            // One page at a time, yielding between pages so the UI keeps drawing the progress.
            var jpegs: [Data] = []
            for i in 0..<pages.count {
                if let j = pages.jpeg(i) { jpegs.append(j) }
                await Task.yield()
            }
            let pageJPEGs = jpegs
            let made = await Task.detached(priority: .userInitiated) { () -> (Data, Int)? in
                guard let pdf = PDFWriter.pdf(jpegs: pageJPEGs) else { return nil }
                return (pdf, pageJPEGs.count)
            }.value
            if let made {
                phase = .ready(pdf: made.0, pages: made.1, id: UUID().uuidString.lowercased())
            } else {
                phase = .idle
                message = Message(title: "No PDF", text: "The pages couldn't be turned into a PDF. Scan again.", finishes: false)
            }
        }
    }

    private func send(_ pdf: Data, pages: Int, id: String) async {
        let item: ShareItem
        do {
            item = try ShareRouter.item(pdf: pdf, title: title)
        } catch let refusal as ShareRefusal {
            phase = .ready(pdf: pdf, pages: pages, id: id)
            message = Message(title: "Can't send this", text: refusal.message, finishes: false)
            return
        } catch {
            phase = .ready(pdf: pdf, pages: pages, id: id)
            return
        }
        let result = await ShareSender.send(item, id: id, server: server, api: model.companion(for: server),
                                            features: model.selectedStatus.knownInfo?.features, outbox: model.outbox)
        model.outboxChanged()
        outcome = result
        switch result {
        case .sent(let text): message = Message(title: "Sent", text: text, finishes: true)
        case .queued: message = Message(title: "Saved", text: ShareOutcome.queuedText, finishes: true)
        case .failed(let text):
            phase = .ready(pdf: pdf, pages: pages, id: id)
            message = Message(title: "Not sent", text: text, finishes: false)
        }
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(1, bytes / 1024)) KB"
    }
}
