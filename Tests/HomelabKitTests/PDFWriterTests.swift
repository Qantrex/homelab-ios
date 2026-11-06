import Foundation
import Testing
@testable import HomelabKit

@Suite struct PDFWriterTests {
    /// A JPEG skeleton: SOI, one start-of-frame segment, EOI. Enough for the writer, which never decodes it.
    func jpeg(width: Int, height: Int, components: Int = 3, marker: UInt8 = 0xC0) -> Data {
        var d: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46]   // SOI + a short APP0
        d += [0xFF, marker, 0x00, UInt8(8 + components * 3), 8,
              UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), UInt8(components)]
        for c in 0..<components { d += [UInt8(c + 1), 0x11, 0] }
        d += [0xFF, 0xD9]
        return Data(d)
    }

    @Test func readsTheFrameHeader() {
        let i = PDFWriter.jpegInfo(jpeg(width: 1500, height: 2000))
        #expect(i?.width == 1500 && i?.height == 2000 && i?.components == 3)
        #expect(PDFWriter.jpegInfo(jpeg(width: 300, height: 200, components: 1, marker: 0xC2))?.components == 1)
        #expect(PDFWriter.jpegInfo(jpeg(width: 10, height: 10, components: 4)) == nil)   // CMYK
        #expect(PDFWriter.jpegInfo(Data("not a jpeg".utf8)) == nil)
        #expect(PDFWriter.jpegInfo(Data()) == nil)
        #expect(PDFWriter.jpegInfo(Data([0xFF, 0xD8, 0xFF])) == nil)
    }

    @Test func buildsAValidStructure() throws {
        let pages = [jpeg(width: 1500, height: 2000), jpeg(width: 2000, height: 1000, components: 1)]
        let pdf = try #require(PDFWriter.pdf(jpegs: pages))
        let text = String(decoding: pdf, as: UTF8.self)
        #expect(pdf.starts(with: Data("%PDF-".utf8)))
        #expect(text.contains("/Count 2") && text.contains("/Kids [3 0 R 6 0 R]"))
        #expect(text.contains("/DeviceGray") && text.contains("/DeviceRGB") && text.contains("/DCTDecode"))
        #expect(text.contains("/MediaBox [0 0 595.00 842.00]") && text.contains("/MediaBox [0 0 842.00 595.00]"))
        #expect(text.hasSuffix("%%EOF\n"))
        // Every xref entry points at "<n> 0 obj".
        let startxref = try #require(text.range(of: "startxref\n"))
        let xrefOffset = try #require(Int(text[startxref.upperBound...].prefix(while: \.isNumber)))
        let tail = Array(pdf)
        let xrefLine = Data("xref\n".utf8)
        #expect(Data(tail[xrefOffset..<(xrefOffset + 5)]) == xrefLine)
        let entries = text[text.index(text.startIndex, offsetBy: 0)...].components(separatedBy: "\n").filter { $0.hasSuffix(" 00000 n ") }
        #expect(entries.count == 8)   // 2 + 3 per page
        for (i, line) in entries.enumerated() {
            let offset = try #require(Int(line.prefix(10)))
            #expect(Data(tail[offset..<min(tail.count, offset + 8)]).starts(with: Data("\(i + 1) 0 obj".utf8)))
        }
    }

    @Test func fitsThePageKeepingTheAspect() throws {
        let pdf = try #require(PDFWriter.pdf(jpegs: [jpeg(width: 842, height: 595)]))
        let text = String(decoding: pdf, as: UTF8.self)
        // Wider than tall: the landscape sheet (842 x 595), the image fills it.
        #expect(text.contains("q 842.00 0 0 595.00 0.00 0.00 cm /Im0 Do Q"))
    }

    @Test func refusesWhatItCannotWrite() {
        #expect(PDFWriter.pdf(jpegs: []) == nil)
        #expect(PDFWriter.pdf(jpegs: [Data("png".utf8)]) == nil)
    }
}
