import Foundation
import Testing
@testable import SpikeShared

@Suite struct AppGroupTests {
    @Test func teamSuffixFromSideStoreBundleIDs() {
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.AB12CD34EF") == "AB12CD34EF")
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.AB12CD34EF.HomelabWidget") == "AB12CD34EF")
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab") == nil)               // xtool/Xcode, no rewrite
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.HomelabWidget") == nil) // not a team ID
        #expect(AppGroup.teamSuffix(bundleID: "com.qantrex.homelab.ab12cd34ef") == nil)    // team IDs are uppercase
        #expect(AppGroup.teamSuffix(bundleID: "com.other.app.AB12CD34EF") == nil)
    }

    @Test func candidatesPutProvisionedFirstWithoutDuplicates() {
        let c = AppGroup.candidates(bundleID: "com.qantrex.homelab.AB12CD34EF.HomelabWidget",
                                    provisioned: ["group.com.qantrex.homelab.AB12CD34EF"])
        #expect(c == ["group.com.qantrex.homelab.AB12CD34EF", "group.com.qantrex.homelab"])
    }

    @Test func candidatesWithoutRewrite() {
        #expect(AppGroup.candidates(bundleID: "com.qantrex.homelab") == ["group.com.qantrex.homelab"])
    }

    @Test func probeOnLinuxFindsNoContainer() {
        let p = AppGroup.probe(["group.com.qantrex.homelab"])
        #expect(p.count == 1)
        #if !canImport(Darwin)
        #expect(p[0].containerFound == false)
        #endif
    }
}

@Suite struct ProvisioningTests {
    @Test func parsesTheXMLInsideTheCMSBlob() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Name</key><string>SideStore profile</string>
          <key>TeamIdentifier</key><array><string>AB12CD34EF</string></array>
          <key>ExpirationDate</key><date>2026-11-11T20:00:00Z</date>
          <key>Entitlements</key><dict>
            <key>com.apple.security.application-groups</key>
            <array><string>group.com.qantrex.homelab.AB12CD34EF</string></array>
          </dict>
        </dict></plist>
        """
        var blob = Data([0x30, 0x82, 0x01, 0x02, 0xFF, 0x00])   // fake CMS header bytes around the plist
        blob.append(Data(xml.utf8))
        blob.append(Data([0x00, 0xA0, 0x82]))
        let p = try #require(Provisioning.parse(blob))
        #expect(p.name == "SideStore profile")
        #expect(p.teamIDs == ["AB12CD34EF"])
        #expect(p.appGroups == ["group.com.qantrex.homelab.AB12CD34EF"])
        #expect(p.expires != nil)
    }

    @Test func garbageGivesNil() {
        #expect(Provisioning.parse(Data("not a profile".utf8)) == nil)
    }
}

@Suite struct StoreTests {
    @Test func roundTripsWithoutAGroup() throws {
        let before = SpikeStore.load(group: nil)
        let after = SpikeStore.update(group: nil) { $0.counter += 1; $0.probeURL = "https://x.example/api/state" }
        #expect(after.counter == before.counter + 1)
        #expect(SpikeStore.load(group: nil) == after)
    }
}

@Suite struct NetworkProbeTests {
    @Test func rejectsNonHTTP() async {
        let r = await NetworkProbe.run("ftp://example.com/x")
        #expect(r.error == "not an http(s) URL")
        #expect(await NetworkProbe.run("").error != nil)
    }

    @Test func reportsConnectionErrorsInsteadOfThrowing() async {
        let r = await NetworkProbe.run("http://127.0.0.1:9/nothing", timeout: 3)   // port 9: discard, closed
        #expect(r.status == nil && r.error != nil)
    }
}
