#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns camera pages and photos into small JPEGs for `PDFWriter`: at most 2000 px on the long side, quality 0.6,
/// always RGB. One image at a time, so the share extension stays far below its memory limit.
public enum PageEncoder {
    public static let maxPixel = 2000
    public static let quality = 0.6

    /// A file (a shared photo, HEIC or JPEG or PNG) as a JPEG page. The file is never decoded at full size: ImageIO
    /// makes the thumbnail straight from the file and applies the photo's rotation.
    public static func jpeg(fileURL: URL, maxPixel: Int = maxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(from: thumb, maxPixel: maxPixel)
    }

    /// A decoded image (a scanned page) as a JPEG page, scaled down to `maxPixel` when larger.
    public static func jpeg(from image: CGImage, maxPixel: Int = maxPixel) -> Data? {
        let longSide = max(image.width, image.height)
        let scale = longSide > maxPixel ? Double(maxPixel) / Double(longSide) : 1
        let width = Int(clamping: Double(image.width) * scale, in: 1...maxPixel)
        let height = Int(clamping: Double(image.height) * scale, in: 1...maxPixel)
        // Redrawn into plain RGB (white behind transparent parts): no CMYK, grey or alpha JPEGs reach the PDF.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// A one-page sample document for the demo (and the simulator, which has no camera): a heading and grey lines.
    public static func samplePDF() -> Data? {
        let width = 1240, height = 1754   // A4 at 150 dpi
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 64, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                           kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "Sample scan" as CFString,
                                                                               attributes as CFDictionary))
        ctx.textPosition = CGPoint(x: 120, y: CGFloat(height) - 220)
        CTLineDraw(line, ctx)
        ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        for i in 0..<18 {
            let w = 1000 - (i % 4) * 130
            ctx.fill(CGRect(x: 120, y: CGFloat(height) - 380 - CGFloat(i) * 70, width: CGFloat(w), height: 22))
        }
        guard let image = ctx.makeImage(), let jpeg = jpeg(from: image) else { return nil }
        return PDFWriter.pdf(jpegs: [jpeg])
    }
}
#endif
