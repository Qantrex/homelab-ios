# Homelab iOS

A native iPhone app for a self-hosted homelab: what is up, what needs attention and what waits for your approval,
plus a chat with your homelab agent and your Home Assistant devices. It is built with SwiftPM and xtool and installed
with a free Apple ID, from Linux or a Mac, or with SideStore. Open source (MIT), no account, no cloud.

The [README on GitHub](../README.md) has the screenshots, the quick start and the limits.

## Docs

- [Features](FEATURES.md): every feature, where it lives, its tests, phone checks, docs and dependencies
- [Setup](SETUP.md): building with xtool, tests, project layout
- [Install from Linux](INSTALL-FROM-LINUX.md): onto an iPhone over USB, no Mac
- [SideStore](SIDESTORE.md): installing and the 7-day refresh, the -80045 fix
- [Server setup](SERVER-SETUP.md): connecting a homelab (reference server, Home Assistant, your own server)
- [API](API.md): the Companion API in plain words, for writing your own server
- [Adapting](ADAPTING.md): fork it for your homelab, turn modules off, add your own
- [Security](SECURITY.md): threat model, what the app does, what server operators must do
- [Design](DESIGN.md): how every screen and widget looks
- [Release](RELEASE.md): building and publishing a release by hand
- [Shortcuts](SHORTCUTS.md): `homelab://` links, Shortcuts recipes, quick actions
- [Plan: Homelab for other homelabs](plans/MODULAR.md): making the app useful without the owner's services

Also: [Reference server](REFERENCE_SERVER.md) options, [CI](CI.md), the [changelog](../CHANGELOG.md) and the
[phone checks](../DeviceTest.md).
