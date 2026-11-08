import Foundation

/// SideStore re-signs the app with a free Apple ID. It changes the bundle ID to `<base>.<TEAMID>` (and the widget to
/// `<base>.<TEAMID>.HomelabWidget`) and rewrites App Group IDs. So the app never hard-codes its group: it tries the
/// likely candidates and uses the first one the system actually grants (Settings → Advanced → Diagnostics shows them all).
public enum AppGroup {
    public static let baseBundleID = "com.qantrex.homelab"
    public static let declaredGroup = "group.com.qantrex.homelab"

    /// The 10-character team ID SideStore appended to the bundle ID, if any.
    public static func teamSuffix(bundleID: String, base: String = baseBundleID) -> String? {
        guard bundleID.hasPrefix(base + ".") else { return nil }
        let rest = bundleID.dropFirst(base.count + 1)
        guard let first = rest.split(separator: ".").first, first.count == 10,
              first.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return String(first)
    }

    /// Candidate group IDs, most likely first, without duplicates. `provisioned` = the groups listed in the bundle's
    /// embedded.mobileprovision (the strongest hint: that is what Apple actually granted).
    public static func candidates(bundleID: String, provisioned: [String] = [],
                                  base: String = baseBundleID, declared: String = declaredGroup) -> [String] {
        var out = provisioned
        if let team = teamSuffix(bundleID: bundleID, base: base) {
            // SideStore's two rules ("<group>.<TEAM>" and "group.<rewritten bundle ID>") give the same string here.
            out.append(declared + "." + team)
        }
        out.append(declared)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Result of probing one candidate on the device.
    public struct Probe: Sendable, Codable {
        public var group: String
        public var containerFound: Bool
        public var writable: Bool
    }

    /// Tries each candidate: is there a container, and can we write a file in it?
    public static func probe(_ groups: [String]) -> [Probe] {
        groups.map { group in
            guard let url = containerURL(group) else {
                return Probe(group: group, containerFound: false, writable: false)
            }
            let test = url.appendingPathComponent(".write-test")
            let ok = (try? Data("ok".utf8).write(to: test, options: .atomic)) != nil
            try? FileManager.default.removeItem(at: test)
            return Probe(group: group, containerFound: true, writable: ok)
        }
    }

    /// The first candidate that is found and writable.
    public static func resolve(bundle: Bundle = .main) -> (group: String?, probes: [Probe]) {
        let provisioned = Provisioning.read(bundle: bundle)?.appGroups ?? []
        let probes = probe(candidates(bundleID: bundle.bundleIdentifier ?? "", provisioned: provisioned))
        return (probes.first { $0.containerFound && $0.writable }?.group, probes)
    }

    /// Resolved once per process (it touches the file system).
    public static let current: String? = resolve().group

    public static func containerURL(_ group: String) -> URL? {
        #if canImport(Darwin)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        #else
        return nil
        #endif
    }
}

/// The parts of embedded.mobileprovision the spike cares about. The file is a CMS blob with an XML plist inside.
public struct Provisioning: Sendable, Codable {
    public var name: String?
    public var teamIDs: [String]
    public var appGroups: [String]
    public var expires: Date?

    public static func read(bundle: Bundle = .main) -> Provisioning? {
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Provisioning? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            return nil
        }
        let ent = plist["Entitlements"] as? [String: Any] ?? [:]
        return Provisioning(name: plist["Name"] as? String,
                            teamIDs: plist["TeamIdentifier"] as? [String] ?? [],
                            appGroups: ent["com.apple.security.application-groups"] as? [String] ?? [],
                            expires: plist["ExpirationDate"] as? Date)
    }
}
