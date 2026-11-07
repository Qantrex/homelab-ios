# Plan: Homelab for other homelabs

Status: plan, 2026-11-07. Read sections 1, 2 and 4 before any task.

> **Status:** M0 done 2026-11-07 (M0.1 `d277f04`, M0.2 and M0.3 in the commit after it). Next: M1.1 and M2.1,
> in parallel. Goldens: `Tests/Goldens/` (app) and `server/goldens/` (reference server); `UPDATE_GOLDENS=1` rewrites
> them only for a change the owner approved.

## 1. Goal and non-goals

**Goal.** Someone without the owner's agent gets a useful app. They run Home Assistant, Uptime Kuma, Docker,
Proxmox, Pi-hole or the *arr apps. They should see a real Today, Lab and widgets within ten minutes.

**Non-goals.** No Homepage clone in the app. No paid Apple ID features (App Intents, configurable widgets, Focus
filters). No new app target, extension or App ID. No agent or LLM in this plan. No change to Companion API v1
except optional fields.

**Owner invariance.** The owner runs one Companion server (identity auth) and one Home Assistant. These rules hold
after every task, and tests enforce them:

| Rule | Test |
|---|---|
| O1 The owner's `servers.json` and `settings.json` decode and re-encode byte-equal. No new key is written unless the user set something new. | `OwnerInvarianceTests/savedFilesRoundTrip` (M0.1) |
| O2 Same data in, same app out: tabs, Today sections per density, headline words, widget snapshot bytes. | `OwnerInvarianceTests/goldens` (M0.1) |
| O3 A user with servers sees no new screen, prompt or line. First run, presets and "Hidden now" appear only with no servers, or once a rule exists. | `OwnerInvarianceTests/noNewSurfaces` (M0.1) |
| O4 Companion API v1 only gains optional fields. `scripts/check-live-api` against the owner's server gives the same table as before. | review of `server/openapi.yaml` diff; owner check (section 4) |
| O5 The reference server without a `sources` key answers as before. | `NoSourcesGolden` in `server/test_reference_server.py` (M0.2) |
| O6 No new app target, extension, entitlement, permission prompt or Swift dependency. | review; `scripts/verify-ipa` |
| O7 CI demo screenshots stay the same unless the task says which ones change. | `scripts/sim-smoke` shots in CI |

## 2. Decisions

**D1. Bridge first. No on-phone adapters for now.**
Options: (a) adapters in the app for Uptime Kuma, Gatus, Glances, a JSON feed; (b) the reference server grows
pluggable sources and stays the one Companion server; (c) both.
Choice: (b). Home Assistant stays direct, as today.
Why: the app sends tokens only over https or to localhost (`URLPolicy.allowsToken`), but most homelab APIs are
`http://192.168.x:port` with keys, and Proxmox uses self-signed certs. Widgets never get a token, so on-phone token
sources would go stale there. Background time (about 30 s) can't fan out to many services. Admin keys would sit on
the phone. Python sources tested on Linux against recorded JSON are cheaper to fix than an app re-signed every 7
days. And the owner's app code path does not change.

**D2. No Composer now.**
Options: a pure `Composer` that merges several sources into one `ServerStatus`, or let the bridge aggregate.
Choice: the bridge aggregates. The app keeps one "Show data from" server plus HA.
Why: it rewires `AppModel`, the widget snapshot, alerts and background refresh, the owner's hot path, for a gain
the bridge gives for free. Revisit if users ask to merge two Companion servers.

**D3. Show rules: yes, small, optional, after the guardrails.**
They help everyone, the owner included, but only when set. Kinds: Always, When it needs me, At set times. Presence
(At home, Away) and quiet hours come later and need the owner's go. No stored-data migration: the plan-control idea
of moving Machines into `hidden` on decode changes the owner's saved file and is dropped. Standard keeps dropping
Machines in code unless Machines has a rule.

**D4. First-run presets: yes, kit plus welcome only.**
Shown only while `hasServers` is false, so the owner never sees them. Three presets (Home, Watch, Everything) write
a `TodayLayout` and a `Density`. Calm, Standard and Overkill stay.

