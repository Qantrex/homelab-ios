import Foundation
import HomelabKit
import WidgetKit

public extension AppModel {
    /// The real app: shared storage, the Keychain, URLSession, and widget reloads.
    static func live() -> AppModel {
        let model = AppModel(storage: .shared(), tokens: KeychainTokenStore())
        model.onWidgetDataChange = { WidgetCenter.shared.reloadAllTimelines() }
        return model
    }
}
