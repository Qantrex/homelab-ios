# Plan

Copied from the owner's homelab notes ("iOS-App Session Plan", 2026-11-04). The notes keep the decisions and progress; this copy is the build playbook. Wiki links like `[[iOS-App]]` point into those private notes.

Changed during the build (2026-11-04): the repo is `Qantrex/homelab-ios`; the app target is `Homelab` (not `HomelabCompanion`), and the shared colours/icons for app and widget live in a small `HomelabDesign` target.

# iOS App: session plan

The playbook for building [[iOS-App]] in one long Claude Code session (about 8–10 h of Claude work, plus the owner's
device test). Written 2026-11-04. When the new repo exists, this file moves there as `PLAN.md`, and this note links to it.

Rule from the owner (2026-11-04): **no v1/v2 steps.** One release that is production-ready, tested as far as the tools
allow, built after reading the docs, with subagents for parallel work. **And no code before viability is proven**
(phase 0 gates everything).

## 0. Defaults for the open questions

Claude uses these unless the owner says otherwise before the session.

| Question | Default |
|---|---|
| Repo | `Qantrex/homelab-ios`, public, MIT (created 2026-11-04) |
| "Works for other homelabs" check | `Qantrex/other_homelab_example` (a Debian server + a sleeping gaming PC, Tailscale only, no agent, no HA). Reference only: nothing may assume this homelab's agent, Plex or HA |
| App name / bundle ID | "Homelab Companion" / `com.qantrex.homelab` (SideStore adds `.<TEAMID>`) |
| Home Assistant backend | **In**: pinned entities, toggles, run script/scene. No HA dashboard clone |
| Face ID lock | **In**, off by default |
| Language | English (strings via `String(localized:)`, so translations can come later) |
| Minimum iOS | 18.0 in the package. Linux builds stamp the SDK version (xtool#351), so the owner's phone needs the newest iOS. CI builds don't have this bug |

## 1. Proven so far (2026-11-04)

| What | How it was proven |
|---|---|
| xtool builds an unsigned IPA without an Apple login | xtool source (`DevCommand.swift`: login only for `--sign`) |
| Widgets, App Groups, entitlements, icon, resources | xtool docs + source (`PackSchema.swift`: `bundleID`, `product`, `infoPath`, `entitlementsPath`, `iconPath`, `resources`, `extensions`) |
| xtool on macOS builds with Xcode's SDK, no login, no `Xcode.xip` | xtool source (`BuildSettings.swift`: uses `xcrun` on macOS) |
| Widget doesn't take a SideStore slot, uses 1 App ID | SideStore source |
| SideStore rewrites bundle + App Group IDs | SideStore source (`adjustedGroupIdentifier`) |
| App Intents not available | xtool#145 open, no App Intents step in the source |
| **Claude can run `swift test` here** | Docker daemon starts in the cloud container; `swift:6.4-noble` (Swift 6.4.2) pulled in 60 s; a probe package with Swift Testing + `URLSession` (FoundationNetworking) decoded JSON from a local fake server: **passed** |
| Free macOS CI exists | GitHub runner images: `macos-26`, `macos-15` (arm64, standard = free on public repos), `xcode-27` (preview). **Never** `-large`/`-xlarge`: those are billed |

What only Linux Swift **can't** check: SwiftUI, WidgetKit, Keychain, LocalAuthentication, BackgroundTasks. Those are
compiled and smoke-tested on the macOS runner, then on the phone.

## 2. Phase 0: the spike (short session before the big one)

Goal: prove the parts that only a device can prove. Throwaway code on branch `spike` of the new repo. Deleted after.

**Done 2026-11-04:** Claude wrote it on branch `spike` of `Qantrex/homelab-ios` (`SPIKE.md` there has the owner's steps). **Claude writes** (~8 files): `Package.swift` (app + widget library products), `xtool.yml`, `App-Info.plist`,
`Widget-Info.plist`, `App.entitlements`, `Widget.entitlements` (both `group.com.qantrex.homelab`), one screen, one
widget, and `.github/workflows/spike.yml`.

The spike screen shows, in plain text:
- bundle ID, team suffix, the App Group candidates and which one works (`containerURL(...) != nil`), and the groups
  listed in `embedded.mobileprovision`
- `GET https://pi-utility.<tailnet>.ts.net/api/state` (URL typed on the phone, not in the public repo) → HTTP code +
  first 300 bytes. Expected **200**: agent-chat accepts any path for an allowed `Tailscale-User-Login`. A 403 means
  the header didn't arrive; agent-chat logs `denied ... login=...`
- a Keychain write/read round-trip, and the time of the last background refresh
- a counter it writes to the App Group; the widget shows the same counter

| # | Test | Who | Pass when |
|---|---|---|---|
| S1 | `xtool dev build --ipa` on `bauarch-pc` | owner | IPA contains `Homelab.app` + `PlugIns/HomelabWidget.appex` |
| S2 | Install with SideStore (free Apple ID) | owner | App opens; SideStore shows 2/3 active apps |
| S3 | Widget | owner | In the gallery; shows the counter |
| S4 | App Group after the rewrite | owner reads the screen | App and widget report the same working group |
| S5 | Tailnet identity | owner + Claude reads the agent-chat log via owner | The log line shows the owner's Tailscale login for the app's request |
| S6 | Keychain + background refresh | owner | Token survives an app kill; a refresh time appears within a day |
| S7 | SideStore refresh | owner | After "Refresh All", the counter and token are still there |
| S8 | macOS CI | Claude (Actions logs via GitHub MCP) | `brew install xtool-org/tap/xtool`, `xtool dev build --ipa` and a simulator build (`--triple arm64-apple-ios-simulator`) pass on `macos-26` or `xcode-27` |

Fallbacks are decided now, so a failure doesn't stop the plan:

| Fails | Then |
|---|---|
| S4 | Widget fetches from the server itself (only servers with Tailscale auth; it never gets tokens) |
| S5 | v1 also accepts a per-device bearer token (`COMPANION_TOKENS` in a new `companion.env`) |
| S6 background | No local notifications; widgets refresh on their own timeline only |
| S8 simulator | CI builds the IPA + runs `xcodebuild test` for `HomelabKit` on the simulator; no screenshots |
| S8 completely | CI runs only Linux `swift test`; the owner builds IPAs; release IPA comes from `bauarch-pc` |
| S1/S2 | Stop. Plan B: a PWA (the chat page already installs as one). The owner decides |

**Gate:** the owner reports S1–S8 in `Day Test iOS Spike.md` (Claude writes the empty checklist). Only then phase 1.

## 3. Architecture

```
homelab-ios/
├─ Package.swift              # products: HomelabCompanion (app), HomelabWidget (extension); no dependencies
├─ xtool.yml                  # bundleID, product, iconPath, infoPath, entitlementsPath, extensions
├─ App-Info.plist  Widget-Info.plist  App.entitlements  Widget.entitlements
├─ Resources/AppIcon.png      # 1024 px, no asset catalog
├─ Sources/
│  ├─ HomelabKit/             # pure Swift, Linux + iOS: models, clients, store, logic. No UI imports
│  ├─ HomelabUI/              # SwiftUI views + @Observable view models (iOS only)
│  ├─ HomelabCompanion/       # @main App, scene, background tasks, deep links, wiring
│  └─ HomelabWidget/          # WidgetBundle: StaticConfiguration only (no App Intents)
├─ Tests/HomelabKitTests/     # Swift Testing; runs on Linux (Docker) and macOS
├─ server/
│  ├─ openapi.yaml            # Companion API v1: the contract
│  ├─ fixtures/*.json         # ok, problem, pending, empty, huge, unknown-fields, v0-legacy
│  ├─ reference_server.py     # stdlib Python: a real server for other homelabs + the mock for tests
│  └─ test_reference_server.py
├─ scripts/  test-linux  build-ipa  install-dev  sim-smoke  make-source
├─ .github/workflows/  ci.yml  release.yml
├─ docs/  SETUP.md  SIDESTORE.md  API.md  SECURITY.md  CONTRIBUTING.md
├─ DeviceTest.md  README.md  CHANGELOG.md  LICENSE
```

Rules for the code:
- Swift 6 language mode, strict concurrency, no warnings. No third-party packages.
- `HomelabKit` holds every decision that can be tested: decoding, auth headers, error mapping, cache age, the
  notification diff, App Group candidates, URL checks, formatting. The views stay thin.
- Decoding is **tolerant**: unknown fields are ignored, almost every field is optional, unknown enum values become
  `.unknown`. Other people's servers will send odd JSON.
- Network: one `HTTPTransport` protocol (URLSession in the app, a fake in tests). Timeouts 10 s (state), 20 s (send).
  Errors are one enum: `offline`, `notOnTailnet`, `unauthorized`, `notFound`, `server(Int)`, `decoding`, `timeout`,
  `insecureURL`.
- Storage: Codable JSON files (no SwiftData). Servers list + the last snapshot per server live in the App Group
  container if there is one, else Application Support. Tokens live only in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never in files, logs, crash text or the widget.
- Logging: `os.Logger` with `privacy: .private` for URLs, never for tokens (a test greps for it).

## 4. Companion API v1 (the contract)

Written first (`server/openapi.yaml`), then the Swift models, then everything else. Paths sit under `/api/v1/`.

| Method + path | Body / reply | Notes |
|---|---|---|
| `GET /info` | `{api: 1, name, server, version, features: [status, hosts, actions, chat, cards, services], auth}` | Test-connection button + feature flags (hide a tab the server can't do) |
| `GET /state` | `{time, status: ok/warning/problem/unknown, checked, problems[], hosts[], pending[], cards[], busy[], last_message}` | Everything the overview, actions and widget need, in one call |
| `GET /messages?after=<id>` | `{messages: [{id, ts, from: me/agent, job, status, text}], busy[]}` | Same as today |
| `POST /messages` | `{text}` → `{id}` | Max 4000 chars, JSON only |
| `POST /button` | `{action: "HOMELAB_<VERB>_<id>_<sig>"}` → `{text}` | Signed strings come from `/state` (approve, always, deny) |
| `GET /services` | `[{name, url, icon, group}]` | Launcher |

Shapes:
- **host**: `{id, name, reachable, checked, load, mem_pct, temp, disks: {mount: pct}, containers: {up, total},
  updates: {upgradable, reboot_required}, backup: {last, result}, flags: [undervoltage_now, throttled_now,
  undervoltage_since_boot]}`
- **pending**: `{id, job, action, arg, reason, created, buttons: {approve, always, deny}}`
- **card** (generic, so other homelabs show their own): `{id, title, subtitle, icon (SF Symbol), tint, updated,
  style: list/metrics/text, items: [{title, subtitle, value, progress (0–1), icon, url}]}`. This homelab maps media
  (now playing, downloads, upcoming, recently added), school, commute and days off to cards on the server.

Auth: `Tailscale-User-Login` (this homelab), or `Authorization: Bearer` (reference server, fallback S5). The app sends
no `Origin` header, so the server's origin check passes.

## 5. Features and their acceptance tests

| Screen | Does | Done when |
|---|---|---|
| Overview | Status pill + "checked 2 min ago"; problems; host cards (reachable, load, RAM, temp, worst disk, containers, under-voltage, updates/reboot, backup); generic cards; services | Fixtures ok/problem/empty/huge render (simulator screenshots); 30 s auto-refresh only while visible; pull to refresh; stale cache shows its age and an "offline" bar |
| Actions | Pending list (job, action, arg, reason, age); Approve (confirm sheet), Always (confirm + explains what it means), Deny; shows the server's reply | Tab badge = pending count; a forged/expired button shows the error, not a crash; list refreshes after a tap |
| Chat | Bubbles, job tag for reports (`morning`, `watchdog`), "working…" while `busy`, inline Markdown, copy, quick commands (`/pending`, `/status`, `/last`, `/help`, `/sick`), 4000-char limit | Poll every 2 s while busy and visible, 15 s otherwise, stop in the background; sent text appears right away and is reconciled by id; no duplicates after reconnect |
| Home (HA) | Pinned entities by area/domain; toggle `switch`/`light`/`input_boolean`/`fan`; run `script`/`scene`; entity picker with search | Tab hidden without an HA server; a toggle shows the new state from HA's answer, not a guess; long-lived token only in the Keychain |
| Settings | Servers (several; kind = companion or Home Assistant; URL; auth none/Tailscale or token), Test connection, default server; notifications; Face ID; demo mode; Diagnostics (version, App Group in use, last error, last background refresh); licenses | Plain `http://` only for LAN/`.local`/IPs, with a warning; a bad URL can't be saved; deleting a server deletes its token |
| Widgets | Small (status + pending), medium (hosts), lock screen circular/rectangular/inline | Reads the shared snapshot; timeline 15 min; tap deep-links (`homelab://overview`, `homelab://actions`); "no data yet" state |
| Background | `BGAppRefreshTask`: fetch `/state`, update the snapshot, reload widgets, optional local notification for a **new** problem or pending action | Diff logic is unit-tested (no repeat for the same problem, no alert storm after being offline); off by default (ntfy already pushes) |
| Demo mode | Built-in fixtures, no network | Used for screenshots and by people trying the app without a server |
| Everywhere | Dark mode, Dynamic Type up to XXL, VoiceOver labels, no clipped text, iPhone SE to Pro Max width | Screenshot set in light/dark/XXL |

Out on purpose: Siri/Shortcuts/interactive widgets (no App Intents in xtool), Apple push (paid), iPad layout polish,
Live Activities.

## 6. Changes in this repo (`deploy/claude-agent`)

| Change | Tests (`tests/run-tests`, about +25 checks) |
|---|---|
| `chat/server.py`: `/api/v1/*` routes from section 4; the old `/api/state`, `/api/send`, ... stay as they are for HA and the web page | v1 needs the login header; HA token refused on v1; shapes match the fixtures; `always` signature works; forged button 403; no token in any v1 reply |
| `state_v1()` builds cards from `media.json`, `school.json`, `commute.json`, `off.json` | One check per card type; missing/old files give no card instead of an error |
| `chat/services.json`: the Homepage links | A check that every `href` in `deploy/homepage/services.yaml` is in `services.json` |
| Only if S5 failed: `COMPANION_TOKENS` in `companion.env` | Token works on v1 only; wrong token 403 |

Deploy: this cloud session can't reach the tailnet, so the owner runs `deploy/claude-agent/deploy.sh` (or a local
Claude session does it). Afterwards: `Homelab.md` (dated), `deploy/README.md` row, test count in the plans, and fix
CLAUDE.md's stale "Resume here" pointer.

## 7. Testing ladder

| Level | Where | What | Who runs it |
|---|---|---|---|
| 1 | Cloud container, Docker `swift:6.4-noble` | `HomelabKit` unit tests + client tests against `reference_server.py` on the host (`--network host`) | Claude, after every change |
| 2 | Cloud container | `python3 -m unittest server/test_reference_server.py`; this repo's `tests/run-tests` | Claude |
| 3 | GitHub Actions `ubuntu-latest` | Levels 1+2 again, clean | CI on every push |
| 4 | GitHub Actions `macos-26` / `xcode-27` | `swift build` for iOS of all 4 targets; `xcodebuild test` of `HomelabKit` on the iOS simulator; `xtool dev build --ipa` | CI |
| 5 | Same macOS job | `scripts/sim-smoke`: boot an iPhone simulator, install the simulator build, launch in demo mode and against the reference server, screenshot every screen (light/dark/XXL) | CI; screenshots are pushed to the orphan branch `ci-screenshots`, Claude fetches and looks at them |
| 6 | Owner's iPhone | `DeviceTest.md` (Day Test style, ✅/⚠️/❌) | Owner |

Claude reads CI results with the GitHub MCP tools (`actions_list`, `get_job_logs`) and fixes until green. That is the
iteration loop for everything Linux can't compile.

## 8. Session timeline and subagents

| Step | Time | Work | Parallel? |
|---|---|---|---|
| 1 Setup | 20 min | `add_repo` with push access, clone, start Docker, pull `swift:6.4-noble`, skeleton, CI that only runs `swift test` | – |
| 2 Contract | 45 min | `openapi.yaml`, fixtures, Swift models, decoding tests (tolerant) | – (everything depends on it) |
| 3 Fan-out | 2.5 h | **A (Claude):** `HomelabKit` clients, store, diff, App Group logic + tests. **B (subagent, this repo, worktree):** section 6 + run-tests checks. **C (subagent):** `reference_server.py` + tests + Docker one-liner. **D (subagent):** `ci.yml`, `release.yml`, `sim-smoke`, `make-source`, Pages | A–D in parallel |
| 4 UI | 2.5 h | View models (tested in Kit where possible), the 5 tabs, widget, deep links, demo mode | E (subagent): widget + background while Claude does the tabs |
| 5 CI loop | 1 h | Green on Linux + macOS, screenshot review, fix layouts | – |
| 6 Hardening | 1 h | Offline/stale states, error copy, a11y pass, `/code-review high` on the whole diff, security review (tokens, ATS, logs, URL checks) | Review subagents |
| 7 Docs + release | 45 min | README (screenshots), SETUP (xtool on Linux/macOS), SIDESTORE (add the source), API, SECURITY, CHANGELOG, `DeviceTest.md`; tag `v1.0.0` → IPA + `source.json` on Pages | F (subagent): docs |
| 8 Device test | owner | `DeviceTest.md`; Claude fixes every ⚠️/❌ and tags `v1.0.1` | – |

Commit and push after every step (the container is ephemeral). Commit style as in this repo.

## 9. Definition of done

- Every level of section 7 green; no compiler warnings in Swift 6 mode
- Every acceptance row in section 5 checked, with screenshots in the README
- Tokens: Keychain only, never logged (grep test), never in the widget, deleted with their server
- Works offline (cached state with age), on a bad server (clear error), and on an unknown server shape (no crash)
- Tag `v1.0.0` released: IPA on GitHub Releases, `source.json` on Pages, added once in SideStore by the owner
- This repo: v1 routes live on pi-two, run-tests green, `Homelab.md` + `deploy/README.md` updated and dated
- €0: public repo, standard runners only, free Apple ID

## 10. Risks

| Risk | Likelihood | Plan |
|---|---|---|
| xtool's Swift/Xcode needs differ from the runner's Xcode | medium | S8 checks it. Pin the runner label + xtool version in CI |
| `xcode-27` runner leaves preview or changes | medium | Fall back to `macos-26`; only `swift test` + IPA need it |
| SideStore changes its ID rewrite | low | Runtime App Group lookup + Diagnostics screen show it at once |
| Background refresh hardly runs (iOS decides) | high | Feature is optional; widgets have their own timeline |
| Free Apple ID login (private APIs) breaks in SideStore | low/medium | Outside the app; the owner can still `xtool dev` over USB |
| Scope is big for one session | medium | Timeline order puts the core first; Home (HA) and lock-screen widgets go last |
| Cloud session can't reach the tailnet | certain | Reference server + fixtures stand in; real data only in the device test |

## Owner checklist before the session

- [x] Create `Qantrex/homelab-ios` and give the Claude GitHub App access (done 2026-11-04)
- [ ] Say yes/no to the defaults in section 0
- [ ] iPhone: iOS version (Settings → General → About), SideStore installed and working
- [ ] `bauarch-pc`: Swift 6.4, `usbmuxd`, xtool AppImage, `Xcode_27.1.xip`, `xtool setup` (SDK)
- [ ] Phase 0 spike: run S1–S7 and fill `Day Test iOS Spike.md`

## Deviations from this plan (2026-11-04, with reasons)

| Plan said | Built | Why |
|---|---|---|
| Home tab grouped by area/domain | By domain only | Home Assistant's REST API (`/api/states`) has no areas; areas need the WebSocket API. Possible later |
| Error enum with `insecureURL` | `URLPolicy.Problem.insecureRemote` in the server editor | An insecure URL can't be saved, so it never reaches the network layer |
| Timeouts 10 s (state), 20 s (send) | 10 s state and info, 15 s messages, 20 s send, 150 s button | A button waits for the action's result on the server |
| `server/fixtures/` | `Sources/HomelabKit/Fixtures/` | One copy shared by demo mode, Swift tests, the mock server and CI |
| Deep-link screenshot via `simctl openurl` | Launch with `-HomelabTab` | `openurl` shows an iOS "Open in Homelab?" prompt in the simulator; deep links are unit-tested in `AppModelTests` |
| `AppModel` in the UI layer | In `HomelabKit` | So its race-prone logic (refresh queueing, token rules, tabs) runs in the Linux tests |
| Release `v1.0.0` | `v1.0.0-rc.1` first | The phone tests (spike S1–S7, `DeviceTest.md`) haven't run yet. `v1.0.0` follows them |
