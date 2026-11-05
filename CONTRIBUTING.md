# Contributing

Thanks for helping. This page says how to build and test, the code rules, and what a pull request needs.

## Build and test

| What | Where | Command |
|---|---|---|
| Shared code tests (HomelabKit) | Linux or macOS, with Docker | `scripts/test-linux` |
| Same, by hand | Docker | `docker run --rm --network host -e KIT_ONLY=1 -v $PWD:/w -w /w swift:6.4-noble swift test` |
| Same, on a Mac | macOS | `KIT_ONLY=1 swift test` |
| Reference server tests | any, Python 3 | `python3 -m unittest server/test_reference_server.py` |
| Source checks | any, bash | `scripts/lint` |
| IPA (always built locally, checked by `verify-ipa`) | macOS or Linux with xtool | `scripts/build-ipa` |
| Install on your iPhone | xtool + USB | `scripts/install-dev` |
| Screenshots from your iPhone | Linux or macOS, iPhone over USB | `scripts/phone-shots` (about 1 minute; use it while working on the UI) |
| Simulator screenshots | macOS | `scripts/sim-smoke APP OUT` |

`KIT_ONLY=1` builds only `HomelabKit` and its tests: SwiftUI and WidgetKit don't exist on Linux. `scripts/test-linux`
also starts the fixture server, so the integration tests run too (they need `HOMELAB_FIXTURE_URL`).

CI runs the tests and checks on every push and pull request, plus a simulator build for `xcodebuild test` on the
simulator and the screenshots. It never builds the IPA: build that locally. See [docs/CI.md](docs/CI.md). You can't run the macOS part on Linux: push and read the CI result.

## Code rules

| Rule | Why |
|---|---|
| Swift 6 language mode, strict concurrency, no compiler warnings (CI fails on any) | Catch races at build time |
| No third-party packages | Small, auditable, builds anywhere |
| `HomelabKit` holds every decision that can be tested (decoding, errors, URL checks, diffs, formatting); views stay thin | Linux CI can test it |
| `HomelabKit` imports Foundation only (no SwiftUI, UIKit, WidgetKit) | It must build on Linux |
| Decoding is tolerant: unknown fields ignored, almost all fields optional, unknown enum values have a fallback | Other people's servers send odd JSON |
| No `print(` / `NSLog(` in `Sources/`: use `os.Logger`, `privacy: .private` for URLs | `scripts/lint` checks it |
| No `try!` or `fatalError(` in `HomelabKit` | Shared code must not crash the app or widget |
| Tokens only in the Keychain. Never in files, logs, error text or the widget | `scripts/lint` greps log calls for token-ish values |
| User-visible strings via `String(localized:)` | Translations later |
| A new API field: `server/openapi.yaml` first, then a fixture, then the model and a test | The contract leads |

Fixtures live in `Sources/HomelabKit/Fixtures/`. Demo mode, tests and the fixture server all use them, so a change
there shows up everywhere. Add a new fixture rather than changing one other tests rely on.

## Pull request checklist

- [ ] `scripts/test-linux` passes (or the `linux` CI job is green)
- [ ] `scripts/lint` passes
- [ ] New logic in `HomelabKit` has a test (Swift Testing: `@Test`, `#expect`)
- [ ] API changes: `server/openapi.yaml`, a fixture and `docs/API.md` updated; the reference server still passes
- [ ] UI changes: look at the CI screenshots (light, dark, large text, small iPhone)
- [ ] No warnings in the `macos (macos-26)` job
- [ ] No tokens, real hostnames or tailnet names in code, fixtures or screenshots
- [ ] `CHANGELOG.md` has a line for anything users notice
