# CI and releases

**Rule: CI only tests and checks; every app build is done locally** (owner, 2026-11-05). `scripts/build-ipa` builds
the IPA on your PC and checks it with `scripts/verify-ipa`. The macOS job builds only for the simulator, because the
screenshots and simulator tests need a build and Linux has no simulator.

**Rule: free standard runners only.** The repo is public, so `ubuntu-latest`, `macos-26` and `xcode-27` cost
nothing. Never use `-large` / `-xlarge` runner labels: those are billed.

## Workflows

| Workflow / job | Runner | Runs on | What it proves |
|---|---|---|---|
| `ci` / `linux` | `ubuntu-latest`, container `swift:6.4-noble` | every push (not `ci-screenshots`), PRs, manual | `scripts/lint` passes (no `print(`/`NSLog(` in `Sources/`, no token-ish values in log calls, no `try!`/`fatalError(` in HomelabKit); HomelabKit tests pass on Linux (`KIT_ONLY=1 swift test`, fixture server running); reference server tests pass |
| `ci` / `macos (macos-26)` | `macos-26` | same | HomelabKit tests on macOS; the app and widget build for the simulator; the simulator build launches and every screen renders (screenshots); HomelabKit tests pass on the iOS simulator (`xcodebuild test`); no compiler warnings in `Sources/`. **Required.** |
| `ci` / `macos (xcode-27)` | `xcode-27` | same | Same, on Xcode 27 (the SDK the local builds use). **Required** too (since 2026-11-05). |
| `ci` / `screenshots` | `ubuntu-latest` | pushes and manual runs, after `macos` | Publishes the `macos-26` screenshots to the `ci-screenshots` branch (see below) |

### Steps of the macOS job

| Step | What it does |
|---|---|
| Install xtool (pinned) | Downloads xtool `1.24.0` (`xtool.app.zip` from the GitHub release), checks its SHA-256, puts it on `PATH`. Falls back to `brew install xtool-org/tap/xtool` with a warning. Fails if `xtool --version` shows a major version other than 1. To upgrade: change `XTOOL_VERSION` and `XTOOL_SHA256` together |
| Shared code tests | `KIT_ONLY=1 swift test` on macOS |
| Simulator build, smoke test | `xtool dev build --triple arm64-apple-ios-simulator`, then `scripts/sim-smoke` |
| Kit tests on the iOS simulator | Starts the fixture server, picks the newest iPhone simulator (`scripts/sim-smoke --pick main`), picks the scheme from `xcodebuild -list` (`Homelab-Package`, else `HomelabKit`), runs `xcodebuild test -only-testing:HomelabKitTests`. If the full package doesn't build there, it retries with `KIT_ONLY=1` and warns. `TEST_RUNNER_HOMELAB_FIXTURE_URL` gives the tests `HOMELAB_FIXTURE_URL`, so the integration tests run. Logs: artifact `xcodebuild-test-<runner>` |
| Compiler warnings | Counts `warning:` lines for `Sources/` in the simulator build log and lists them in the job summary. **Fails** when there is one or more, on both runners. Runs last, so it never hides the screenshots |

### Security of the workflow

| Rule | How |
|---|---|
| Read-only token by default | Top-level `permissions: contents: read` |
| One writer | Only the `screenshots` job has `contents: write`. It runs only git and bash on the downloaded PNGs, no third-party tools |
| No token left on disk | `persist-credentials: false` on every checkout, except in `screenshots` (it pushes) |
| Pinned actions | `actions/checkout`, `upload-artifact`, `download-artifact` by full commit SHA (the tag is in a comment) |
| Pinned xtool | Fixed release + SHA-256, see above |

## Screenshots

`scripts/sim-smoke` takes them, numbered in order:

| # | Shots |
|---|---|
| 01–05 | Demo mode, every tab (today, actions, chat, lab, settings), light. **Core**: sim-smoke fails without them |
| 06–10 | The same, dark |
| 11–15 | The same, accessibility extra-large text (`-xxl`) |
| 16–20 | Live mode against the fixture server: `state-problem.json` today and chat (a proposal with its buttons and a card inside the bubbles), `state-pending.json` actions, `state-huge.json` lab, `state-ok.json` today |
| 21 | Offline: the fixture server is stopped and the app relaunched; it should show the cached data with its age and the error bar |
| 22–23 | The smallest iPhone simulator available (narrowest screen; SE, an "e" model or mini; never a two-screen model like "iPhone Duo"): demo today and actions |
| 24–25 | Forms of actions the app starts (`-HomelabAction`): Wake-up in dark, Add an event with accessibility extra-large text |
| 26 | A host's details (`-HomelabHost media`), dark: 24 h sparklines, containers with problems first and Restart buttons |
| 27 | Demo Today in Overkill with the Snarky personality (last: both settings stay set) |

The demo shots from 24 on start from a reset (`-HomelabResetState YES -HomelabDemo YES`): a clean demo, without the
fixture server and its cache from 16–21.

Other failed shots are listed in `summary.txt` but don't fail the step. There is no deep-link shot: `simctl openurl`
shows an "Open in Homelab?" system prompt; the launch argument `-HomelabTab` covers opening a tab directly.

They are:

- in the run's summary page, and as the artifact `screenshots-<runner>` (14 days, also on PRs);
- on the orphan branch `ci-screenshots`, under `<branch>/<short-sha>/` (a `/` in the branch name becomes `-`).
  `<branch>/latest.txt` holds the newest short sha; only the last 5 sha folders per branch are kept. Only `macos-26`
  pushes there (the `screenshots` job), and only for pushes and manual runs (PRs from forks get a read-only token).
- the README set, always from the newest run, under fixed names in `<branch>/readme/`: `01-today.png`,
  `02-actions.png`, `03-chat.png`, `04-lab.png`, `05-settings.png` (demo, light) and `06-dark.png` (demo today,
  dark); `readme/sha.txt` says which run they came from. Copy them into `docs/screenshots/` for the README.

Open them in the browser: `https://github.com/Qantrex/homelab-ios/tree/ci-screenshots`.

CI builds no device IPA at all. The device build, with the widget and App Group check, runs on your PC
(`scripts/build-ipa`). **CI never builds or publishes an app to install** (owner's rules, 2026-11-04 and 2026-11-05).

## Release

By hand, from your own build: [RELEASE.md](RELEASE.md). There is no release workflow.

## Local scripts

| Script | What it does |
|---|---|
| `scripts/test-linux` | Fixture server on the host, `KIT_ONLY=1 swift test` in Docker (`swift:6.4-noble`), Python tests, lint |
| `scripts/lint` | The source checks from the `linux` job |
| `scripts/build-ipa` | `xtool dev build --ipa` (release config if supported), runs `scripts/verify-ipa` on it, prints the IPA path and size |
| `scripts/install-dev` | `xtool dev`: build, sign and install on an iPhone over USB |
| `scripts/verify-ipa IPA` | Widget inside the IPA, App Group in app and widget (entitlements from `codesign`, `ldid`, or python3 reading the signature) |
| `scripts/phone-shots [--no-install] [OUT]` | Linux or macOS: build, install on the iPhone over USB, open every tab in demo mode, save screenshots (`shots-phone/`). About 1 minute. Needs the phone unlocked, trusted, Developer Mode on; uses `pymobiledevice3` in `.venv/` (no root) |
| `scripts/sim-smoke APP OUT` | macOS: simulator screenshots, as in CI. `--pick main\|small` prints a simulator UDID |
| `scripts/make-source` | Builds the SideStore/AltStore `source.json` (`--help` for options) |
