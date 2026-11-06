# Changelog

## 1.0.0 (unreleased)

First release.

App:

- Today: a mood headline on top (calm when all is fine, gold or love with a glow and a haptic when not), the server's
  "today" card as a day line (clock times in order, filled up to now, countdown to the next stop), actions waiting,
  pinned Home Assistant tiles, the other cards and the last report. Sections can be reordered and hidden; Calm,
  Standard or Overkill density (Overkill adds every machine's numbers, exact times and busy jobs).
- Progress in cards (downloads, now playing) as rings with the percent inside.
- Lab (was Overview): overall status, problems first, a tile per host (load, RAM, worst disk, temperature, containers, flags),
  host details, a service launcher (opens Safari). Pull to refresh, refresh every 30 s while open, last data with its
  age when offline.
- Look: true black (white in light mode), monochrome, thin borders, mono numbers; colour only for problems (Rosé
  Pine love) and warnings (gold). No blue.
- Actions: proposed actions with reason and age. Approve, Always and Deny with a confirm step; shows the server's
  answer. Tab badge with the count.
- Chat: chat with a homelab agent. "Working…" state, report tags, inline Markdown, copy, quick commands, 4000-character
  limit with a counter, failed messages can be edited and sent again.
- Home Assistant with a long-lived token: pin a few lights, switches, fans, toggles, automations, scripts, scenes,
  buttons or sensors as tiles on Today; tap to toggle or run them. No separate Home tab.
- Settings: several servers (Homelab API or Home Assistant), Tailscale identity or token login, test connection,
  shown server, Today's sections and detail, personality, notifications, Face ID lock, demo mode, Diagnostics with
  a copyable report, reset everything.
- Personality: Off (default), Dry or Snarky. One line of commentary under Today's headline, on empty screens and as
  a notification's subtitle; it changes once a day, and the facts never change with it.
- Motion: tiles and panels give way under the finger (only dim with Reduce Motion), numbers roll when they change,
  panels slide in and out, rings and meters fill smoothly. Haptics on toggles, approve/deny results and sending.
- Tabs show only what the server offers (`features` in `/api/v1/info`).
- Demo mode with built-in data, no network.
- Widgets: status (small and lock screen: circular, rectangular, inline) and hosts (medium, large). Read-only, tap
  opens the right tab, old data is marked.
- Background refresh with optional local notifications for new problems and new actions. Off by default, no repeats,
  no alert storm after being offline.
- `homelab://` links for each tab.
- Security: tokens in the Keychain only (this device, after first unlock), inline Markdown and http(s) links only,
  plain http only for local and tailnet addresses, no cookies, no third-party code, no analytics.
- Finds its App Group at runtime, so the widget works after SideStore renames it.
- Dark mode, Dynamic Type, VoiceOver labels.

Server and tooling:

- Homelab Companion API v1 (`server/openapi.yaml`).
- Reference server (`server/reference_server.py`): one stdlib Python file for any homelab. Host and web checks, cards,
  services, opt-in actions and chat, and a fixture mode for tests.
- CI on Linux and macOS (free runners): tests, lint, simulator build, screenshots and simulator tests. The IPA is
  always built locally (`scripts/build-ipa`, which checks the widget and App Group).
- Releases by hand from a local build (`docs/RELEASE.md`): GitHub Release with the IPA, its SHA-256 and the SideStore
  `source.json`.
- Docs: setup, SideStore, server setup, security, device test checklist.
