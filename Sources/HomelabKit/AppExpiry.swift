import Foundation

/// When this install stops opening. A free Apple ID signs for 7 days (docs/SETUP.md); the date is in the app's own
/// `embedded.mobileprovision` (a signed blob with a plain XML plist inside). Nil for an App Store, TestFlight or
/// simulator build, which have no such file or no date.
public enum AppExpiry {
    /// Warn this long before the date: enough to plug the phone in on a normal day.
    public static let warnAhead: TimeInterval = 2 * 24 * 3600

    /// The `ExpirationDate` from a provisioning profile's bytes.
    public static func date(fromProfile data: Data) -> Date? {
        Provisioning.parse(data)?.expires
    }

    /// This install's date, read once.
    public static let current: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return date(fromProfile: data)
    }()

    /// The warning for Today, or nil while there is time: "Homelab stops opening in 2 days. …".
    public static func warning(expires: Date?, now: Date = Date()) -> String? {
        guard let expires, expires.timeIntervalSince(now) <= warnAhead else { return nil }
        let left = expires.timeIntervalSince(now)
        let when: String
        if left <= 0 { when = "has stopped opening" }   // shown only by a still-running app
        else if left < 24 * 3600 {
            let hours = max(1, Int(clamping: (left / 3600).rounded(.down)))
            when = hours == 1 ? "stops opening in 1 hour" : "stops opening in \(hours) hours"
        } else {
            let days = Int(clamping: (left / (24 * 3600)).rounded(.down))
            when = days == 1 ? "stops opening in 1 day" : "stops opening in \(days) days"
        }
        return "This install \(when) (free Apple ID, 7 days). Refresh it in SideStore, or reinstall it from the computer; your data stays."
    }
}
