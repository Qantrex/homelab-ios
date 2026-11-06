import Foundation
import Testing
@testable import HomelabKit

// Fixes from the security review of 2026-11-06 (its probe tests, turned into real ones).

/// Picture sizes are read from the header before anything is cached or decoded.
struct ImagePixelTests {
    static func png(width: UInt32, height: UInt32) -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13) + Array("IHDR".utf8) + be(width) + be(height)
                    + [8, 2, 0, 0, 0] + [0, 0, 0, 0])
    }

    static func jpeg(width: Int, height: Int) -> Data {
        // SOI, an APP0 segment, then SOF0 (length 17, precision 8, height, width, 3 components).
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        let sof: [UInt8] = [0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(height >> 8), UInt8(height & 0xFF),
                            UInt8(width >> 8), UInt8(width & 0xFF), 0x03] + [UInt8](repeating: 0, count: 9)
        return Data([0xFF, 0xD8] + app0 + sof + [0xFF, 0xD9])
    }

    static func webp(_ chunk: String, _ payload: [UInt8]) -> Data {
        Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + Array(chunk.utf8) + [0, 0, 0, 0] + payload
             + [UInt8](repeating: 0, count: 16))
    }

    @Test func headerParser() {
        #expect(ImagePixels.headerSize(Self.png(width: 342, height: 513))! == (342, 513))
        #expect(ImagePixels.headerSize(Self.png(width: 30000, height: 30000))! == (30000, 30000))
        #expect(ImagePixels.headerSize(PlaceholderPoster.png(seed: "a"))! == (PlaceholderPoster.width, PlaceholderPoster.height))
        #expect(ImagePixels.headerSize(Self.jpeg(width: 780, height: 1170))! == (780, 1170))
        #expect(ImagePixels.headerSize(Self.jpeg(width: 65000, height: 65000))! == (65000, 65000))
        // VP8: frame tag, start code, 14-bit sizes. VP8L: signature, (w-1, h-1) in 14 bits. VP8X: 24-bit (w-1, h-1).
        #expect(ImagePixels.headerSize(Self.webp("VP8 ", [0, 0, 0, 0x9D, 0x01, 0x2A, 0x56, 0x01, 0x01, 0x02]))! == (342, 513))
        let w = 341, h = 512, bits = w | h << 14
        #expect(ImagePixels.headerSize(Self.webp("VP8L", [0x2F, UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF),
                                                          UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]))! == (342, 513))
        #expect(ImagePixels.headerSize(Self.webp("VP8X", [0, 0, 0, 0, 0x2F, 0x75, 0x00, 0x2F, 0x75, 0x00]))! == (30000, 30000))
        // Cut off, zero sized or not a picture.
        #expect(ImagePixels.headerSize(Self.png(width: 342, height: 513).prefix(20)) == nil)
        #expect(ImagePixels.headerSize(Self.png(width: 0, height: 513)) == nil)
        #expect(ImagePixels.headerSize(Self.jpeg(width: 780, height: 0)) == nil)
        #expect(ImagePixels.headerSize(Data([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])) == nil)
        #expect(ImagePixels.headerSize(Data("<html>".utf8)) == nil)
    }

    @Test func limits() {
        #expect(ImagePixels.fits(width: 4000, height: 6000) && ImagePixels.fits(width: 6000, height: 4000))
        #expect(!ImagePixels.fits(width: 4001, height: 6000) && !ImagePixels.fits(width: 100, height: 6001))
        #expect(!ImagePixels.fits(width: 0, height: 10))
        #expect(ImagePixels.isAcceptable(Self.png(width: 342, height: 513)))
        #expect(!ImagePixels.isAcceptable(Self.png(width: 30000, height: 30000)))
        #expect(!ImagePixels.isAcceptable(Self.jpeg(width: 65000, height: 65000)))
        #expect(!ImagePixels.isAcceptable(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))   // no size: refused
    }

    @Test func loaderNeverKeepsAHugePicture() async throws {
        let bomb = Self.png(width: 30000, height: 30000)
        let t = FakeTransport { r in
            .init(body: r.url?.path.contains("bomb") == true ? bomb : PlaceholderPoster.png(seed: "a"),
                  headers: ["Content-Type": "image/png"])
        }
        let dir = temporaryDirectory().appendingPathComponent("images")
        let l = ImageLoader(api: CompanionClient(baseURL: base, token: nil, transport: t), scope: "s", directory: dir)
        #expect(await l.data(for: "/api/v1/poster/bomb.png") == nil)
        #expect(await l.data(for: "/api/v1/poster/fine.png") != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        // A huge one already on disk (an older version cached it) is not served either.
        let planted = dir.appendingPathComponent(ImageLoader.fileName("s|/api/v1/poster/old.png"))
        try bomb.write(to: planted)
        let l2 = ImageLoader(api: CompanionClient(baseURL: base, token: nil, transport: FakeTransport(status: 404, json: "{}")),
                             scope: "s", directory: dir)
        #expect(await l2.data(for: "/api/v1/poster/old.png") == nil)
    }
}
