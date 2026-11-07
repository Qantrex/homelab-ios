# Homelab iOS

A native iPhone app for a self-hosted homelab. It shows what is up, what needs attention and what waits for your
approval. It can chat with your homelab agent and switch Home Assistant devices. Open source, MIT, no account, no
cloud.

It is built with SwiftPM and [xtool](https://github.com/xtool-org/xtool), so you don't need a Mac or a paid Apple
developer account. You install it with a free Apple ID: from a Linux PC or a Mac with xtool, or
with [SideStore](https://sidestore.io).

## What it does

- **Today**: how the lab is doing in two words, your day as a line with a countdown, actions to approve, your Home
  Assistant tiles and the server's cards.
- **Actions**: approve, always allow or deny what your homelab proposes, and start actions of your own from small
  forms. Deals, Scan and Find live here too.
- **Lab**: every host with load, RAM, disk and a 24 h history, its containers with Restart, and your web UIs.
- **Chat** with your homelab agent, with proposals and cards right in the replies.
- **Widgets** and a "Leave by" Live Activity on the lock screen.

| Tab | What you see and do |
|---|---|
| Today | The status in two words ("All quiet.", "1 problem."; tap it or "Lab ›" for Lab). The server's "today" card as a line through the day with a countdown to the next stop. Then actions to approve, Home tiles, deals to act on and the other cards (to-dos you tick off, deadlines counting down, downloads, parcels, …). Settings → Today: order of the sections, and Calm, Standard or Overkill detail. Refreshes every 30 s while open |
| Actions | Start: tiles for the actions your server lets you start (add a to-do, set tomorrow's wake-up, restart a container, …); each opens a small form, or asks "Run now?" right away when there is nothing to fill in. Below: "To approve", the actions your homelab proposes, with reason and age. Approve, Always or Deny, each with a confirm step. Approve and Deny also work right on the notification; your three most used actions are Home-screen quick actions; links like `homelab://actions/todo-add?summary=Milk` open a form filled in ([docs/SHORTCUTS.md](docs/SHORTCUTS.md)) |
| Scan and share | If the server has `documents`: a Scan tile on Actions (and a Home-screen quick action, or `homelab://scan`) opens the document camera and sends the PDF to Paperless. The share extension "Homelab" sends a link (a willhaben ad gets a price check, other links a read-later list), a PDF, or photos (made into one PDF) to your server. Offline or on a token server, items wait in an outbox and the app sends them later |
| Find | If the server has `search`: a "Find a movie or show" tile on Actions. Posters from the server, a Request button per title |
| Deals | If the server offers `/deals`: a Deals tile on Actions (`homelab://deals`), and a section on Today while a strong one is fresh. Used-market ads far below their market value that your server found and judged: price, −50 %, confidence, warnings in gold, the comparable ads, open or copy the ad |
| Chat | Chat with your homelab agent. "Working…" while it runs, report tags (`morning`, `watchdog`, …), long-press to copy, a "/" button with the commands the server lists, Clear (hides the chat on this phone; the server keeps it). Proposals in a reply have Approve, Always and Deny in the bubble; cards in a reply show small under the text |
| Lab | Problems, a tile per host (load, RAM, worst disk, temperature, containers, a 24 h load line); the header says "No problems · 2 hosts with a warning" when a host has one. Tap a host for 24 h charts and its containers (problems first) with Restart for the ones on its restart list. A launcher for your web UIs (opens Safari). Diagnostics at the end |
| Settings | Several servers ("Show data from" picks the one for Today, Lab, Actions and Chat; "Home tiles from" the Home Assistant), test connection, Today's sections and detail, a personality (Off, Dry or Snarky; off by default), notifications, the "Leave by" Live Activity, Face ID lock, demo servers, Diagnostics |

Tabs appear only when they make sense: Actions and Chat only if the server offers them. Home tiles appear on Today
when you add a Home Assistant server. A setup error (token, address, certificate) has an "Edit server" button next
to Retry.

**Widgets** (read-only, no buttons):

| Widget | Sizes | Shows |
|---|---|---|
| Homelab status | small, lock screen (circular, rectangular, inline) | Today's headline ("All quiet.", "1 problem.") in its colour, the first problem, actions to approve |
| Homelab day | small, medium, lock screen (rectangular, inline) | The "today" card's day line: the next stop big with its countdown (small, lock screen), every stop on the line (medium) |
| Homelab hosts | medium (4 hosts), large (8 hosts and problems) | The headline, then each host with load, RAM and disk |
| U6 departures | small, lock screen (circular, rectangular, inline) | The next trains from your stop, with delays and disruptions (from the server's `departures` card) |
| Deadlines | small, medium, lock screen (circular, rectangular, inline) | What is due next, counting down |
| To-dos | small, medium, lock screen (circular, rectangular) | Your open to-dos |
| "Leave by" (Live Activity) | lock screen, banner, StandBy | When to leave and the next train, counting down by itself (from the server's `commute`) |

U6 is a metro line in Vienna (the line this app was built for). The widget's name in the gallery is fixed in
`Sources/HomelabWidget/DeparturesWidget.swift`; the line it shows comes from the `departures` card's title. For your
own line see [docs/ADAPTING.md](docs/ADAPTING.md).

Widgets show the data the app saved last. For a Homelab API server with the Tailscale login they also fetch
`/state` themselves when that data is older than 5 minutes (iOS reloads a widget about every 15 minutes), so they
stay fresh with the app closed. Widgets never get a token: for a token server they only show what the app (or its
background refresh) fetched. The day widget redraws every minute while a stop is less than an hour away. Tapping a
widget opens the right tab. Data older than 2 hours loses its colour and shows its age with a clock. The status
text is hidden on the lock screen while the phone is locked. With the app lock on, the widgets show only counts: no
problem text, titles, host names or day (the U6 times stay, they are public).

## Who it is for

Anyone with a homelab and Tailscale (or another VPN) on the phone. You need one of these:

| You have | Use |
|---|---|
| Nothing special: a Linux box with some Docker apps | The [reference server](docs/REFERENCE_SERVER.md): one Python file, no dependencies |
| Home Assistant | Add it directly with a long-lived token (Home tiles on Today) |
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

> **Status (2026-11-07): no release yet.** Used daily on an iPhone 12 mini (iOS 18), installed through SideStore
> (after the [-80045 sign-in fix](docs/SIDESTORE.md#sign-in-error--80045)); xtool 1.24.0 plus the one-line App Group
> patch ([docs/SETUP.md](docs/SETUP.md#known-xtool-bug-no-app-group-with-a-free-apple-id-xtool-1240-and-older)) works
> too.
> Until the first release, build and install it yourself. Releases are built by hand, never by CI
> ([docs/RELEASE.md](docs/RELEASE.md)).

| Way | Status | How |
|---|---|---|
| Build and install from Linux | Works, used daily. Reinstall every 7 days over USB | [docs/INSTALL-FROM-LINUX.md](docs/INSTALL-FROM-LINUX.md) |
| Build and install from a Mac | Same xtool steps | [docs/SETUP.md](docs/SETUP.md) |
| IPA from GitHub Releases | From the first release on. Install it with xtool (`xtool install`) or SideStore | [Releases](https://github.com/Qantrex/homelab-ios/releases) |
| SideStore | Not verified yet (sign-in error -80045). SideStore would refresh the app over Wi-Fi | [docs/SIDESTORE.md](docs/SIDESTORE.md) |

Needs iOS 18 or newer.

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
| No Siri or Shortcuts actions of its own, no buttons in widgets, no Control Center | These need App Intents, and xtool can't build them yet. Shortcuts can still open `homelab://` links that fill in a form ([docs/SHORTCUTS.md](docs/SHORTCUTS.md)) |
| No Apple push notifications | APNs needs a paid developer account. The app can check in the background and send a local notification, but iOS decides when that runs (often every 15–60 minutes, sometimes much less) |
| Reinstall every 7 days | Apps signed with a free Apple ID stop opening after 7 days. Today warns 2 days before, and Settings → Diagnostics shows the date. Reinstall over USB (`scripts/install-dev`); your data stays. SideStore refreshes it (a Shortcut swaps its VPN and Tailscale) |
| 3 active apps | A free Apple ID allows 3 sideloaded apps (with SideStore, SideStore is one). The widget and the share extension don't count, so Homelab uses one slot (but 3 of the 10 new App IDs a week) |
| One Home Assistant at a time | The Home tiles on Today come from one Home Assistant: the one under Settings → "Home tiles from" |
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
| [docs/INSTALL-FROM-LINUX.md](docs/INSTALL-FROM-LINUX.md) | Installing from a Linux PC over USB (no Mac) |
| [docs/SIDESTORE.md](docs/SIDESTORE.md) | SideStore (and the -80045 fix), the 7-day refresh, App Group, troubleshooting |
| [docs/SERVER-SETUP.md](docs/SERVER-SETUP.md) | Connecting a homelab: reference server, Home Assistant, your own server |
| [docs/REFERENCE_SERVER.md](docs/REFERENCE_SERVER.md) | All options of the reference server |
| [server/openapi.yaml](server/openapi.yaml) | The Homelab Companion API v1 |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, what the app does, what server operators must do |
| [docs/SETUP.md](docs/SETUP.md) | Building with xtool, tests, project layout |
| [docs/CI.md](docs/CI.md) | CI (checks and screenshots; it never builds an app to install) |
| [docs/API.md](docs/API.md) | The API in plain words, for writing your own server |
| [docs/SHORTCUTS.md](docs/SHORTCUTS.md) | `homelab://` links that fill in a form, Shortcuts recipes, quick actions, Approve / Deny on notifications |
| [docs/ADAPTING.md](docs/ADAPTING.md) | Fork it for your homelab: turn modules off, add your own (with Claude) |
| [docs/DESIGN.md](docs/DESIGN.md) | How every screen and widget looks |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Building, testing, code rules |
| [DeviceTest.md](DeviceTest.md) | The checks only a real iPhone can do |
| [docs/RELEASE.md](docs/RELEASE.md) | Building and publishing a release by hand |
| [CHANGELOG.md](CHANGELOG.md) | What changed |

## License

MIT, see [LICENSE](LICENSE).
