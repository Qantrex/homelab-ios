import HomelabKit
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// The scanned pages, handed from the camera to the code that makes the PDF. The images are never changed after
/// the scanner made them, so crossing to another task is safe.
struct ScannedPages: @unchecked Sendable {
    var images: [CGImage]
}

#if os(iOS)
/// VisionKit's document camera in SwiftUI. It finds the page edges, flattens and cleans the pages itself.
struct DocumentScanner: UIViewControllerRepresentable {
    var onPages: (ScannedPages) -> Void
    var onCancel: () -> Void

    /// False on the simulator and on devices without a camera.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // Main-actor class with a preconcurrency conformance: the delegate methods arrive on the main thread.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var images: [CGImage] = []
            for i in 0..<scan.pageCount {
                if let cg = Self.upright(scan.imageOfPage(at: i)) { images.append(cg) }
            }
            parent.onPages(ScannedPages(images: images))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            parent.onCancel()
        }

        /// The page's pixels in reading order (VisionKit's pages are upright; a rotated one is drawn upright).
        static func upright(_ image: UIImage) -> CGImage? {
            guard image.imageOrientation != .up || image.cgImage == nil else { return image.cgImage }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }.cgImage
        }
    }
}
#else
struct DocumentScanner {
    static var isSupported: Bool { false }
}
#endif
