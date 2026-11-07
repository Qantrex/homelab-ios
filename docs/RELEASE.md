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
(cd dist && sha256sum -c "Homelab-$V.ipa.sha256") && scripts/phone push-ipa "dist/Homelab-$V.ipa"
```

`push-ipa` copies the IPA into SideStore's folder. On the phone: SideStore → My Apps → + → the IPA. (Without
SideStore, `xtool install "dist/Homelab-$V.ipa"` over USB also works.)

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

The release channel is IPA + SHA-256 + `source.json`. SideStore has installed Homelab since 2026-11-07 (after the
-80045 fix in [SIDESTORE.md](SIDESTORE.md)); the source URL itself can only be checked once the release exists.

**Decided 2026-11-07: publish `source.json` too.** Right after the release, add the source URL once in SideStore on
the test phone (Sources → +) and check that Homelab shows up and offers the update (DeviceTest I1/I2). If that fails,
delete `source.json` from the release assets (`gh release delete-asset`); the IPA stays.

## Homelab Bridge image

The Docker image of the Homelab Bridge ([SERVER-SETUP.md → Docker](SERVER-SETUP.md#docker)) is
`ghcr.io/qantrex/homelab-bridge`. Like the IPA it is built and pushed by hand (owner, 2026-11-07); CI only builds and
tests it (job `bridge-image`) and never publishes.

1. CI green on the commit, and a clean checkout of it.
2. Once per machine: `docker login ghcr.io -u Qantrex` with a token that has `write:packages`, and docker buildx plus
   QEMU binfmt for the other platform (on Arch: `docker-buildx` and `qemu-user-static-binfmt`).
3. Build, test and push:

   ```bash
   scripts/build-bridge-image --push      # tags <commit date>-<short sha> and latest, linux/amd64 and linux/arm64
   ```

   It runs `--test` first (server tests inside the image, `check-live-api` against it) and stops on any failure or
   uncommitted change. Without `--push` it only builds (and with `--test` tests) the image for this machine.
4. The first push makes a private package: on GitHub, Packages → homelab-bridge → Package settings → Change
   visibility → Public. The image's source label links it to this repo.

## Notes

- A Linux build records a wrong SDK version (xtool issue #351). That only matters for the App Store; SideStore and
  `xtool install` don't care, and the minimum iOS (18) is right.
- No GitHub Pages and no workflow are needed. Everything is a file on the release.
