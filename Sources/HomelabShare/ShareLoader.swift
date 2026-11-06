import Foundation
import HomelabKit
import UniformTypeIdentifiers

/// What the share sheet handed over, ready to send.
struct LoadedShare: Sendable {
    var item: ShareItem
    /// "3 photos, 1.2 MB" or the link's host: the second line of the screen.
    var detail: String
    /// The title field is offered (PDFs and photos; a link's title comes from the page).
    var editableTitle: Bool
}

/// The extension context's items. Read-only here, and handed to the loader once, so crossing to it is safe.
struct SharedItems: @unchecked Sendable {
    var items: [NSExtensionItem]
}

/// Reads the extension's input items. Order of preference: a PDF, photos (one PDF), a link, text with a link.
enum ShareLoader {
    static func load(_ input: SharedItems) async -> Result<LoadedShare, ShareRefusal> {
        let items = input.items
        let providers = items.flatMap { $0.attachments ?? [] }
        // Only the item's title. Its content text is never sent: some apps put the selected text, a whole note or a
        // message there, which the owner never sees in the share sheet.
        let pageTitle = items.compactMap { $0.attributedTitle?.string }.first

        if let pdf = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) {
            return await loadPDF(pdf)
        }
        // A web link wins over images: some apps (shops, willhaben) attach a preview picture next to the link, and that
        // must become a price check or read-later, not a photo PDF in Paperless. Photos never carry a web link (a file
        // URL doesn't count), so photo shares still end up below.
        if let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = await loadURL(link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return build { try ShareRouter.item(url: url, title: pageTitle) }
        }
        let images = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !images.isEmpty { return await loadImages(images) }

        if let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = await loadURL(link) {
            return build { try ShareRouter.item(url: url, title: pageTitle) }
        }
        if let text = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
           let string = await loadText(text) {
            return build { try ShareRouter.item(text: string, title: pageTitle) }
        }
        // Some apps only put the text into the item itself.
        if let text = items.compactMap({ $0.attributedContentText?.string }).first {
            return build { try ShareRouter.item(text: text, title: nil) }
        }
        return .failure(.nothing)
    }

    private static func build(_ make: () throws -> ShareItem) -> Result<LoadedShare, ShareRefusal> {
        do {
            let item = try make()
            guard case .url(let url, _) = item else { return .failure(.nothing) }
            return .success(LoadedShare(item: item, detail: url.host ?? url.absoluteString, editableTitle: false))
        } catch let e as ShareRefusal {
            return .failure(e)
        } catch {
            return .failure(.nothing)
        }
    }

    // MARK: Providers (callbacks wrapped, only Sendable values cross)

    private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                c.resume(returning: (item as? URL) ?? (item as? String).flatMap { URL(string: $0) })
            }
        }
    }

    private static func loadText(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                c.resume(returning: (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }

    private static func loadPDF(_ p: NSItemProvider) async -> Result<LoadedShare, ShareRefusal> {
        let name = p.suggestedName
        let read: Result<Data, ShareRefusal> = await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                guard let url else { c.resume(returning: .failure(.notPDF)); return }
                // Look at the size first: a huge file is never read into memory.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > ShareLimits.maxPDFBytes { c.resume(returning: .failure(.tooLarge(bytes: size))); return }
                guard let data = try? Data(contentsOf: url) else { c.resume(returning: .failure(.notPDF)); return }
                c.resume(returning: .success(data))
            }
        }
        switch read {
        case .failure(let e): return .failure(e)
        case .success(let data):
            let title = (name as NSString?)?.deletingPathExtension ?? ShareRouter.defaultScanTitle()
            do {
                let item = try ShareRouter.item(pdf: data, title: title)
                return .success(LoadedShare(item: item, detail: "PDF, \(Self.size(data.count))", editableTitle: true))
            } catch let e as ShareRefusal {
                return .failure(e)
            } catch {
                return .failure(.notPDF)
            }
        }
    }

    /// Photos become one PDF. One photo at a time is thumbnailed and compressed straight from its file.
    private static func loadImages(_ providers: [NSItemProvider]) async -> Result<LoadedShare, ShareRefusal> {
        guard providers.count <= ShareLimits.maxImages else { return .failure(.tooManyImages) }
        var pages: [Data] = []
        for p in providers {
            let jpeg: Data? = await withCheckedContinuation { c in
                _ = p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    c.resume(returning: url.flatMap { PageEncoder.jpeg(fileURL: $0) })
                }
            }
            if let jpeg { pages.append(jpeg) }
        }
        guard let pdf = PDFWriter.pdf(jpegs: pages) else { return .failure(.nothing) }
        let title = "Photos " + ShareRouter.defaultScanTitle().dropFirst("Scan ".count)
        do {
            let item = try ShareRouter.item(pdf: pdf, title: title)
            let count = pages.count == 1 ? "1 photo" : "\(pages.count) photos"
            return .success(LoadedShare(item: item, detail: "\(count) as one PDF, \(Self.size(pdf.count))", editableTitle: true))
        } catch let e as ShareRefusal {
            return .failure(e)
        } catch {
            return .failure(.nothing)
        }
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(1, bytes / 1024)) KB"
    }
}
