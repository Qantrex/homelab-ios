import HomelabKit
import SwiftUI
import UIKit

/// The share extension's principal class (Share-Info.plist: NSExtensionPrincipalClass = "ShareViewController").
/// The @objc name lets the runtime find it without the module prefix; Package.swift keeps it from being stripped.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let model = ShareModel()
        let host = UIHostingController(rootView: ShareView(model: model, cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }, done: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(items) }
    }
}
