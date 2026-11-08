# Install from Linux

Install Homelab on an iPhone from a Linux PC over USB, no Mac. Tested setup (2026-11-07): Arch Linux, iPhone 12 mini
with iOS 18.7.3, a free Apple ID, xtool 1.24.0 with the App Group patch below. The owner installs the app this way
and uses it every day. The app needs iOS 18 or newer.

**Windows:** building needs Linux or macOS. xtool's docs describe Windows only through WSL with USB passthrough; WSL2
is untested here. See [SETUP.md](SETUP.md).

There is no release yet, so there is no IPA to download until the owner calls a version 1.0.0. Two ways: **A** would
install a released IPA (no Swift or Xcode needed), but needs a release. **B** builds on your PC; it is the only way
today, and it also runs the newest code. B needs a download of about 2 GB from Apple (Apple ID login) once, see
[SETUP.md](SETUP.md).

## Once: tools and Apple ID

Install git, usbmuxd (talks to the iPhone over USB), libimobiledevice and FUSE 2 (the xtool AppImage needs it) with
your distro's package manager:

```bash
# Arch
sudo pacman -S --needed git usbmuxd libimobiledevice fuse2
# Debian / Ubuntu (Ubuntu 24.04 and newer: libfuse2t64)
sudo apt install git usbmuxd libimobiledevice-utils libfuse2
# Fedora (package names not tested here)
sudo dnf install git usbmuxd libimobiledevice-utils fuse-libs
```

Get xtool as in [SETUP.md](SETUP.md) ("xtool and the iOS SDK": a pinned version with its sha256 listed there):

```bash
XTOOL_VERSION=1.24.0
case $(uname -m) in
  x86_64)  XTOOL_SHA256=dbfd9d7216f077c84c171b688c4173c37c23ca76bf7fd185d1a9ae8a53dab59f ;;
  aarch64) XTOOL_SHA256=4bc0515fed71efb86e82564f358efa0c4c6d76bf1bcfd4c5f256727b53ec59c8 ;;
esac
mkdir -p ~/.local/bin && curl -fL "https://github.com/xtool-org/xtool/releases/download/$XTOOL_VERSION/xtool-$(uname -m).AppImage" -o ~/Downloads/xtool-$XTOOL_VERSION.AppImage
echo "$XTOOL_SHA256  $HOME/Downloads/xtool-$XTOOL_VERSION.AppImage" | sha256sum -c -   # must say OK, then:
install -m 755 ~/Downloads/xtool-$XTOOL_VERSION.AppImage ~/.local/bin/xtool
```

Widgets on a USB install need `xtool --version` newer than 1.24.0, or 1.24.0 patched as in
[SETUP.md](SETUP.md#only-for-usb-installs-with-widgets-patched-xtool) (a one-line change and a Docker build). An
unpatched 1.24.0 or older drops the App Group for a free Apple ID, and the widgets then never show data. The app itself
works, and installing the built IPA with SideStore ([SIDESTORE.md](SIDESTORE.md)) needs no patch.

```bash
xtool auth
```

Pick **Password** (free Apple ID; xtool talks to Apple only). A throwaway Apple ID is fine.

Plug the phone in with a cable, unlock it, tap **Trust** and enter the passcode. Check that the PC sees it:

```bash
xtool devices
```

## A: install a released IPA (no Swift, no Xcode)

Once there is a release (built by hand, see [RELEASE.md](RELEASE.md); none exists yet), download `Homelab-<version>.ipa` from the
[release page](https://github.com/Qantrex/homelab-ios/releases), then:

```bash
xtool install ~/Downloads/Homelab-*.ipa
```

Until the first release, use B.

## B: build on the PC

Needs Swift 6.4 and the iOS SDK from Xcode 27.1 (download `Xcode_27.1.xip`, about 2 GB, in the browser from
[developer.apple.com/download](https://developer.apple.com/download/all/?q=Xcode), Apple ID login). Swift 6.4:

```bash
# Arch: from the AUR (any AUR helper, or makepkg)
yay -S swift-bin
# Debian / Ubuntu / Fedora: swiftly, see the Swift block in SETUP.md (https://www.swift.org/install/linux/)
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
3. Open **Homelab**. Try the demo, or add your server (Tailscale on: [TAILSCALE.md](TAILSCALE.md)).

## Good to know

| Thing | What to do |
|---|---|
| The app stops opening after 7 days | Free Apple ID certificates last 7 days. Today warns 2 days before ("This install stops opening in 2 days …"), and Settings → Advanced → Diagnostics → Install expires shows the date. Plug the phone in and run the install again (A, or `xtool dev` / `scripts/install-dev` for B) before then: servers, tokens, settings and widgets stay. SideStore refreshes by itself ([SIDESTORE.md](SIDESTORE.md)) |
| `xtool devices` is empty | Unlock the phone, re-plug, tap Trust. Check `systemctl status usbmuxd` (udev starts it when the phone is plugged in) |
| `Error: … maximum number of apps` | A free Apple ID allows 3 sideloaded apps and 10 new App IDs per week. Each install registers **3** App IDs (app, widget, share extension), so about three fresh installs a week. Remove an old test app |
| "Homelab" is missing in the share sheet | Share sheet → scroll the app row to the end → More → switch Homelab on. Open the app once first |
| The widget shows "Open the app" | Open the app once; it writes the data the widget shows |
| Widgets say "No App Group: see Diagnostics" | xtool dropped the App Group (1.24.0 or older without the patch). Install again with a fixed xtool, see [SETUP.md](SETUP.md) |
| Something else | Settings → Advanced → Diagnostics → Copy report (host names with the tailnet part masked, no tokens), and paste it into `DeviceTest.md` or an issue |
