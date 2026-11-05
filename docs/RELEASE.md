# Releasing (by hand, from your own build)

Rule (owner, 2026-11-04): **CI never builds the app you install or share.** CI only checks (tests, compile,
simulator screenshots). You build the IPA yourself with xtool and publish it.

## 1. Build

On the Arch PC (setup: [INSTALL-FROM-LINUX.md](INSTALL-FROM-LINUX.md), way B):

```bash
cd ~/Projects/homelab-ios && git pull && scripts/build-ipa
```

The IPA is under `xtool/`. Install it on your phone first and run [DeviceTest.md](../DeviceTest.md).

## 2. Write the SideStore source

```bash
V=1.0.0
```

```bash
mkdir -p dist && cp xtool/*.ipa "dist/Homelab-$V.ipa" && (cd dist && sha256sum "Homelab-$V.ipa" > "Homelab-$V.ipa.sha256")
```

```bash
curl -fsSL -o dist/previous-source.json https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json || rm -f dist/previous-source.json
```

```bash
scripts/make-source --version "$V" --ipa "dist/Homelab-$V.ipa" --download-url "https://github.com/Qantrex/homelab-ios/releases/download/v$V/Homelab-$V.ipa" $( [ -f dist/previous-source.json ] && echo --previous dist/previous-source.json ) --output dist/source.json
```

`--previous` keeps the older versions in the source. A version with a `-` (`1.1.0-beta.1`) is a pre-release.

## 3. Publish

```bash
git tag "v$V" && git push origin "v$V"
```

```bash
gh release create "v$V" "dist/Homelab-$V.ipa" "dist/Homelab-$V.ipa.sha256" dist/source.json --title "Homelab $V" --generate-notes
```

People add this source in SideStore once, and it always points at the newest release:

`https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json`

(`latest` skips pre-releases. For a pre-release, give testers the URL with the tag:
`https://github.com/Qantrex/homelab-ios/releases/download/v<version>/source.json`.)

## Notes

- A Linux build records a wrong SDK version (xtool issue #351). That only matters for the App Store; SideStore and
  `xtool install` don't care, and the minimum iOS (18) is right.
- No GitHub Pages and no workflow are needed. Everything is a file on the release.
