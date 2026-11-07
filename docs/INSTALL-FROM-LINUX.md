# Install on your iPhone from Linux (Arch)

Tested setup (2026-11-07): Arch Linux, iPhone 12 mini with iOS 18.7.3, a free Apple ID, xtool 1.24.0 with the App
Group patch below. The owner installs the app this way and uses it every day. The app needs iOS 18 or newer.

Two ways. **A** installs a released IPA (no Swift or Xcode needed). **B** builds on your PC; use it until the
first release, or to run the newest code.

## Once: tools and Apple ID

```bash
sudo pacman -S --needed git usbmuxd libimobiledevice fuse2
```

Get xtool as in [SETUP.md](SETUP.md) ("xtool and the iOS SDK": a pinned version, its sha256 checked):

```bash
XTOOL_VERSION=1.24.0
mkdir -p ~/.local/bin && curl -fL "https://github.com/xtool-org/xtool/releases/download/$XTOOL_VERSION/xtool-$(uname -m).AppImage" -o ~/Downloads/xtool-$XTOOL_VERSION.AppImage
sha256sum ~/Downloads/xtool-$XTOOL_VERSION.AppImage   # compare with the value you recorded, then:
install -m 755 ~/Downloads/xtool-$XTOOL_VERSION.AppImage ~/.local/bin/xtool
```

`xtool --version` must be newer than 1.24.0, or 1.24.0 patched as in [SETUP.md](SETUP.md) ("Known xtool bug: no
App Group", a one-line change and a Docker build). An unpatched 1.24.0 or older drops the App Group for a free
Apple ID, and the widgets then never show data.

```bash
xtool auth
```

Pick **Password** (free Apple ID; xtool talks to Apple only). A throwaway Apple ID is fine.

Plug the phone in with a cable, unlock it, tap **Trust** and enter the passcode. Check that the PC sees it:

```bash
xtool devices
```

## A: install a released IPA (no Swift, no Xcode)

Once there is a release (built by hand, see [RELEASE.md](RELEASE.md)), download `Homelab-<version>.ipa` from the
[release page](https://github.com/Qantrex/homelab-ios/releases), then:

```bash
xtool install ~/Downloads/Homelab-*.ipa
```

Until the first release, use B.

## B: build on the PC

Needs Swift 6.4 and the iOS SDK from Xcode 27.1 (download `Xcode_27.1.xip` in the browser from
https://developer.apple.com/download/all/?q=Xcode, Apple login).

```bash
yay -S swift-bin   # from the AUR (any AUR helper, or makepkg)
```

```bash
xtool sdk install ~/Downloads/Xcode_27.1.xip
```

```bash
git clone https://github.com/Qantrex/homelab-ios ~/Projects/homelab-ios && cd ~/Projects/homelab-ios && xtool dev
```

`xtool dev` builds, signs with your Apple ID and installs over USB. The first build takes a few minutes.

## On the phone (first time)

1. iOS 18 needs **Developer Mode** for apps you sign yourself: Settings → Privacy & Security → Developer Mode → on,
   restart, confirm. (The switch shows up after the first install attempt.)
2. Trust your Apple ID: Settings → General → VPN & Device Management → **Developer App** → your Apple ID → Trust.
3. Open **Homelab**. Try the demo, or add your server (Tailscale on).

## Good to know

| Thing | What to do |
|---|---|
| The app stops opening after 7 days | Free Apple ID certificates last 7 days. Today warns 2 days before ("This install stops opening in 2 days …"), and Settings → Diagnostics → Install expires shows the date. Plug the phone in and run the install again (A, or `xtool dev` / `scripts/install-dev` for B) before then: servers, tokens, settings and widgets stay. SideStore refreshes by itself, but it is not verified with this app yet ([SIDESTORE.md](SIDESTORE.md)) |
| `xtool devices` is empty | Unlock the phone, re-plug, tap Trust. Check `systemctl status usbmuxd` (udev starts it when the phone is plugged in) |
| `Error: … maximum number of apps` | A free Apple ID allows 3 sideloaded apps and 10 new App IDs per week. Each install registers **3** App IDs (app, widget, share extension), so about three fresh installs a week. Remove an old test app |
| "Homelab" is missing in the share sheet | Share sheet → scroll the app row to the end → More → switch Homelab on. Open the app once first |
| The widget shows "Open the app" | Open the app once; it writes the data the widget shows |
| Widgets say "No App Group: see Diagnostics" | xtool dropped the App Group (1.24.0 or older without the patch). Install again with a fixed xtool, see [SETUP.md](SETUP.md) |
| Something else | Settings → Diagnostics → Copy report (host names with the tailnet part masked, no tokens), and paste it into `DeviceTest.md` or an issue |
