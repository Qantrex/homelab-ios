# Spike: is xtool + SideStore viable? (throwaway, 2026-11-04)

This branch is a tiny app with **no real features**. It exists to prove, on a real iPhone, the parts that reading
source code can't prove. The real app is written only after every test below passes. Delete this branch afterwards.

The app has one screen with a section per test, and a **Copy report** button. The widget shows a counter the app
writes, and the App Group it found.

## What is already proven without a phone

| Check | Result |
|---|---|
| Shared code (`SpikeShared`) on Linux, Swift 6.4.2 | 9/9 tests pass: `KIT_ONLY=1 swift test` (in Docker: `swift:6.4-noble`) |
| macOS CI: IPA, entitlements, simulator, screenshot | test S8 below, the `spike` workflow on every push |

## Owner: build and install (bauarch-pc, Arch)

One-time setup:

```bash
sudo pacman -S --needed usbmuxd libimobiledevice fuse2
```

```bash
yay -S swift-bin   # or the Swift 6.4 tarball from swift.org/install/linux
```

```bash
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o ~/.local/bin/xtool && chmod +x ~/.local/bin/xtool
```

Download **Xcode 27.1** in the browser (Apple login) from https://developer.apple.com/download/all/?q=Xcode, then:

```bash
xtool sdk install ~/Downloads/Xcode_27.1.xip
```

No `xtool auth` is needed: SideStore signs the app, so xtool never sees an Apple ID.

Build (S1):

```bash
cd ~/Projects && git clone -b spike https://github.com/Qantrex/homelab-ios && cd homelab-ios
```

```bash
xtool dev build --ipa
```

The IPA is in `xtool/`. Or take the CI one: Actions → `spike` → artifact `ipa-macos-26`. Send it to the phone
(AirDrop/Files/LocalSend) → **Share → SideStore** (or SideStore → My Apps → +).

## Tests

Fill in the results in `Day Test iOS Spike.md` (homelab vault): ✅ / ⚠️ / ❌ plus the pasted report.

| # | Test | Pass when |
|---|---|---|
| S1 | `xtool dev build --ipa` on bauarch-pc | It ends without an error, and `unzip -l xtool/*.ipa` lists `Payload/Homelab.app/PlugIns/HomelabWidget.appex` |
| S2 | SideStore install (free Apple ID) | "Homelab Spike" opens. SideStore → My Apps shows it, and the active-app count is 2 of 3 |
| S3 | Widget | Long-press the home screen → + → "Homelab Spike" is listed. Add the small one. Tap "Counter +1" in the app: within a minute the widget shows the new number. "Widget last read" in the app has a time |
| S4 | App Group after SideStore's rewrite | The app's **S4** section shows one ✅ group, and the widget shows the **same** group name (not "NO GROUP") |
| S5 | Tailnet request, no token | Tailscale on. URL `https://pi-utility.<tailnet>.ts.net/api/state` → **HTTP 200** (agent-chat accepts the `Tailscale-User-Login` header that `tailscale serve` adds). A 403 means the header didn't arrive: then run `ssh pi-two 'journalctl -u agent-chat -n 20 \| grep denied'` and paste the line |
| S6 | Keychain + background | Kill the app (swipe up), open again: Keychain shows the **same** time as before. After a day of normal use: "Background refresh → Runs" is above 0 |
| S7 | SideStore refresh | SideStore → My Apps → Refresh All. Open the app: the counter, the Keychain time and the saved URL are all still there. The widget still works |
| S8 | macOS CI (Claude checks it) | The `spike` workflow passes "S8a" (IPA with the widget and App Group entitlements in both) on at least one macOS runner, and ideally S8b/S8c (simulator + screenshot) |

Tap the widget: the app opens and "Deep link" shows `homelab://spike` (extra check of the widget URL).

## If something fails

| Fails | Then (decided before the test) |
|---|---|
| S4 | The widget fetches from the server itself (servers with Tailscale auth only; it never gets tokens) |
| S5 | API v1 also accepts a per-device bearer token |
| S6 background | No local notifications; widgets refresh on their own timeline only |
| S8 simulator | CI builds the IPA and runs the shared tests; no screenshots |
| S8 completely | CI runs only the Linux tests; the owner builds release IPAs on bauarch-pc |
| S1 or S2 | Stop. Plan B: a PWA. The owner decides |
