# CI and releases

**Rule: free standard runners only.** The repo is public, so `ubuntu-latest`, `macos-26` and `xcode-27` cost
nothing. Never use `-large` / `-xlarge` runner labels: those are billed.

## Workflows

| Workflow / job | Runner | Runs on | What it proves |
|---|---|---|---|
| `ci` / `linux` | `ubuntu-latest`, container `swift:6.4-noble` | every push (not `ci-screenshots`), PRs, manual | `scripts/lint` passes (no `print(`/`NSLog(` in `Sources/`, no token-ish values in log calls, no `try!`/`fatalError(` in HomelabKit); HomelabKit tests pass on Linux (`KIT_ONLY=1 swift test`, fixture server running); reference server tests pass |
| `ci` / `macos (macos-26)` | `macos-26` | same | HomelabKit tests on macOS; the full app builds into an IPA (release config if xtool supports it); the IPA has `Payload/Homelab.app/PlugIns/HomelabWidget.appex` and both carry the App Group `group.com.qantrex.homelab`; the simulator build launches and every screen renders (screenshots). **Required.** |
| `ci` / `macos (xcode-27)` | `xcode-27` | same | Same, on the next toolchain. `continue-on-error`, so it never blocks. |
| `release` / `build` + `pages` | `macos-26`, `ubuntu-latest` | tag `v*` (or manual with a tag) | Builds and verifies the release IPA, creates the GitHub Release (`Homelab-<version>.ipa` + `.sha256`), publishes the SideStore source to GitHub Pages |

Compiler warnings from `Sources/` are listed in the job summary of each macOS run (not failing yet).

## Screenshots

`scripts/sim-smoke` takes them (demo mode on every tab, dark mode, large text, live mode against the fixture server,
a deep link). They are:

- in the run's summary page, and as the artifact `screenshots-<runner>` (14 days, also on PRs);
- on the orphan branch `ci-screenshots`, under `<branch>/<short-sha>/` (a `/` in the branch name becomes `-`).
  `<branch>/latest.txt` holds the newest short sha; only the last 5 sha folders per branch are kept. Only `macos-26`
  pushes there, and only for pushes and manual runs (PRs from forks get a read-only token).

Open them in the browser: `https://github.com/Qantrex/homelab-ios/tree/ci-screenshots`.

The IPA of every CI run is the artifact `ipa-<runner>` (14 days).

## Release

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The `release` workflow then:

1. builds and verifies the IPA, creates the GitHub Release with `Homelab-1.0.0.ipa` and its SHA-256;
2. builds `source.json` with `scripts/make-source` (the newest version first, older ones kept from the live source),
   copies `Resources/AppIcon.png` to `icon.png` and writes an `index.html`;
3. deploys that site to https://qantrex.github.io/homelab-ios/.

Add the source in SideStore from the site's "Add to SideStore" link, or by hand:
`https://qantrex.github.io/homelab-ios/source.json`. A tag with a `-` (e.g. `v1.1.0-beta.1`) becomes a pre-release.
To redo a release, run the workflow by hand (Actions → release → Run workflow) with the tag; it replaces the files.

**One-time setup (owner):** Settings → Pages → Source: **GitHub Actions**. Until then the release workflow stops at
"Check GitHub Pages" before it publishes anything.

## Local scripts

| Script | What it does |
|---|---|
| `scripts/test-linux` | Fixture server on the host, `KIT_ONLY=1 swift test` in Docker (`swift:6.4-noble`), Python tests, lint |
| `scripts/lint` | The source checks from the `linux` job |
| `scripts/build-ipa` | `xtool dev build --ipa` (release config if supported), prints the IPA path and size |
| `scripts/install-dev` | `xtool dev`: build, sign and install on an iPhone over USB |
| `scripts/verify-ipa IPA` | Widget inside the IPA, App Group in app and widget (entitlements need macOS `codesign` or `ldid`) |
| `scripts/sim-smoke APP OUT` | macOS: simulator screenshots, as in CI |
| `scripts/make-source` | Builds the SideStore/AltStore `source.json` (`--help` for options) |