**D5. The bridge is the reference server, not a new project.**
`server/reference_server.py` stays the entry point and stays stdlib-only. Sources are optional stdlib modules in
`server/sources/`. A Dockerfile and a compose file with a Tailscale sidecar make it one `docker compose up`.

**D6. Secrets stay on the bridge, in env vars.** Config names the variable (`key_env`), never the key. Sources are
read-only by default. Actions (restart, start, stop) are opt-in and reuse the existing signed buttons.

**Decided by the owner, 2026-11-07** (binding for every task):
1. **Name: "Homelab Bridge".** The reference server grown with sources is the Homelab Bridge; the image is
   `ghcr.io/qantrex/homelab-bridge`. Docs say "Homelab Bridge"; `server/reference_server.py` keeps its file name and
   its no-sources behaviour (M0.2 golden).
2. **Image on GHCR, built by hand.** A script (like `scripts/build-ipa`) builds and pushes the image; CI only checks
   that it builds. CI never publishes.
3. **PyYAML only in the Docker image.** The single-file reference server stays stdlib-only; without PyYAML the
   Homepage import says what is missing (M1.8 is in scope).
4. **Show rules: yes, including presence and quiet hours.** M3.1, M3.2 and M3.3 are all in scope. Every rule is off
   by default; the owner's Today stays identical (goldens).
5. **Self-signed certificates (Proxmox, TrueNAS): opt-in `insecure: true` plus a warning** in the source status
   (`/info` and Diagnostics). A `ca_file` option is welcome on top.
6. **Bridge actions (container restart, VM start/stop): off by default, per item.** Only containers/VMs listed in the
   source's config get actions; each press still goes through the app's confirm and the signed-button rules.
7. **Merging:** each task on its own branch; the coordinator merges into `main` only when every check in section 4 is
   green, and pushes in batches so CI runs finish.
8. **Phone:** the coordinator may look at the owner's phone read-only (`scripts/phone`: launch, screenshots, logs) and
   copy a finished IPA into SideStore's folder; installing stays the owner's tap. Agents never touch the phone.

## 3. Architecture

```
iPhone app (unchanged contract, one "Show data from" server + one HA)
 ├── Companion API v1 ──> owner: the owner's agent (untouched by this plan)
 │                   └──> others: reference server with sources (the bridge, Docker + Tailscale sidecar)
 │                              ├── json      any URL answering a subset of /state; cards_dir for push
 │                              ├── uptime-kuma, gatus      problems, status
 │                              ├── docker (socket proxy)   containers, unhealthy -> problems
 │                              ├── proxmox                 hosts, 24 h history
 │                              ├── pihole / adguard        dns card
 │                              └── sonarr/radarr + qbit    health problems, queue card
 └── Home Assistant REST (direct, token, as today)
Widgets: read widget-snapshot.json; fetch /state only from identity servers (unchanged).
```

## 4. Owner-invariance guardrails

M0.1 and M0.2 land before any other task. After that, every task ends with all of these green:

1. `scripts/test-linux` (Swift kit tests, Python tests, lint).
2. `scripts/features` (registry check) and `scripts/features render` with no diff left.
3. For server tasks: `scripts/check-live-api --token "$T" http://127.0.0.1:PORT` against the reference server
   started with that task's sample config.
4. CI green on the branch (Linux and both macOS jobs).
5. Goldens unchanged. If a golden must change, stop and ask the owner. Never regenerate goldens to make a test pass.

**Owner check** (the owner runs it, or an agent with the phone on USB, read-only): `scripts/check-live-api` against
the owner's server, `scripts/phone-shots` before and after for UI tasks. Agents never run `deploy.sh` or install on
the phone without the owner.

## 5. Workstreams and tasks

M0 first. Then M1 (server) and M2 (app) run in parallel. M3 after M0, in parallel with both.

### M0. Guardrails

