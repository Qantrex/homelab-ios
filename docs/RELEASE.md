# Releasing (by hand, from your own build)

Rule (owner, 2026-11-04, 2026-11-05): **every app build is done locally; CI never builds the app you install or share.**
CI only tests and checks (tests, lint, a simulator build for the screenshots). You build the IPA yourself with xtool and publish it.

There is no release yet (2026-11-07). Open decision for the owner before the first one: see "Open decision" at the end.

## 0. Bump the version

The version lives in three Info.plists, and all three must say the same: `App-Info.plist`, `Widget-Info.plist` and
`Share-Info.plist`. `CFBundleShortVersionString` is the version people see (`1.0.0`), `CFBundleVersion` the build
number (count it up by one for every release, also a pre-release). The app reads them (`AppVersion`, shown in
Settings → Diagnostics); `xtool.yml` has no version of its own.

```bash
V=1.0.0
grep -A1 -E 'CFBundleShortVersionString|CFBundleVersion' App-Info.plist Widget-Info.plist Share-Info.plist
```

Edit the six values, give `CHANGELOG.md` a heading `## $V (<date>)` instead of "unreleased", commit and push to
`main`.

## 1. CI green on the commit you tag

The commit you build and tag must have a green CI run (CI runs on pushes to branches, not on tags):

```bash
git switch main && git pull && git status --short   # must print nothing
SHA=$(git rev-parse HEAD)
gh run list --commit "$SHA" --workflow ci.yml       # every run "completed  success"
```

Wait until it is green. A red or missing run: fix first, then start again at step 0 or 1.

## 2. Build

On the Arch PC (setup: [INSTALL-FROM-LINUX.md](INSTALL-FROM-LINUX.md), way B), at exactly that commit:

```bash
cd ~/Projects/homelab-ios && [ "$(git rev-parse HEAD)" = "$SHA" ] && scripts/build-ipa
```

The IPA is under `xtool/`. `scripts/build-ipa` runs `scripts/verify-ipa` (widget inside, App Group on both).

## 3. Write the SideStore source

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
`make-source` warns when the IPA's version is not `$V` (step 0 forgotten).

## 4. Install the exact IPA you will publish and test it

Not a fresh `xtool dev` build: the file in `dist/`.

```bash
(cd dist && sha256sum -c "Homelab-$V.ipa.sha256") && xtool install "dist/Homelab-$V.ipa"
```

On the phone: Settings → Diagnostics shows `$V` and the build number from step 0. Then go through the
**release-blocking rows** of [DeviceTest.md](../DeviceTest.md) (listed at its top) with a real server, and write the
date, phone, iOS and version in its header. Every ❌ in a release-blocking row stops the release.

## 5. Publish

Tag the commit you built and tested:

```bash
git tag "v$V" "$SHA" && git push origin "v$V"
```

```bash
gh release create "v$V" "dist/Homelab-$V.ipa" "dist/Homelab-$V.ipa.sha256" dist/source.json --verify-tag --title "Homelab $V" --generate-notes
```

People add this source in SideStore once, and it always points at the newest release:

`https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json`

(`latest` skips pre-releases. For a pre-release, give testers the URL with the tag:
`https://github.com/Qantrex/homelab-ios/releases/download/v<version>/source.json`.)

## Release channel (decided 2026-11-07)

SideStore was tested with Homelab on 2026-11-07 (after the -80045 fix in [SIDESTORE.md](SIDESTORE.md)); the source
(`source.json`) itself is not tested yet. For the first release, choose one:

| Option | For | Against |
|---|---|---|
| Publish `source.json` too (steps 3 and 5 as written) | SideStore users get updates from the start | Adding the source URL in SideStore is not tested yet (installing the IPA is) |
| Publish only the IPA and its SHA-256 (leave `dist/source.json` out of `gh release create`) | Only what was tested: the IPA, installed with xtool or imported in SideStore | No updates through a SideStore source; the source URL above stays empty |

**Decided 2026-11-07: publish `source.json` too.** Right after the release, add the source URL once in SideStore on
the test phone (Sources → +) and check that Homelab shows up and offers the update (DeviceTest I1/I2). If that fails,
delete `source.json` from the release assets (`gh release delete-asset`); the IPA stays.

## Notes

- A Linux build records a wrong SDK version (xtool issue #351). That only matters for the App Store; SideStore and
  `xtool install` don't care, and the minimum iOS (18) is right.
- No GitHub Pages and no workflow are needed. Everything is a file on the release.
