import Foundation
import Testing
@testable import HomelabKit

/// Settings → Data: "Show data from" and "Home tiles from".
@Suite struct ServerListTests {
    @Test func homeTilesComeFromTheChosenHomeAssistant() throws {
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: URL(string: "https://lab.ts.net")!, auth: .identity)
        let ha1 = ServerConfig(name: "HA", kind: .homeAssistant, baseURL: URL(string: "https://ha.ts.net")!, auth: .token)
        let ha2 = ServerConfig(name: "HA 2", kind: .homeAssistant, baseURL: URL(string: "https://ha2.ts.net")!, auth: .token)
        var list = ServerList(servers: [lab, ha1, ha2])
        #expect(list.homeAssistant?.id == ha1.id)                                // nothing chosen: the first
        list.home = ha2.id
        #expect(list.homeAssistant?.id == ha2.id)
        list.remove(ha2.id)
        #expect(list.home == nil && list.homeAssistant?.id == ha1.id)

        // An older servers.json without "home" still reads.
        let old = #"{"servers":[],"selected":null}"#
        #expect(try JSONDecoder().decode(ServerList.self, from: Data(old.utf8)).home == nil)
    }
}