**M0.1 Owner goldens in the kit.** Size M. Depends: none.
- Files: `Tests/HomelabKitTests/OwnerInvarianceTests.swift`, `Tests/Goldens/` (outside the test target, so SwiftPM
  doesn't warn about unhandled files).
- Steps: write a made-up owner-shaped `servers.json` (Companion `https://nas.tail1234.ts.net`, identity; HA
  `https://ha.tail1234.ts.net`, token, pins, tile names and icons, `selected` and `home` set) and `settings.json` (a
  reordered layout with hidden sections, a personality, `leaveActivity` false). For each `state-*.json` fixture and
  each density, record `availableTabs`, `Density.sections`, the headline words and the widget snapshot JSON. Read
  goldens via `#filePath` (no `Package.swift` change). `UPDATE_GOLDENS=1` rewrites them; commit them from `main`
  before any refactor.
- Accept: green on `main`. Changing `Density.standard` or the snapshot encoder makes it fail (try once, revert).
  `noNewSurfaces` asserts the first-run flag is false with servers.
- Registry: add the suite to the `foundation`-area feature that owns `AppModel` tests (or a new `owner-invariance`
  entry, area Foundation, `not_needed = {device_tests = "kit only"}`).
- Parallel with M0.2. Risk: fixtures with "now"-relative times; pin a clock.

**M0.2 Reference server golden.** Size S. Depends: none.
- Files: `server/test_reference_server.py` (class `NoSourcesGolden`), `server/goldens/`.
- Steps: start the server from a config without `sources`, fixture mode on. GET `/info`, `/state`, `/actions`,
  `/services`; mask times; compare with goldens.
- Accept: green; a changed field in `/state` fails it. Registry: claim the class and `server/goldens/*`.

**M0.3 Commit this plan; registry prep.** Size S. Depends: none.
- Files: `docs/plans/MODULAR.md`, `scripts/features` (`py_tests` reads every `server/test_*.py`, not only one file).
- Accept: `scripts/features` green; a new `server/test_x.py` class shows as unclaimed until listed.

### M1. Bridge (server side, Python stdlib)

**M1.1 Sources interface and fake upstream.** Size M. Depends: M0.2, M0.3.
- Files: `server/reference_server.py` (`Collector.run_once` calls sources; config key `sources`),
  `server/sources/__init__.py` (loader, `fetch` helper), `server/test_sources.py`, `server/recordings/`.
- Contract: `collect(cfg, fetch) -> {"problems", "hosts", "cards", "services"}`. `fetch` has a timeout, an 8 MB
  limit, no redirects, no cookies, secrets from `key_env` only. Merge: ids prefixed `<source name>:`; status is the
  worst; sources can't use the card ids `today` or `departures`; a failing source becomes exactly one `warning`
  problem ("Kuma: 401") and the rest still answers. Each source runs on its own `every` (default 60 s).
- Fake upstream: a stdlib `http.server` that replays `server/recordings/<type>/<case>.json`.
- Accept: M0.2 green; a timeout or crash gives one warning; the env secret never appears in any reply (test greps
  every endpoint); `check-live-api` passes on a sample config. Docs: `docs/REFERENCE_SERVER.md#sources`.
- Registry: new feature `server-sources`, area Server. Risk: the collector thread blocks; run sources in a pool.

**M1.2 Source status in `/info`.** Size S. Depends: M1.1. Parallel: M1.3 to M1.7.
- Optional `sources: [{name, type, ok, error, checked}]` in `/info`. Add to `server/openapi.yaml` and
  `docs/API.md` as optional. `check-live-api` accepts it. Errors are short and contain no URL with a key.

**M1.3 `json` feed source.** Size S. Depends: M1.1.
- Pulls a URL that answers a subset of `/state`, read leniently. Docs say when to use `cards_dir` (push) instead.
- Accept: normal and odd recordings (unknown fields, wrong types, 9 MB body) pass; odd never crashes.

**M1.4 Monitors: Uptime Kuma and Gatus.** Size M. Depends: M1.1.
- Kuma: the public status page JSON (`/api/status-page/<slug>`, `/api/status-page/heartbeat/<slug>`), no key.
  Gatus: `/api/v1/endpoints/statuses`. Down monitors become problems. A summary card per source.
- Accept per source: normal and odd recordings, unit tests, a row in the sources table in `docs/SERVER-SETUP.md`.
  Verify the API paths against current upstream docs first and pin the tested version in the source's docstring.

**M1.5 Docker and Proxmox.** Size L. Depends: M1.1.
- Docker through a socket proxy URL (never the raw socket in compose): containers per host, unhealthy and
  restarting become problems. Proxmox: API token with the PVEAuditor role; nodes become hosts with 24 h history
  from `rrddata`; guests as containers. `ca_file`, or `insecure: true` with a warning.
- Accept: as M1.4, plus history keeps the API limits (at most 288 points) and `check-live-api` passes.
- Risk: the existing `docker` key uses the CLI; keep it, and document which to pick.

**M1.6 DNS and media: Pi-hole v6, AdGuard Home, Sonarr/Radarr, qBittorrent.** Size M. Depends: M1.1.
- Pi-hole: app password, session from `POST /api/auth`, logout after. AdGuard: basic auth. Both fill the existing
  `dns` card style. *arr: `/api/v3/health` becomes problems, the queue a list card with `progress`.
- Accept: as M1.4. No new card style without an entry in `docs/API.md` and the app's card tests.

**M1.7 Container image and compose.** Size M. Depends: M1.1. Parallel: M1.2 to M1.6.
- Files: `server/Dockerfile` (base pinned by digest), `server/compose.yaml` (`tailscale/tailscale` sidecar, shared
  network namespace, `TS_SERVE_CONFIG`, server on 127.0.0.1 only, socket proxy service), a CI job that builds the
  image and never pushes, `docs/SERVER-SETUP.md#docker`.
- Accept: CI builds the image; locally, the image in token mode on loopback passes `check-live-api`. Docs say never
  to use Funnel. Ask the owner before adding the CI job (new job, cache, time).

**M1.8 Homepage import.** Size L. Blocked on owner decision 3.
- Reads a mounted `services.yaml`: the launcher (`services`) right away; widget entries with a known `type` become
  sources with their keys. Accept: 5 widget types work from a made-up Homepage config.

### M2. App side

**M2.1 Home Assistant only Today.** Size M. Depends: M0.1. Parallel: M1.x, M3.1.
- Files: `Sources/HomelabKit/HeroLines.swift` (or a new `HomeGlance.swift`), `Sources/HomelabUI/TodayView.swift`,
  a demo scene `-HomelabDemoScene ha-only`.
- With no Companion server, the headline says something real: "Home." then "3 lights on", gold "2 unavailable".
- Accept: O1 to O3 goldens unchanged; kit tests on `ha-states.json`; a CI shot `demo-ha-only`; a DeviceTest row in
  "Home"; registry entry (area Home, `launch_args`, `screenshots`).

**M2.2 Start presets (kit).** Size S. Depends: M0.1. Parallel: M2.1.
- `StartPreset` (`home`, `watch`, `everything`): `suggested(features:hasHA:)` and `layout(features:hasHA:)` returning
  a `TodayLayout` and a `Density`. Tests for each feature set. No UI.

**M2.3 First run.** Size L. Depends: M2.2.
- Welcome: "Add Home Assistant", "Add a Homelab server", "Try the demo". After Test connection: what was found,
  then "Start with" with the suggested preset preselected. With HA, the tile picker opens next. All skippable.
- Accept: `noNewSurfaces` green; a fresh HA-only install reaches Today with tiles in 5 taps after the token; the demo
  is still one tap. DeviceTest FS1 rewritten, new FS rows; CI shots of the new screens (light, dark, XXL).

**M2.4 Source status in Diagnostics.** Size S. Depends: M1.2.
- Diagnostics lists `/info.sources` as "Kuma · ok" or "Proxmox · 401". Nothing when the field is absent (the owner).
- Accept: decode tests with and without the field; `state-unknown-fields.json` still passes.

**M2.5 Docs for newcomers.** Size S. Depends: M1.4, M1.7.
- `README.md#who-it-is-for`: a row "Uptime Kuma, Docker, Proxmox, Pi-hole, *arr: the reference server with
  sources". `docs/SERVER-SETUP.md`: "Pick your sources". `docs/ADAPTING.md`: a source is the third way to add a module.

### M3. Today control (in scope: decision 4, presence and quiet hours included)

**M3.1 Show rules (kit).** Size M. Depends: M0.1. Parallel: M1.x, M2.x.
- `ShowRule` (`always`, `needsMe`, `times` with `from`, `to`, `days`), `TodayLayout.rules: [String: ShowRule]?`
  encoded only when set, `TodaySection.needsMe(state:home:)`, `Density.sections(layout, context)`. Overkill ignores
  rules. Calm adds sections set to "When it needs me" while they need you.
- Accept: owner goldens unchanged (O1, O2) at every hour of a test week; rule tests for midnight wrap, weekdays,
  and each section's `needsMe`. Pass the clock in; never read `Date()` inside the rule.

**M3.2 Rule editor and "Hidden now".** Size M. Depends: M3.1.
- The sections editor shows the rule in words under each row; a sheet with the three kinds and named windows. Under
  Today, "Hidden now: Deals (evenings) · Show" appears only while a rule hides something.
- Accept: a launch argument for a fixed time shows a Deals rule hiding at 14:00 and showing at 19:00 in a CI shot;
  DeviceTest rows; registry entry (area Today).

**M3.3 Presence and quiet hours.** Size L. Needs the owner's go. Presence from an HA `person.*` entity (fails open
when unknown or older than 30 min); quiet hours for local notifications; both off by default.

