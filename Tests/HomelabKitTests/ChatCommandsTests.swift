import Foundation
import Testing
@testable import HomelabKit

/// The chat's "/" menu, the suggestions under a typed "/", and Clear on this phone.
@Suite struct ChatCommandsTests {
    private func info(_ json: String) throws -> ServerInfo {
        try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
    }

    @Test func theServersCommandsGetTheirLines() throws {
        let i = try info(#"{"api":1,"commands":["/pending","/last","/weird"]}"#)
        let list = ChatCommands.list(i)
        #expect(list.map(\.name) == ["/pending", "/last", "/weird"])            // the server's order, nothing added
        #expect(list[0].help == "Actions waiting for your answer" && !list[0].takesArgument)
        #expect(list[1].takesArgument && ChatCommands.pick(list[1]) == .fill("/last "))
        #expect(list[2].help == nil && ChatCommands.pick(list[2]) == .send("/weird"))   // unknown: shown as it is
        #expect(ChatCommands.list(nil).isEmpty)
    }

    @Test func aServerMaySayWhatItsCommandsDo() throws {
        let i = try info("""
        {"api":1,"commands":["/pending",{"command":"/status","description":"  How the lab is  "},
                             {"command":"/memory","description":""},{"description":"no command"},{"command":"rm -rf"},
                             {"command":"/long","description":"\(String(repeating: "x", count: 200))"},"/pending"]}
        """)
        #expect(i.commands == ["/pending", "/status", "/memory", "/long"])     // bad and repeated entries dropped
        let list = ChatCommands.list(i)
        #expect(list[1].help == "How the lab is")
        #expect(list[2].help == "What the agent remembers")                      // empty: the built-in line
        #expect(list[3].help?.count == 80)

        // A cached snapshot writes it back and reads it the same.
        let again = try JSONDecoder().decode(ServerInfo.self, from: JSONEncoder().encode(i))
        #expect(again == i)
        // A single string still counts as a list of one.
        #expect(try info(#"{"api":1,"commands":"/help"}"#).commands == ["/help"])
    }

    @Test func suggestionsFollowWhatIsTyped() throws {
        let list = ChatCommands.list(try info(#"{"api":1,"commands":["/pending","/last","/memory","/help"]}"#))
        #expect(ChatCommands.suggestions(for: "/", in: list).count == 4)
        #expect(ChatCommands.suggestions(for: "/PE", in: list).map(\.name) == ["/pending"])
        #expect(ChatCommands.suggestions(for: "/pending", in: list).isEmpty)    // finished
        #expect(ChatCommands.suggestions(for: "/last nas", in: list).isEmpty)   // typing its argument
        #expect(ChatCommands.suggestions(for: "hello /", in: list).isEmpty)
        #expect(ChatCommands.suggestions(for: "", in: list).isEmpty)
    }

    private func m(_ id: Int64, _ from: ChatMessage.Sender = .agent) -> ChatMessage {
        ChatMessage(id: id, from: from, text: "m\(id)")
    }

    @Test func clearHidesWhatIsShownAndPollsOnAfterIt() {
        var t = ChatTimeline()
        #expect(!t.canClear)
        t.merge(MessagePage(messages: [m(1), m(2, .me), m(3)]))
        let waiting = t.begin("still on its way")
        let failed = t.begin("didn't go")
        t.fail(failed, message: "offline")
        #expect(t.canClear)

        t.clear()
        #expect(t.messages.isEmpty && t.clearedThrough == 3 && t.cursor == 3)
        #expect(t.outgoing.map(\.id) == [waiting])                               // a send under way stays
        #expect(!t.canClear)

        // A late page with old messages doesn't bring them back; newer ones come in.
        t.merge(MessagePage(messages: [m(2), m(3), m(4)]))
        #expect(t.messages.map(\.id) == [4] && t.cursor == 4)

        // After a restart: the stored mark again, before the first load.
        var fresh = ChatTimeline()
        fresh.restore(clearedThrough: 3)
        #expect(fresh.cursor == 3)
        fresh.merge(MessagePage(messages: [m(1), m(4)]))
        #expect(fresh.messages.map(\.id) == [4])

        // "Show earlier messages": load from the start again.
        fresh.unclear()
        #expect(fresh.clearedThrough == 0 && fresh.cursor == 0 && fresh.messages.isEmpty)
        fresh.merge(MessagePage(messages: [m(1), m(4)]))
        #expect(fresh.messages.map(\.id) == [1, 4])

        // Another server: no mark.
        fresh.clear()
        fresh.reset()
        #expect(fresh.clearedThrough == 0)
    }

    @Test func clearMarksAreKeptPerServer() throws {
        var c = ChatClears()
        c.set(42, for: "a|companion|https://lab:443")
        c.set(7, for: "b")
        c.set(0, for: "b")
        #expect(c.mark(for: "a|companion|https://lab:443") == 42 && c.mark(for: "b") == 0 && c.through.count == 1)
        let again = try JSONDecoder().decode(ChatClears.self, from: JSONEncoder().encode(c))
        #expect(again == c)
    }
}
