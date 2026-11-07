# Homelab iOS

A native iPhone app for a self-hosted homelab. It shows what is up, what needs attention and what waits for your
approval. It can chat with your homelab agent and switch Home Assistant devices. Open source, MIT, no account, no
cloud.

It is built with SwiftPM and [xtool](https://github.com/xtool-org/xtool), so you don't need a Mac or a paid Apple
developer account. You install it with [SideStore](https://sidestore.io) and a free Apple ID.

## What it does

| Tab | What you see and do |
|---|---|
| Today | Your day first. On top, how the lab is doing in two words ("All quiet." or "1 problem.", calm or loud); tap it for Lab. Under it the server's "today" card as a line through the day (wake-up → leave by → first lesson) that fills up to now and counts down to the next stop. Then actions waiting for you, your pinned Home Assistant tiles (tap to toggle or run), the other cards (downloads and what's playing with progress rings, school, parcels, …): a to-do list with a circle per item (tap it to tick the item off, after one confirm) and an "+ Add" button that opens the form prefilled, deadlines counting down ("2 d", gold today, love when past), and the last report. Settings → Today: reorder or hide sections, and pick Calm, Standard or Overkill (everything, with every machine's numbers and exact times). Pull to refresh; refreshes every 30 s while open |
| Actions | Start: tiles for the actions your server lets you start (add a to-do, set tomorrow's wake-up, restart a container, …); each opens a small form, asks once and runs at once. Below: actions your homelab proposes, with reason and age. Approve, Always or Deny, each with a confirm step. Shows the server's answer. Approve and Deny also right on the "waiting for you" notification; your three most used actions as Home-screen quick actions; links like `homelab://actions/todo-add?summary=Milk` open a form filled in (Shortcuts, [docs/SHORTCUTS.md](docs/SHORTCUTS.md)) |
| Scan and share | If the server has `documents`: a Scan tile on Actions (and a Home-screen quick action, or `homelab://scan`) opens the document camera and sends the PDF to Paperless. The share extension "Homelab" in the share sheet sends a link (a willhaben ad gets a price check, other links a read-later list), a PDF, or photos (made into one PDF) to your server. Offline or on a token server, items wait in an outbox and the app sends them later |
| Chat | Chat with your homelab agent. "Working…" while it runs, report tags (`morning`, `watchdog`, …), long-press to copy, a "/" button with the commands the server lists (each with what it does; typing "/" suggests them too), Clear (hides the chat on this phone; the server keeps it). Proposals in a reply have Approve, Always and Deny right in the bubble (same confirm as Actions; gone once answered); cards in a reply show small under the text |
| Deals | On the Actions tab (a Deals tile, `homelab://deals`) and as a section on Today while a strong one is fresh: used-market ads far below their market value that your server found and judged (price, −50 %, confidence, warnings in gold, the comparable ads, open or copy the ad). Only with a server that offers `/deals` |
| Lab | Problems, a tile per host (load, RAM, worst disk, temperature, containers, flags, a 24 h load line), tap a host for details: 24 h sparklines for load, memory, temperature and disk, and its containers (problems first) with Restart for the ones on its restart list. A launcher for your web UIs (opens Safari) |
| Settings | Several servers ("Show data from" picks the one for Today, Lab, Actions and Chat; "Home tiles from" the Home Assistant), test connection, Today's sections and detail, a personality (Off, Dry or Snarky: one line of commentary under the headline, on empty screens and in notifications; off by default), notifications, Face ID lock, demo mode, Diagnostics |

Tabs appear only when they make sense: Actions and Chat only if the server offers them. Home Assistant tiles appear on
Today when you add a Home Assistant server.

**Widgets** (read-only, from the last data the app fetched):

| Widget | Sizes | Shows |
|---|---|---|
| Homelab status | small, lock screen (circular, rectangular, inline) | Today's headline ("All quiet.", "1 problem.") in its colour with the glow, the first problem, actions waiting |
| Homelab day | small, medium, lock screen (rectangular, inline) | The "today" card's day line: the next stop big with its countdown (small, lock screen), every stop on the line (medium) |
| Homelab hosts | medium (4 hosts), large (8 hosts + problems) | The headline, then each host with load, RAM and disk |

The day widget redraws every minute while a stop is less than an hour away. Tapping a widget opens the right tab. Data older than 2 hours is dimmed and says how old it is. The status text is
hidden on the lock screen while the phone is locked. With the app lock on, the widgets show only counts: no problem
text, host names or day.

## Who it is for

Anyone with a homelab and Tailscale (or another VPN) on the phone. You need one of these:

| You have | Use |
|---|---|
| Nothing special: a Linux box with some Docker apps | The [reference server](docs/REFERENCE_SERVER.md): one Python file, no dependencies |
| Home Assistant | Add it directly with a long-lived token (tiles on Today) |
| Your own agent or scripts | Implement the small JSON API in [`server/openapi.yaml`](server/openapi.yaml) |

You can combine them, for example the reference server plus Home Assistant. **Try the demo** on the first screen to
look around without any server.

## Screenshots

| Today | Actions | Chat |
|---|---|---|
| ![Today](docs/screenshots/01-today.png) | ![Actions](docs/screenshots/02-actions.png) | ![Chat](docs/screenshots/03-chat.png) |

| Lab | Settings | Dark mode |
|---|---|---|
| ![Lab](docs/screenshots/04-lab.png) | ![Settings](docs/screenshots/05-settings.png) | ![Dark mode](docs/screenshots/06-dark.png) |

## Install

> **Status (2026-11-04): no release yet.** The app is tested in CI and the simulator, not yet on a real iPhone.
> Until the first release, build and install it yourself: [docs/INSTALL-FROM-LINUX.md](docs/INSTALL-FROM-LINUX.md)
> (Linux) or [docs/SETUP.md](docs/SETUP.md) (macOS). Releases are built by hand, never by CI
> ([docs/RELEASE.md](docs/RELEASE.md)).

| Way | Good for | How |
|---|---|---|
| SideStore source | Most people. Updates show up in SideStore | In SideStore: Sources → + → `https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json` (from the first release on) |
| IPA from GitHub Releases | One version, no source | Download `Homelab-<version>.ipa` from [Releases](https://github.com/Qantrex/homelab-ios/releases), then SideStore → My Apps → + |
| Build it yourself | Developers | xtool on Linux or macOS, see [docs/SETUP.md](docs/SETUP.md). From Linux straight to a phone over USB: [docs/INSTALL-FROM-LINUX.md](docs/INSTALL-FROM-LINUX.md) |

Details and troubleshooting: [docs/SIDESTORE.md](docs/SIDESTORE.md). Needs iOS 18 or newer.

## Quick start (a homelab with nothing yet)

On a Debian/Ubuntu server that is in your tailnet. Once per tailnet, in the Tailscale admin console → DNS: turn on
**MagicDNS** and **HTTPS Certificates** (`tailscale serve --https` needs both).

```bash
git clone https://github.com/Qantrex/homelab-ios && cd homelab-ios
printf '%s\n' '{"name": "homeserver", "trust_identity_header": "Tailscale-User-Login",' \
  ' "allowed_logins": ["you@example.com"], "this_host": {"kind": "server", "disks": ["/"]}}' > config.json
python3 server/reference_server.py --config config.json
```

Put your Tailscale login in `allowed_logins` (a refused login is printed in the log, so you can copy it). The full
example with hosts, checks and services is `server/config.example.json`.

In a second shell, publish it in your tailnet (pick a free port, `tailscale serve status` shows the used ones;
`tailscale serve` replaces what already runs on that port):

```bash
sudo tailscale serve --bg --https=7443 http://127.0.0.1:8791
```

On the iPhone, with Tailscale on: Homelab → **Add a server** → Type **Homelab API**, Address
`https://<machine>.<tailnet>.ts.net:7443`, Login **Tailscale / proxy** → **Test connection** → **Save**.

To run it for good (systemd), and for cards, actions and chat: [docs/SERVER-SETUP.md](docs/SERVER-SETUP.md).

## Limits

Honest list. Most come from the free Apple ID and from building without Xcode.

| Limit | Why |
|---|---|
| No Siri, no Shortcuts, no buttons in widgets, no Control Center | These need App Intents, and xtool can't build them yet |
| No Apple push notifications | APNs needs a paid developer account. The app can check in the background and send a local notification, but iOS decides when that runs (often every 15–60 minutes, sometimes much less) |
| Refresh every 7 days | Apps signed with a free Apple ID expire after 7 days. SideStore refreshes them over Wi-Fi; open SideStore now and then |
| 3 active apps | A free Apple ID allows 3 sideloaded apps, SideStore is one. The widget and the share extension don't count, so Homelab uses one slot (but 3 of the 10 new App IDs a week) |
| One Home Assistant | The Home tab uses the first Home Assistant server you add |
| iPhone only, portrait | No iPad layout |

## Privacy

- The app talks only to the servers you add. No analytics, no crash reporting, no third-party code.
- Tokens are stored in the iOS Keychain on this phone only (not synced, not in backups to other devices). They are
  never written to files or logs and never given to the widget.
- Cached data (the last status per server) stays in the app's own storage so the widget and offline view can show it.
- Settings → Reset everything deletes all servers, tokens, cached data and settings.

More: [docs/SECURITY.md](docs/SECURITY.md).

## Docs

| Doc | For |
|---|---|
| [docs/SIDESTORE.md](docs/SIDESTORE.md) | Installing, the 7-day refresh, troubleshooting |
| [docs/SERVER-SETUP.md](docs/SERVER-SETUP.md) | Connecting a homelab: reference server, Home Assistant, your own server |
| [docs/REFERENCE_SERVER.md](docs/REFERENCE_SERVER.md) | All options of the reference server |
| [server/openapi.yaml](server/openapi.yaml) | The Homelab Companion API v1 |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, what the app does, what server operators must do |
| [docs/SETUP.md](docs/SETUP.md) | Building with xtool, tests, project layout |
| [docs/CI.md](docs/CI.md) | CI and releases |
| [docs/INSTALL-FROM-LINUX.md](docs/INSTALL-FROM-LINUX.md) | Installing from a Linux PC over USB (no Mac) |
| [docs/API.md](docs/API.md) | The API in plain words, for writing your own server |
| [docs/SHORTCUTS.md](docs/SHORTCUTS.md) | `homelab://` links that fill in a form, Shortcuts recipes, quick actions, Approve / Deny on notifications |
| [docs/ADAPTING.md](docs/ADAPTING.md) | Fork it for your homelab: turn modules off, add your own (with Claude) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Building, testing, code rules |
| [docs/RELEASE.md](docs/RELEASE.md) | Building and publishing a release by hand |
| [CHANGELOG.md](CHANGELOG.md) | What changed |

## License

MIT, see [LICENSE](LICENSE).