### Not planned now
The Composer, on-phone adapters, merging two Companion servers, rule-based proposals, chat through a local LLM,
TrueNAS (WebSocket API). Each needs a new decision.

## 6. Execution protocol for agents

- **One writer per checkout.** Each agent works in its own git worktree (inside the repo's git-ignored
  `.claude/worktrees/`, never a new folder in `~`). Never two agents in one checkout.
- **Branch:** `modular/<task-id>-<slug>`, for example `modular/m1.4-monitors`. One task per branch. Merge to `main`
  only when section 4 is green; the owner merges, or says an agent may.
- **CI** cancels in-progress runs per branch: push once when the task is done, then wait for the result.
- **Verify:** `scripts/test-linux`, `scripts/lint`, `scripts/features`, `scripts/features render`,
  `python3 -m unittest -v server/test_*.py`, `scripts/check-live-api` for server tasks. App UI tasks also need CI's
  macOS jobs and their shots.
- **Registry:** every new user-visible thing is one `[[feature]]` in `features.toml` with `sources`, `tests`,
  `device_tests` (or `not_needed` with a reason), `docs` and `depends_on`. Every new file under `Sources/`,
  `scripts/` or `server/` must be claimed, recordings and goldens too. Use `status = "partial"` until the phone row
  is checked; the owner sets `shipped`. Then `scripts/features render` and commit `docs/FEATURES.md`.
