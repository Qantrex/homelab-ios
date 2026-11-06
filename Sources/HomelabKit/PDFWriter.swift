import Foundation

/// Makes a PDF out of JPEG pages without decoding them: each page is one image (DCTDecode) fitted on an A4 sheet.
/// The share extension has little memory (~120 MB): a decoded 2000 px photo is 16 MB, a JPEG of it 300 KB. Foundation
/// only, so it is tested on Linux. The JPEGs come from `PageEncoder` (iOS).
public enum PDFWriter {
    /// Width, height and colour components (1 grey, 3 RGB) from the JPEG's start-of-frame segment.
    public static func jpegInfo(_ data: Data) -> (width: Int, height: Int, components: Int)? {
        let b = [UInt8](data.prefix(1 << 20))
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }   // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            // Baseline and progressive frames (not the DHT 0xC4, JPG 0xC8 and DAC 0xCC markers).
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard i + 9 < b.count else { return nil }
                let height = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let width = Int(b[i + 7]) << 8 | Int(b[i + 8])
                let components = Int(b[i + 9])
                guard width > 0, height > 0, components == 1 || components == 3 else { return nil }
                return (width, height, components)
            }
            if marker == 0xDA { return nil }   // image data before any frame header
            i += 2 + length
        }
        return nil
    }

    public static let a4 = (width: 595.0, height: 842.0)

    /// nil for no pages or a JPEG that isn't a baseline/progressive grey or RGB one.
    public static func pdf(jpegs: [Data]) -> Data? {
        guard !jpegs.isEmpty else { return nil }
        let infos = jpegs.compactMap(jpegInfo)
        guard infos.count == jpegs.count else { return nil }

        var out = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        func object(_ number: Int, _ body: Data) {
            offsets.append(out.count)
            out.append(Data("\(number) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        func text(_ s: String) -> Data { Data(s.utf8) }
        func n(_ v: Double) -> String { String(format: "%.2f", v) }

        // 1 catalog, 2 page tree, then three objects per page: page, content, image.
        object(1, text("<< /Type /Catalog /Pages 2 0 R >>"))
        let kids = (0..<jpegs.count).map { "\(3 + $0 * 3) 0 R" }.joined(separator: " ")
        object(2, text("<< /Type /Pages /Kids [\(kids)] /Count \(jpegs.count) >>"))
        for (index, jpeg) in jpegs.enumerated() {
            let info = infos[index]
            let landscape = info.width > info.height
            let (pageW, pageH) = landscape ? (a4.height, a4.width) : (a4.width, a4.height)
            let scale = min(pageW / Double(info.width), pageH / Double(info.height))
            let (w, h) = (Double(info.width) * scale, Double(info.height) * scale)
            let (x, y) = ((pageW - w) / 2, (pageH - h) / 2)
            let base = 3 + index * 3
            object(base, text("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(pageW)) \(n(pageH))] "
                              + "/Resources << /XObject << /Im0 \(base + 2) 0 R >> >> /Contents \(base + 1) 0 R >>"))
            let content = "q \(n(w)) 0 0 \(n(h)) \(n(x)) \(n(y)) cm /Im0 Do Q"
            object(base + 1, text("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"))
            var image = text("<< /Type /XObject /Subtype /Image /Width \(info.width) /Height \(info.height) "
                             + "/ColorSpace /\(info.components == 1 ? "DeviceGray" : "DeviceRGB") /BitsPerComponent 8 "
                             + "/Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n")
            image.append(jpeg)
            image.append(text("\nendstream"))
            object(base + 2, image)
        }

        let xref = out.count
        var table = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(text(table))
        return out
    }
}
