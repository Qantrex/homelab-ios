import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HomelabKit

@Suite struct StartActionsTests {
    /// Fri 2026-11-06 15:00 in Vienna: "tomorrow" is the 7th.
    let now = Date(timeIntervalSince1970: 1_793_973_600)
    var vienna: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }

    func specs() throws -> [ActionSpec] { try fixture(ActionList.self, "actions.json").actions }
    func spec(_ name: String) throws -> ActionSpec { try #require(try specs().first { $0.name == name }) }
    func decode(_ json: String) throws -> [ActionSpec] { try JSONDecoder().decode(ActionList.self, from: Data(json.utf8)).actions }

    @Test func fixtureDecodes() throws {
        let list = try specs()
        #expect(list.map(\.name) == ["todo-add", "calendar-add", "wake-set", "commute-mode", "ha-control", "restart-container"])
        let todo = try spec("todo-add")
        #expect(todo.variants.isEmpty)
        #expect(todo.fields.map(\.name) == ["summary", "due", "description", "list"])
        #expect(todo.fields[0].required && todo.fields[0].max == 120)
        #expect(todo.fields[1].kind == .dateOrDatetime && !todo.fields[1].required)
        #expect(todo.fields[3].options.map(\.label) == ["To-dos", "Shopping"])
        let wake = try spec("wake-set")
        #expect(wake.variants.map(\.label) == ["Wake me", "No wake-up"])
        #expect(wake.variants[0].parts == [.date(label: "Day"), .literal("T"), .time(label: "Time")])
        #expect(try spec("restart-container").destructive)
        #expect(!todo.destructive)
    }

    @Test func roundTripsThroughTheCache() throws {
        let list = try specs()
        let again = try JSONDecoder().decode([ActionSpec].self, from: JSONEncoder().encode(list))
        #expect(again == list)
    }

    @Test func oddServersAreReadLeniently() throws {
        let list = try decode("""
        {"actions": [
          {"name": "a", "arg": [{"label": "x", "parts": [{"kind": "colour", "label": "C"}]},
                                {"label": "y", "parts": [{"kind": "word", "label": "W"}]}]},
          {"name": "b", "arg": [{"parts": [{"kind": "hologram"}]}]},
          {"name": "Bad Name"}, {"label": "no name"}, "not an object",
          {"name": "c", "fields": [{"name": "f", "kind": "hologram", "max": "50", "required": "yes"},
                                   {"name": "g", "kind": "choice"}, {"label": "no name"}, {"name": "f"}]},
          {"name": "a", "label": "duplicate"},
          {"name": "d", "arg": [], "fields": "nope", "destructive": "yes", "max": 99999}
        ]}
        """)
        #expect(list.map(\.name) == ["a", "c", "d"])
        // The variant with an unknown part is dropped, the other stays; the label defaults to the name.
        #expect(list[0].variants.map(\.label) == ["y"] && list[0].label == "a")
        // Unknown kind = text, number as text, "yes" = true, a choice without options = text, no duplicates.
        #expect(list[1].fields.map(\.name) == ["f", "g"])
        #expect(list[1].fields[0].kind == .text && list[1].fields[0].max == 50 && list[1].fields[0].required)
        #expect(list[1].fields[1].kind == .text)
        #expect(list[2].variants.isEmpty && list[2].fields.isEmpty && list[2].destructive)
    }

    @Test func formStartsWithSensiblePicks() throws {
        let form = ActionForm(try spec("wake-set"), now: now, calendar: vienna)
        #expect(form.value(part: 0) == "2026-11-07")
        #expect(form.value(part: 2) == "07:00")
        #expect(form.arg == "2026-11-07T07:00")
        #expect(form.isReady)
        let commute = ActionForm(try spec("commute-mode"), now: now, calendar: vienna)
        #expect(commute.arg == "2026-11-07:bike")
    }

    @Test func variantsBuildTheirOwnArgument() throws {
        var form = ActionForm(try spec("wake-set"), now: now, calendar: vienna)
        form.set(part: 2, "06:45")
        #expect(form.arg == "2026-11-07T06:45")
        form.variant = 1
        #expect(form.arg == "2026-11-07:off")
        form.set(part: 0, "2026-11-09")
        #expect(form.arg == "2026-11-09:off")
        form.variant = 0   // the other variant kept its own values
        #expect(form.arg == "2026-11-07T06:45")
        form.variant = 7
        #expect(form.variant == 1)
    }

    @Test func badPartsBlockTheArgument() throws {
        var form = ActionForm(try spec("restart-container"), now: now, calendar: vienna)
        #expect(form.arg == nil)
        #expect(form.problems == ["Container is missing."])
        form.set(part: 2, "sonarr; rm")
        #expect(form.arg == nil)
        #expect(form.problems == ["Container: only letters, digits, . _ and -."])
        form.set(part: 2, " sonarr ")
        #expect(form.arg == "nas:sonarr")
        form.set(part: 0, "evil")
        #expect(form.arg == nil && form.problems == ["Host: pick one of the options."])
        var wake = ActionForm(try spec("wake-set"), now: now, calendar: vienna)
        wake.set(part: 2, "7:5")
        #expect(wake.arg == nil && wake.problems == ["Time: pick a time."])
    }

    @Test func payloadIsTrimmedAndChecked() throws {
        var form = ActionForm(try spec("todo-add"), now: now, calendar: vienna)
        #expect(form.problems == ["To-do is missing."])
        #expect(form.arg == "")
        form.fieldValues["summary"] = "  Milk \n"
        form.fieldValues["description"] = "   "
        #expect(form.payload == ["summary": "Milk"])
        #expect(form.isReady)
        form.fieldValues["due"] = "2026-11-07"
        #expect(form.problems.isEmpty)
        form.fieldValues["due"] = "2026-11-07T08:00"
        #expect(form.problems.isEmpty)
        form.fieldValues["due"] = "tomorrow"
        #expect(form.problems == ["Due must be a day or a time."])
        form.fieldValues["due"] = nil
        form.fieldValues["list"] = "garden"
        #expect(form.problems == ["List: pick one of the options."])
        form.fieldValues["list"] = "shopping"
        form.fieldValues["summary"] = String(repeating: "x", count: 121)
        #expect(form.problems == ["To-do is longer than 120 characters."])
    }

    @Test func numberAndRequiredDayFields() throws {
        var form = ActionForm(try spec("calendar-add"), now: now, calendar: vienna)
        #expect(form.fieldValues == ["start": "2026-11-07"])   // a required day starts at tomorrow
        #expect(form.problems == ["Title is missing."])
        form.fieldValues["title"] = "Dentist"
        form.fieldValues["start"] = "2026-11-10T15:00"
        form.fieldValues["duration_min"] = "4x"
        #expect(form.problems == ["Minutes must be a whole number."])
        form.fieldValues["duration_min"] = "45"
        #expect(form.isReady)
        #expect(form.payload == ["title": "Dentist", "start": "2026-11-10T15:00", "duration_min": "45"])
    }

    @Test func summaryUsesLabels() throws {
        var form = ActionForm(try spec("commute-mode"), now: now, calendar: vienna)
        form.set(part: 2, "u6")
        #expect(form.summary.map { "\($0.label)=\($0.value)" } == ["Day=2026-11-07", "Way=U6"])
        var wake = ActionForm(try spec("wake-set"), now: now, calendar: vienna)
        wake.variant = 1
        #expect(wake.summary.map { "\($0.label)=\($0.value)" } == ["=No wake-up", "Day=2026-11-07"])
        var todo = ActionForm(try spec("todo-add"), now: now, calendar: vienna)
        todo.fieldValues = ["summary": "Milk", "list": "shopping"]
        #expect(todo.summary.map { "\($0.label)=\($0.value)" } == ["To-do=Milk", "List=Shopping"])
    }

    @Test func fieldDefaults() throws {
        let at = Date(timeIntervalSince1970: 1_793_975_400)   // 15:30 Vienna
        func d(_ kind: ActionSpec.Field.Kind) -> String? {
            ActionForm.defaultValue(.init(name: "x", kind: kind, options: [.init(value: "a")]), now: at, calendar: vienna)
        }
        #expect(d(.date) == "2026-11-07" && d(.dateOrDatetime) == "2026-11-07")
        #expect(d(.datetime) == "2026-11-06T16:00")
        #expect(d(.choice) == "a" && d(.text) == nil && d(.number) == nil)
    }

    @Test func datesAsTheServerReadsThem() throws {
        let d = try #require(ActionForm.date("2026-11-07T08:05", calendar: vienna))
        #expect(ActionForm.dayTime(d, calendar: vienna) == "2026-11-07T08:05")
        #expect(ActionForm.day(d, calendar: vienna) == "2026-11-07")
        #expect(ActionForm.time(d, calendar: vienna) == "08:05")
        let day = try #require(ActionForm.date("2026-11-07", calendar: vienna))
        #expect(ActionForm.dayTime(day, calendar: vienna) == "2026-11-07T00:00")
        let t = try #require(ActionForm.date("21:30", calendar: vienna))
        #expect(ActionForm.time(t, calendar: vienna) == "21:30")
        #expect(ActionForm.date("tomorrow") == nil)
        #expect(ActionForm.date("2026-11-07T8") == nil)
    }

    @Test func clientListsActions() async throws {
        let t = FakeTransport(fixture: "actions.json")
        let list = try await CompanionClient(baseURL: base, token: nil, transport: t).actions()
        #expect(list.count == 6)
        #expect(t.last?.url?.absoluteString == "https://homelab.example.ts.net/api/v1/actions")
    }

    @Test func clientRunsAnAction() async throws {
        let t = FakeTransport(json: #"{"ok": true, "text": "Done: todo-add\nadded"}"#)
        let r = try await CompanionClient(baseURL: base, token: nil, transport: t)
            .run("todo-add", arg: "", payload: ["summary": "Milk"])
        #expect(r == ActionResult(ok: true, text: "Done: todo-add\nadded"))
        let req = try #require(t.last)
        #expect(req.url?.absoluteString == "https://homelab.example.ts.net/api/v1/actions/todo-add")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Origin") == nil)
        let body = try #require(req.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["arg"] as? String == "")
        #expect(body["payload"] as? [String: String] == ["summary": "Milk"])
    }

    @Test func clientResultsAndErrors() async throws {
        let running = FakeTransport(json: #"{"ok": true, "running": "yes", "text": "Still running."}"#)
        #expect(try await CompanionClient(baseURL: base, token: nil, transport: running).run("a", arg: "", payload: [:]).running)
        let failed = FakeTransport(json: #"{"ok": false, "text": "Failed (exit 4): a"}"#)
        #expect(try await CompanionClient(baseURL: base, token: nil, transport: failed).run("a", arg: "", payload: [:]).ok == false)
        let empty = FakeTransport(json: "{}")
        #expect(try await CompanionClient(baseURL: base, token: nil, transport: empty).run("a", arg: "", payload: [:])
            == ActionResult(ok: true, text: "Done."))
        let refused = FakeTransport(status: 400, json: #"{"error": "payload is missing title"}"#)
        await #expect(throws: APIError.badRequest("payload is missing title")) {
            try await CompanionClient(baseURL: base, token: nil, transport: refused).run("a", arg: "", payload: [:])
        }
        let limit = FakeTransport(status: 429, json: #"{"error": "too many"}"#)
        await #expect(throws: APIError.tooManyRequests) {
            try await CompanionClient(baseURL: base, token: nil, transport: limit).run("a", arg: "", payload: [:])
        }
        // A name the server can't have never leaves the phone.
        let never = FakeTransport(json: "{}")
        await #expect(throws: APIError.badRequest("No such action.")) {
            try await CompanionClient(baseURL: base, token: nil, transport: never).run("../state", arg: "", payload: [:])
        }
        #expect(never.requests.isEmpty)
    }

    @Test func infoKnowsRunActions() throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"api": 1, "features": ["actions", "run-actions"]}"#.utf8))
        #expect(info.features == [.actions, .runActions])
    }

    @Test func demoRunsAndTellsTheChat() async throws {
        let demo = DemoBackend(delay: .zero)
        #expect(try await demo.actions().count == 6)
        let r = try await demo.run("ha-control", arg: "lamps-on", payload: [:])
        #expect(r.ok && r.text.contains("Living room"))
        let msgs = try await demo.messages(after: 0).messages.suffix(2)
        #expect(msgs.first?.text == "Living room: lamps-on" && msgs.last?.job == "action")
        await #expect(throws: APIError.notFound) { try await demo.run("nope", arg: "", payload: [:]) }
    }
}