- **Stop and ask the owner** when: a golden must change; `openapi.yaml` would change in a non-optional way; a task
  needs a new target, entitlement, dependency, CI job or CI permission; something must run on the phone or the
  owner's server beyond read-only checks; an upstream API differs from this plan.
- **Private data:** the repo is public. Examples use `nas.tail1234.ts.net`, `ha.tail1234.ts.net`, `192.0.2.x`
  addresses and names like "Kuma" or "pve1". Recordings are made up or scrubbed: no real hosts, keys, slugs, names,
  media titles or IPs. Never read or copy `~/.config/homelab-ios/`. `scripts/lint` and the `check-live-api` secret
  scan must pass.
- **Commits:** prefix `FEAT:`, `FIX:` or `DOCS:` (tests go with their feature). Short plain sentences, the house style. Identity
  `Konstantin Bauer <konstantin@wbauer.com>`. No AI attribution lines (public repo). One commit per finished,
  tested step.

## 7. Risks and open questions

- **Scope creep into a dashboard.** Cap official sources at about 15. Others are "community, untested".
- **The bridge holds many keys.** Env vars only, read-only tokens by default, socket proxy for Docker, server bound
  to 127.0.0.1 behind `tailscale serve`, never Funnel.
- **Upstream drift** (Pi-hole v6, Uptime Kuma 2.x, Proxmox). Pin the tested version per source; fail soft into one
  warning.
- **HA-only users get no widgets with data.** Widgets read the Companion snapshot. Open: write an HA-only status
  into the widget snapshot (M2.1 follow-up), or say "add the reference server for widgets".
- **Noisy headline.** Many sources mean many problems. Open: a per-source `counts_toward_status` flag.
- **Golden brittleness.** Pin times and order in fixtures, or goldens fail for no reason.
- Open: should `/info` suggest a starting layout (`suggested_today`) for presets? Not now; presets read `features`.
