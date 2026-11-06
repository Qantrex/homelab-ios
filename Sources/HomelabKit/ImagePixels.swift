import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// How big a server's picture is once decoded. A 1 MB PNG or JPEG can declare 30000×30000 pixels: decoded that is
/// 3.6 GB, and the app (or the widget) dies. The size is read from the file's header before anything is cached or
/// decoded, and pictures past `maxShortSide`×`maxLongSide` are refused. Posters are then decoded as thumbnails at
/// display size (`thumbnail`), never at full size.
public enum ImagePixels {
    /// A poster is 2:3; 4000×6000 is far past any real one (w780 is 780×1170). Either orientation.
    public static let maxShortSide = 4000
    public static let maxLongSide = 6000

    /// Width and height. With ImageIO (iOS) from its reading of the file; elsewhere from the PNG, JPEG or WebP header
    /// (`headerSize`). Nil when it can't be read.
    public static func size(_ data: Data) -> (width: Int, height: Int)? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
        #else
        return headerSize(data)
        #endif
    }

    /// True when `data` is a JPEG, PNG or WebP whose size is known and within the limits.
    public static func isAcceptable(_ data: Data) -> Bool {
        guard ImageKind(sniffing: data) != nil, let s = size(data) else { return false }
        return fits(width: s.width, height: s.height)
    }

    public static func fits(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && Swift.min(width, height) <= maxShortSide && Swift.max(width, height) <= maxLongSide
    }

    /// The size the file's header declares, without decoding: PNG (IHDR), JPEG (the first start-of-frame segment)
    /// and WebP (VP8, VP8L, VP8X). Nil for anything else or a cut-off header.
    public static func headerSize(_ data: Data) -> (width: Int, height: Int)? {
        switch ImageKind(sniffing: data) {
        case .png: pngSize(data)
        case .jpeg: PDFWriter.jpegFrame(data).map { ($0.width, $0.height) }
        case .webp: webpSize(data)
        case nil: nil
        }
    }

    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(24))
        // Signature (8), then the first chunk must be IHDR: length (4), "IHDR", width and height big-endian.
        guard b.count == 24, b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52 else { return nil }
        let w = be32(b, 16), h = be32(b, 20)
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    static func webpSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(30))
        guard b.count >= 30 else { return nil }
        let chunk = String(decoding: b[12..<16], as: UTF8.self)
        switch chunk {
        case "VP8 ":
            // Frame tag (3), start code 9D 01 2A, then 14-bit width and height, little-endian.
            guard b[23] == 0x9D, b[24] == 0x01, b[25] == 0x2A else { return nil }
            return nonZero((Int(b[26]) | Int(b[27]) << 8) & 0x3FFF, (Int(b[28]) | Int(b[29]) << 8) & 0x3FFF)
        case "VP8L":
            // Signature 0x2F, then width-1 and height-1 in 14 bits each.
            guard b[20] == 0x2F else { return nil }
            let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
            return nonZero((bits & 0x3FFF) + 1, (bits >> 14 & 0x3FFF) + 1)
        case "VP8X":
            // Flags (1), reserved (3), canvas width-1 and height-1 in 24 bits each.
            return nonZero((Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16) + 1,
                           (Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16) + 1)
        default:
            return nil
        }
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func nonZero(_ w: Int, _ h: Int) -> (width: Int, height: Int)? {
        w > 0 && h > 0 ? (w, h) : nil
    }

    #if canImport(ImageIO)
    /// The picture decoded at most `maxPixel` on its long side (ImageIO's thumbnail path, which never holds the full
    /// bitmap), turned upright. Nil for a picture past the limits or one ImageIO can't read.
    public static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard isAcceptable(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Swift.max(maxPixel, 1),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    #endif
}
