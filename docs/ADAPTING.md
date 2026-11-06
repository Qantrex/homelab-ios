# Adapting the app to your homelab

The app is built for one homelab (the owner's). If yours is similar, fork it, turn off what you don't have and add
what you need. This page lists the places to change, in order. It is written for you and for Claude working for
you (see [Prompt for Claude](#prompt-for-claude) at the end).

The app is still growing (more card styles, chat cards, item actions, Lab history). The places below stay the same.
Before you add a case to an enum, read the current one.

## What a module is

A module is one feature, in three parts:

| Part | Where | Example (Chat) |
|---|---|---|
| A server feature | `features` in `GET /api/v1/info`, plus its endpoint or fields | `chat`, `GET`/`POST /messages` |
| Logic and models | `Sources/HomelabKit` (Foundation only, tested on Linux) | `ChatTimeline.swift`, `MessagePage` in `Models.swift` |
| A screen, section or card | `Sources/HomelabUI` (thin SwiftUI views) | `ChatView.swift`, the Chat tab in `RootView.swift` |

The feature names are `ServerInfo.Feature` in `Sources/HomelabKit/Models.swift`. A server that leaves a feature out
gets no tab or section for it. `AppModel.availableTabs` (`Sources/HomelabKit/AppModel.swift`) and `RootView.tabs`
(`Sources/HomelabUI/RootView.swift`) decide which tabs show.

## The modules

| Module | Server feature | Kit (logic) | UI | How it is switched |
|---|---|---|---|---|
| Headline (mood) | `status` | `Mood.swift`, `Voice.swift` (personality) | `TodayView.swift` (top) | Always on. Personality: Settings, off by default |
| Day line | `cards` + a card with `id: "today"` | `DayTimeline.swift` | `TodayView.swift` (`DaySection`), `HomelabDesign/DayLine.swift`, Day widget | Settings → Today → "The day in numbers"; or send no `today` card |
| Cards | `cards` | `Card` in `Models.swift` | `CardView` in `LabView.swift`, Today's "Cards" section | Settings → Today → "Cards"; or leave out `cards` |
| Approvals (proposed actions) | `actions` | `PendingAction` in `Models.swift`, `Alerts.swift` | `ActionsView.swift`, Today's "Waiting for you" | Leave out `actions`; Settings → Today |
| Start actions | `run-actions` | `StartActions.swift` (`ActionSpec`, `ActionForm`) | `ActionsView.swift` ("Start"), `ActionFormView.swift` | Leave out `run-actions`, or list no actions |
| Chat | `chat` | `ChatTimeline.swift`; `commands` in `/info` | `ChatView.swift` | Leave out `chat` |
| Lab (hosts, problems) | `hosts` | `Host`, `Problem` in `Models.swift`, `Format.swift` | `LabView.swift` | Tab shows whenever a server is set |
| Machines (Overkill) | `hosts` | `TodayLayout.swift` (`Density`) | `MachineList` in `TodayView.swift` | Settings → Today → detail; section "Machines" |
| Service launcher | `services` | `Service` in `Models.swift` | `ServicesSection` in `LabView.swift` | Leave out `services` (or send an empty list) |
| Home Assistant tiles | – (a Home Assistant server in Settings) | `HomeAssistant.swift` | `HomeTiles.swift` | Don't add an HA server; or Settings → Today → "Home tiles" |
| Last report | `last_message` in `/state` | `Models.swift` | `TodayView.swift` (`lastReport`) | Settings → Today → "Last report" |
| Widgets (status, day, hosts) | the data above | `AppGroup.swift`, `Storage.swift` | `Sources/HomelabWidget/HomelabWidget.swift` | Remove from the `HomelabWidgets` bundle |
| Background check, notifications | `status`, `actions` | `Alerts.swift` | `HomelabUI/Background.swift`, `Sources/Homelab/HomelabApp.swift` | Settings, off by default |

Today's sections are `TodaySection` in `Sources/HomelabKit/TodayLayout.swift`; the views for them are the `switch` in
`TodayView.section(for:)`. Demo mode reads `Sources/HomelabKit/Fixtures/` (`info.json` lists the demo's features).

## Turn a module off

Start on the server. Change the app only if you want the code gone.

| Where | What to do | Code change |
|---|---|---|
| Server | Leave the feature out of `features` in `/info` (reference server: leave its config key out, see [REFERENCE_SERVER.md](REFERENCE_SERVER.md)) | None |
| Phone | Settings → Today: hide a section; Calm/Standard/Overkill picks how much shows | None |
| Demo | Remove the feature from `Fixtures/info.json`. Tests that expect it fail: fix or delete those | Fixture + tests |

To delete a module from the app:

| Kind | Remove |
|---|---|
| A tab | Its `Tab(...)` in `RootView.tabs`, its line in `AppModel.availableTabs`, the `AppTab` case (keep old names working in `AppTab.init(name:)`), the view file, its Kit file and tests, the tab in `TABS` in `scripts/sim-smoke`, its rows in `DeviceTest.md` |
| A Today section | The `TodaySection` case (stored layouts drop unknown names by themselves), its `case` in `TodayView.section(for:)`, the view, the expectations in `Tests/HomelabKitTests/TodayLayoutTests.swift` |
| A widget | Its line in `HomelabWidgets` (`HomelabWidget.swift`) and the widget struct |
| Home Assistant | `HomeTiles.swift`, the `.home` section, `HomeAssistant.swift` and its tests, the HA server type in Settings |

Then run `scripts/test-linux`.

## Add a module

In this order. The contract comes first; the app only follows it.

| # | Step | Files |
|---|---|---|
| 1 | Contract: the new feature name in the `features` enum, the new path or fields | `server/openapi.yaml`, `docs/API.md` (endpoint table, "What `/info` changes") |
| 2 | Feature name | `ServerInfo.Feature` in `Sources/HomelabKit/Models.swift` |
| 3 | Model with tolerant decoding: every field optional, unknown fields ignored, unknown enum values fall back, bad list items dropped. Use the helpers in `Lenient.swift` (`c.text`, `c.int`, `c.double`, `c.bool`, `c.date`, `c.strings`, `Lossy<T>`) | `Sources/HomelabKit/Models.swift` or a new `Sources/HomelabKit/<Name>.swift` |
| 4 | Client: a method on `CompanionAPI`, in `CompanionClient` and in `DemoBackend` | `CompanionClient.swift`, `Demo.swift` |
| 5 | Fetch and keep it: a field on `ServerStatus`, fetched only when the feature is there (copy how `services` and `actions` are fetched) | `Sources/HomelabKit/AppModel.swift` |
| 6 | Fixture: a normal one and an odd one (missing fields, unknown values). Add the feature to `info.json`. A new endpoint also needs a route in `FixtureApp` | `Sources/HomelabKit/Fixtures/<name>.json`, `server/reference_server.py`, `server/test_reference_server.py` |
| 7 | Tests: decoding (normal and odd), every decision the view would make, the client against the fixture server | `Tests/HomelabKitTests/<Name>Tests.swift`, `ClientTests.swift`, `IntegrationTests.swift` |
| 8 | UI, thin: a tab (`AppTab`, `availableTabs`, `RootView.tabs`) or a Today section (`TodaySection` + `title`, `TodayView.section(for:)`). Colours and fonts only from `HomelabDesign` (`Palette`, `Typo`, `Symbols`) | `Sources/HomelabUI/<Name>View.swift` |
| 9 | Screenshot in CI: a tab in `TABS` gets light, dark and XXL shots by itself; anything else gets a `scene` line with launch arguments. Update the numbered list at the top | `scripts/sim-smoke` |
| 10 | Phone check: a row with "Pass when" | `DeviceTest.md` |
| 11 | Users notice it: a line | `CHANGELOG.md`, the tab table in `README.md` |

Your server then has to send the feature and the data. The reference server only serves what the tests and demo
need; your own server or agent does the real work ([SERVER-SETUP.md](SERVER-SETUP.md), section "Your own server").

### A new card style

Often a card is enough, and a card needs no app change: a server sends `list`, `metrics` or `text` cards with any
content. Add a style only when none of those can show it.

| # | Step | Files |
|---|---|---|
| 1 | The style in the `style` enum, with what its `items` mean | `server/openapi.yaml`, "How the app shows cards" in `docs/API.md` |
| 2 | A case in `Card.Style`. Unknown styles fall back to `list`, so send `items` that still read as a list in older apps | `Sources/HomelabKit/Models.swift` |
| 3 | Any logic (sorting, parsing values) in Kit, with tests | `Sources/HomelabKit/<Style>.swift`, `Tests/HomelabKitTests/` |
| 4 | A case in the `switch card.style` of `CardView` | `Sources/HomelabUI/LabView.swift` |
| 5 | A card with the style in a new fixture (don't change one other tests rely on), and a sim-smoke shot of it | `Sources/HomelabKit/Fixtures/`, `scripts/sim-smoke` |

### A new action the app can start

No app change, as long as the form only needs the part and field kinds the app knows. The server lists the action in
`GET /actions` and runs it on `POST /actions/<name>` (shapes in [API.md](API.md), "Actions the app starts").

| Kinds the app knows | |
|---|---|
| Argument parts | `literal`, `date` (2026-11-07), `time` (07:30), `number`, `word` (`[A-Za-z0-9._-]`), `choice` |
| Payload fields | `text`, `multiline`, `date`, `datetime`, `date-or-datetime`, `number`, `choice` |

The owner's agent (not in this repo) keeps the list in one file, `chat/app-actions.json`. Each entry names an
executable action script; the payload fields come from that script's `# payload:` line, and the file only adds labels
and kinds. The server builds the form description and a check from the templates. A made-up example:

```json
{"actions": [
  {"name": "restart-container", "label": "Restart a container", "icon": "arrow.clockwise", "destructive": true,
   "hint": "Only containers on the host's restart list.",
   "arg": [{"label": "Container", "template": "{Host: nas|media}:{Container: word}"}]},
  {"name": "todo-add", "label": "Add a to-do", "icon": "checklist",
   "fields": {"summary": {"label": "To-do"}, "due": {"label": "Due", "kind": "date-or-datetime"}}}
]}
```

| Key | Meaning |
|---|---|
| `name` | The action; the server runs only names on this list |
| `label`, `icon`, `hint` | Tile text, SF Symbol name, one line under the form |
| `destructive` | Red confirm button |
| `arg` | Variants; each `template` is literal text and `{Label: kind}` parts, a choice as `{Label: a=Text\|b=Text}` |
| `fields` | Per payload field: `label`, `kind`, `options` for a choice, `hidden` to keep an optional field out of the form |

The server must check the argument and payload again: the form only stops obviously wrong input. For the demo and
the CI shots, add the action to `Sources/HomelabKit/Fixtures/actions.json` (already in the expanded shape the API
sends). A new part or field kind needs app code: `StartActions.swift` (with tests in `StartActionsTests.swift`) and
`ActionFormView.swift`.

## Rules to keep

| Rule | Check |
|---|---|
| True black and monochrome: white and grey type, mono numbers. **No blue.** Rosé Pine only for status: love = problem, gold = warning, iris = links | Use `Palette` and `Tint.color` in `HomelabDesign/Theme.swift`, never your own colours |
| Tolerant decoding: an odd server never crashes the app or hides the rest | An odd fixture and a test for every new model |
| Logic in `HomelabKit` (Foundation only), views thin | Kit must build on Linux |
| Tests run on Linux | `scripts/test-linux` (Swift in Docker, Python, lint) before every commit |
| No secrets or personal data in the repo: tokens only in the Keychain, never in logs; host names, tailnet URLs and addresses are settings or server data, never code. Demo data is made up | `scripts/lint`; read your diff |
| Swift 6, strict concurrency, no warnings, no third-party packages | CI `macos` job |
| No `print(`/`NSLog(` in `Sources/`, no `try!`/`fatalError(` in `HomelabKit` | `scripts/lint` |

More code rules: [CONTRIBUTING.md](../CONTRIBUTING.md).

## Prompt for Claude

Paste this into Claude Code in your fork, and fill in the two lists:

```text
This is my fork of homelab-ios, an iPhone app for a homelab. Read docs/ADAPTING.md, CONTRIBUTING.md and
docs/API.md first, then follow ADAPTING.md step by step.

My homelab: <hosts, what runs where, what my server or agent can do>

1. Turn these modules off: <list>. Prefer leaving the feature out on my server; delete app code only where I say so.
2. Add these modules: <list, with what the server sends>. For each: contract (server/openapi.yaml, docs/API.md)
   first, then the HomelabKit model with tolerant decoding, a normal and an odd fixture, tests, then a thin view,
   a sim-smoke shot and a DeviceTest.md row.

Rules: true-black monochrome look from HomelabDesign, no blue, Rosé Pine colours only for status. No secrets, host
names or personal data in the repo. Run scripts/test-linux after each step and fix what fails. Commit after each
finished step. Ask me before changing the server contract in a way that isn't an addition.
```
