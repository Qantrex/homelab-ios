# Building the app

The app is a SwiftPM package. [xtool](https://github.com/xtool-org/xtool) turns it into an iOS app with a widget
extension, on Linux or macOS. There is no Xcode project. `xtool.yml` names the bundle ID, the Info.plists, the
entitlements, the icon and the widget extension.

There is no release yet, so for now you build and install it yourself: from Linux see
[INSTALL-FROM-LINUX.md](INSTALL-FROM-LINUX.md). After the first release you can take the release IPA instead
([SIDESTORE.md](SIDESTORE.md), tested 2026-11-07).

## Linux

You need Swift 6.4, usbmuxd (to talk to the iPhone over USB), the xtool AppImage, and the iOS SDK from Xcode 27.1.

### Arch

```bash
sudo pacman -S --needed usbmuxd libimobiledevice fuse2
yay -S swift-bin        # or the Swift 6.4 tarball from https://www.swift.org/install/linux/
```

### Debian / Ubuntu

```bash
sudo apt install usbmuxd libimobiledevice-utils libfuse2   # Ubuntu 24.04 and newer: libfuse2t64
```

Install Swift 6.4 with swiftly, as described on <https://www.swift.org/install/linux/>:

```bash
curl -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
tar zxf "swiftly-$(uname -m).tar.gz" && ./swiftly init
swiftly install 6.4 && swift --version
```

### xtool and the iOS SDK (both distros)

Pin the version, and check the file before you install it:

```bash
XTOOL_VERSION=1.24.0   # the newest release on 2026-11-07; it needs the App Group patch below
mkdir -p ~/.local/bin
curl -fL "https://github.com/xtool-org/xtool/releases/download/$XTOOL_VERSION/xtool-$(uname -m).AppImage" \
  -o ~/Downloads/xtool-$XTOOL_VERSION.AppImage
sha256sum ~/Downloads/xtool-$XTOOL_VERSION.AppImage
# Compare with <sha256 of xtool-1.24.0-x86_64.AppImage, recorded at the first download>. Different: don't install it.
install -m 755 ~/Downloads/xtool-$XTOOL_VERSION.AppImage ~/.local/bin/xtool
```

Record the checksum the first time (with the version and the date), so a later download can be compared with it.

Download **Xcode 27.1** in the browser (Apple login) from <https://developer.apple.com/download/all/?q=Xcode>, then:

```bash
xtool sdk install ~/Downloads/Xcode_27.1.xip
```

This is a one-time step. xtool only takes the SDK from it.

## macOS

Install Xcode from the App Store (xtool uses its SDK through `xcrun`, so no `.xip` is needed), then:

```bash
brew install xtool-org/tap/xtool
```

## Build

| Command | What it does |
|---|---|
| `scripts/build-ipa` | `xtool dev build --ipa` (release configuration if your xtool supports it), then `scripts/verify-ipa`. Prints the IPA path and size. The IPA is in `xtool/` |
| `scripts/install-dev` | `xtool dev`: build, sign and install on an iPhone over USB in one step |
| `scripts/verify-ipa xtool/<name>.ipa` | Checks the widget is inside and both carry the App Group (`build-ipa` runs it for you) |

`scripts/build-ipa` needs no Apple ID: the IPA is unsigned, and SideStore signs it when you install it (send it to the
phone with AirDrop, LocalSend or Files, then SideStore → My Apps → +).

`scripts/install-dev` signs with your own Apple ID. Before the first run:

- `xtool auth login` (a free Apple ID works; the app then stops opening after 7 days: run `scripts/install-dev`
  again, your data stays. Today warns 2 days before, and Settings → Diagnostics → Install expires shows the date).
- The iPhone trusts this computer and has Developer Mode on (Settings → Privacy & Security).
- On Linux, usbmuxd must be running.

### Known xtool bug: no App Group with a free Apple ID (xtool 1.24.0 and older)

xtool 1.24.0 and older remove the App Group entitlement when they sign for a free Apple ID (free teams had App
Groups marked as "not free" in xtool). The install works and the app works, but the provisioning profiles of the
app and the widget have no `com.apple.security.application-groups`, so each one falls back to its own folder. The
widgets never see the app's data:

- Every widget says "No App Group: see Diagnostics" (before 2026-11-06: "Open the app" / "Open Homelab to load …").
- Settings → Diagnostics → App Group says "none".
- `pymobiledevice3 provision list` shows the `XTL profile` entries with only `application-identifier`,
  `keychain-access-groups`, `get-task-allow` and the team ID.

xtool fixed it on `main` in [#284](https://github.com/xtool-org/xtool/pull/284) (merged 2026-10-30, one App Group
per app on a free team, which is what Homelab uses). Use the first release after 1.24.0. Until then, build 1.24.0
with the one line from #284 (what this project used on 2026-11-07; `main` itself didn't compile on Linux then).

Save this as `build-xtool.sh` and run `bash build-xtool.sh`. It stops when the source is not the pinned commit or the
patch changes anything but that one line:

```sh
set -eu
# Tag 1.24.0 is this commit (`git ls-remote https://github.com/xtool-org/xtool.git refs/tags/1.24.0`, 2026-11-07).
XTOOL_COMMIT=70e1568fdfcb20b560774057cd783f02361293b9
git clone --branch 1.24.0 https://github.com/xtool-org/xtool.git xtool-124 && cd xtool-124
[ "$(git rev-parse HEAD)" = "$XTOOL_COMMIT" ] || { echo "1.24.0 is not $XTOOL_COMMIT, stop"; exit 1; }

f="Sources/XKit/DeveloperServices/App IDs/Entitlements/DeveloperServicesCapability.swift"
[ "$(grep -c '(.appGroups, isFree: false)' "$f")" = 1 ] || { echo "not exactly one appGroups line, stop"; exit 1; }
sed -i 's/(.appGroups, isFree: false)/(.appGroups, isFree: true)/' "$f"
[ "$(git diff --numstat | cut -f1,2 | tr '\t' ' ')" = "1 1" ] || { echo "the patch changed more than one line, stop"; exit 1; }

# The Dockerfile fetches some dependencies by branch or tag name, not by commit. Keep this list with your notes.
grep -n '^ADD' Dockerfile
# Docker without buildx: the Dockerfile's `ADD <git url>` lines need BuildKit, so clone instead
sed -i -E 's#^ADD --keep-git-dir=true (https://[^ ]+\.git)\#([^ ]+) (/[^ ]+)$#RUN git clone -q --branch \2 \1 \3#' Dockerfile
docker build --target build-xtool -t xtool-appgroups .
cid=$(docker create xtool-appgroups) && docker cp "$cid:/xtool/Linux/packages/xtool-x86_64.AppImage" . && docker rm "$cid"
sha256sum xtool-x86_64.AppImage   # write it down: <sha256 of your build>
cp ~/.local/bin/xtool ~/.local/bin/xtool-1.24.0-original && install -m 755 xtool-x86_64.AppImage ~/.local/bin/xtool
```

Keep the commit, the `ADD` list and the AppImage's sha256 together. Before a later install, `sha256sum
~/.local/bin/xtool` must still show the same value.

It reports itself as `xtool unversioned`. The first install may stop with "An Application Group with Identifier …
is not available": run it again, the group exists by then.
`scripts/install-dev` and `scripts/phone-shots` warn when `xtool --version` is 1.24.0 or older. SideStore installs
are not affected: SideStore registers the group itself ([SIDESTORE.md](SIDESTORE.md)).

After the first install with a fixed xtool, the group is `group.XTL-<ID>.com.qantrex.homelab` (xtool's prefix, read
from the profile, see `AppGroup.swift`). The app copies the server list, settings and cache from its own folder into
the group on its first start (`Storage.adoptFiles`), so nothing has to be set up again; the Keychain tokens stay where
they are. Open the app once so it writes the widgets' snapshot. Widgets already on the Home Screen pick it up with
their next reload; remove and add them again if one still shows the old text after a minute.

### Known xtool bug: recorded SDK version on Linux builds

Linux builds record the deployment target (iOS 18) as the SDK version in the binary
([xtool issue #351](https://github.com/xtool-org/xtool/issues/351)). The minimum iOS is correct, so the app
installs on iOS 18 and newer. Only an App Store upload would be refused, and this app doesn't use the App Store.
CI never builds an IPA to install: releases are built by hand ([RELEASE.md](RELEASE.md)).

## Tests

Only `HomelabKit` (models, clients, URL rules, the notification diff, App Group logic) builds on Linux. SwiftUI,
WidgetKit, Keychain and BackgroundTasks don't exist there. `KIT_ONLY=1` makes `Package.swift` leave out the app
targets.

| Command | Needs | Runs |
|---|---|---|
| `scripts/test-linux` | docker, python3 | Same as the CI `linux` job: fixture server on `127.0.0.1:8791`, `KIT_ONLY=1 swift test` in `swift:6.4-noble`, the reference server's Python tests, `scripts/lint` |
| `KIT_ONLY=1 swift test` | Swift 6.4 | The HomelabKit tests. The integration tests are skipped unless `HOMELAB_FIXTURE_URL` is set |
| `python3 -m unittest -v server/test_reference_server.py` | python3 | The reference server's tests |
| `scripts/lint` | bash, grep (python3 3.11+ for the registry) | No `print(`/`NSLog(` in `Sources/`, no token-ish values in log calls, no `try!`/`fatalError(` in HomelabKit, the feature registry (`scripts/features check`) |

To run the integration tests natively, start the fixture server first:

```bash
python3 server/reference_server.py --fixtures Sources/HomelabKit/Fixtures --port 8791 &
HOMELAB_FIXTURE_URL=http://127.0.0.1:8791 KIT_ONLY=1 swift test
```

On macOS, `scripts/sim-smoke APP OUT` installs a simulator build and takes screenshots of every screen. Build the
simulator app with `xtool dev build --triple arm64-apple-ios-simulator`. CI runs this on every push, see
[CI.md](CI.md).

## Looking at the app on a real iPhone

`scripts/phone` drives the Homelab app that is installed on the phone over USB, whatever installed it (SideStore or
xtool), with real data and without a second app. It's meant for people and for a coding agent alike:

| Command | What |
|---|---|
| `scripts/phone apps` | Installed Homelab and SideStore apps, versions, and when their signing expires |
| `scripts/phone launch -HomelabTab lab` | Start the app with launch arguments (below) |
| `scripts/phone shot NAME [ARGS…]` | Launch, wait, save `shots-phone/NAME.png` |
| `scripts/phone tabs [--ax]` | One screenshot per tab; `--ax` at the largest accessibility text size |
| `scripts/phone log [SECONDS]` | The app's log lines for a while (default 20 s) |
| `scripts/phone crashes [--pull DIR]` | The app's crash reports |
| `scripts/phone push-ipa [IPA]` | Copy an IPA into SideStore's folder, then install it there (My Apps → + → On My iPhone → SideStore) |

The phone must be unlocked; black screenshots or a failed launch mean it's locked. `scripts/phone-shots` is the demo
screenshot set; on a phone where SideStore installed the app, run it with `--no-install`.

## Launch arguments

For tests, screenshots and a quick first run. Pass them to the app at launch, for example in the simulator:

```bash
xcrun simctl launch --terminate-running-process booted com.qantrex.homelab -HomelabDemo YES -HomelabTab chat
```

| Argument | Effect |
|---|---|
| `-HomelabDemo YES` | Turns on the demo servers (a demo homelab and a demo Home Assistant, no network) and shows the demo homelab |
| `-HomelabDemo NO` | Removes the demo servers again (like the Demo servers switch in Settings); your own servers stay. `scripts/phone-shots` ends with it |
| `-HomelabDemoScene <scene>` | What the demo homelab shows in this launch: `calm` (default: an ordinary current day, all quiet, one proposal; `state-demo.json`) or `problem` (the stress scene for screenshots: an unhealthy and an exited container, a warning, U6 delays; `state-problem.json`) |
| `-HomelabServer <url>` | Adds a Homelab API server with this address (login: Tailscale / proxy) and shows it. The URL rules below apply |
| `-HomelabTab <tab>` | Opens a tab: `today`, `actions`, `chat`, `lab` or `settings` (`overview` and `home` mean Today). A tab that depends on a server feature (Actions, Chat) opens once the server's info shows it |
| `-HomelabResetState YES` | Deletes all servers, tokens, cached data and settings before the start |
| `-HomelabAction <name>` | Opens the Actions tab with that action's form (once the server lists it; dropped when it doesn't). Names as in `GET /actions`: `[a-z0-9][a-z0-9_-]*` |
| `-HomelabHost <host-id>` | Opens Lab with that host's details (once the state has the host; dropped when a newer state lacks it) |
| <code>-HomelabDeals list&#124;detail</code> | Opens the Deals screen (`detail`: with the first deal's detail). Needs a server with deals (the demo has them) |
| `-HomelabPins <ids>` | Sets the Home tiles of the Home Assistant server: entity ids separated by commas (`light.a,script.b`), at most 12; anything odd drops the whole argument |
| `-HomelabTileNames "<id>=<name>,…"` | Sets custom names for pinned Home tiles, for example `"light.wohnzimmer_lampen=Living room,script.homelab_radio_off=Alarm off"`. Ids as for `-HomelabPins`, names trimmed to one line of at most 24 characters and without commas; a bad id, an empty name or more than 12 entries drops the whole argument. Names only stick to pinned entities, so give `-HomelabPins` first (an earlier launch is enough). Home Assistant keeps its own names |
| `-HomelabTileIcons "<id>=<symbol>,…"` | Sets icons for pinned Home tiles, for example `"light.wohnzimmer_lampen=lamp.floor,script.homelab_goodnight=moon.stars"`. Symbols only from the app's list (`TileIcon.choices`: `lightbulb`, `lamp.floor`, `lamp.table`, `lamp.ceiling`, `sofa`, `sparkles`, `book`, `moon.stars`, `bed.double`, `sun.horizon`, `alarm`, `music.note`, `speaker.slash`, `radio`, `tv`, `power`); anything else, a bad id or more than 12 entries drops the whole argument. Like names, icons only stick to pinned entities |
| `-HomelabDensity <detail>` | Today's detail: `calm`, `standard` or `overkill` (stored like the setting) |
| `-HomelabPersonality <voice>` | The headline's personality: `off`, `dry`, `snarky` or `ultrakill` (stored like the setting) |

`YES`, `true` and `1` all count as yes. The links `homelab://today`, `homelab://actions`, `homelab://chat`,
`homelab://lab` and `homelab://settings` open a tab too (the widgets use them; the older `overview` and `home` open Today).
`homelab://actions/<name>` opens that action's form (`?arg=…&<field>=…` fills it in, see [SHORTCUTS.md](SHORTCUTS.md)),
`homelab://lab/<host-id>` a host's details. A form or host waits with its tab until the data is there; picking another
tab by hand drops the request, and a newer link replaces it.

URL rules (`Sources/HomelabKit/URLPolicy.swift`): `https://` always works. Plain `http://` only works for addresses
that stay in your home network or tailnet: private IPs (`10.x`, `172.16–31.x`, `192.168.x`), `127.x`, `169.254.x`,
Tailscale's `100.64–127.x`, `localhost`, names ending in `.local`, single-label
names (not all digits or `0x…`: those are IPv4 numbers), and local IPv6 (`::1`, `fe80:`, `fc`/`fd`). A trailing
`/api/v1` or `/api` is removed. User names and passwords in the URL are refused. A token (a token server, Home
Assistant) only goes over `https://`, or plain `http://` to this device (`localhost`, `127.0.0.1`, `::1`)
(`URLPolicy.allowsToken`, `ServerConfig.tokenTransportProblem` for the editor); otherwise the clients send nothing.

## Project layout

| Path | What it holds | Builds on Linux |
|---|---|---|
| `Sources/HomelabKit` | Foundation only: API models (tolerant decoding), Companion and Home Assistant clients, error texts, URL rules, storage, App Group lookup, notification diff, chat timeline, demo backend, fixtures | yes |
| `Sources/HomelabDesign` | Colours, symbols and small shared views for app and widget | no |
| `Sources/HomelabUI` | The SwiftUI screens, `AppModel`, Keychain token store, background refresh, Face ID lock | no |
| `Sources/Homelab` | The `@main` app: scene, deep links, notification taps, background task | no |
| `Sources/HomelabWidget` | The WidgetKit extension (status, day, hosts, U6, deadlines and to-do widgets and the Live Activity, static configuration only; no App Intents) | no |
| `Sources/HomelabShare` | The share extension (send a link, photo or PDF to the server; queued in the outbox when offline) | no |
| `Tests/HomelabKitTests` | Swift Testing tests for HomelabKit, plus integration tests against the fixture server | yes |
| `server/` | `openapi.yaml` (the API), `reference_server.py`, its tests, `config.example.json` | – |
| `scripts/` | Build, install, test, lint, screenshot and release helpers | – |
| `xtool.yml`, `App-Info.plist`, `Widget-Info.plist`, `Share-Info.plist`, `App.entitlements`, `Widget.entitlements`, `Share.entitlements`, `Resources/AppIcon.png` | What xtool needs to package the app and its two extensions | – |
| `.github/workflows/` | `ci.yml` (Linux + macOS checks only; CI never builds an app to install, see `docs/RELEASE.md`) | – |

No third-party Swift packages. The shared App Group is `group.com.qantrex.homelab`; SideStore renames it, see
[SIDESTORE.md](SIDESTORE.md).
