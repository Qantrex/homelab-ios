import Foundation
import Testing
@testable import HomelabKit

/// Settings → Test section and the server's `"test": true` actions (shown under Test on the Actions tab).
struct TestSectionTests {
    @Test func testFlagDecodesAndRoundTrips() throws {
        let json = #"[{"name":"morning-voice","label":"Morning message","test":true},{"name":"todo-add"},"#
            + #"{"name":"card","start":false,"test":true}]"#
        let specs = try JSONDecoder().decode([ActionSpec].self, from: Data(json.utf8))
        #expect(specs.map(\.test) == [true, false, true])
        #expect(specs.map(\.startTile) == [false, true, false])
        #expect(specs.map(\.testTile) == [true, false, false])   // start: false wins: a card-only action is no tile at all
        let again = try JSONDecoder().decode([ActionSpec].self, from: JSONEncoder().encode(specs))
        #expect(again == specs)
        // An action without the key encodes as before (no "test").
        let plain = String(decoding: try JSONEncoder().encode(ActionSpec(name: "a")), as: UTF8.self)
        #expect(!plain.contains("test"))
    }

    @Test func testsStayOutOfTheWidget() {
        var u = ActionUsage()
        u.setOffered([ActionSpec(name: "a"), ActionSpec(name: "t", test: true)], server: UUID())
        #expect(u.offered.values.flatMap { $0 }.map(\.name) == ["a"])
    }

    @Test func settingIsOffByDefaultAndOmittedWhenOff() throws {
        var s = AppSettings()
        #expect(!s.testsOn && s.testSection == nil)
        let off = String(decoding: try Storage.encoder.encode(s), as: UTF8.self)
        #expect(!off.contains("testSection"))
        s.testsOn = true
        let back = try JSONDecoder().decode(AppSettings.self, from: Storage.encoder.encode(s))
        #expect(back.testsOn)
        s.testsOn = false
        #expect(s == AppSettings())
        // A hand-edited false reads as off and is dropped, like the other default-off switches.
        let edited = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"testSection":false}"#.utf8))
        #expect(edited.testSection == nil)
    }
}
