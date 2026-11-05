# Changelog

## 1.0.0 (unreleased)

First release.

App:

- Overview: overall status, problems first, a tile per host (load, RAM, worst disk, temperature, containers, flags),
  host details, cards from the server, a service launcher (opens Safari), the last report. Pull to refresh, refresh
  every 30 s while open, last data with its age when offline.
- Actions: proposed actions with reason and age. Approve, Always and Deny with a confirm step; shows the server's
  answer. Tab badge with the count.
- Chat: chat with a homelab agent. "Working…" state, report tags, inline Markdown, copy, quick commands, 4000-character
  limit with a counter, failed messages can be edited and sent again.
- Home: Home Assistant with a long-lived token. Pin lights, switches, fans, toggles, automations, scripts, scenes,
  buttons and sensors; toggle or run them.
- Settings: several servers (Homelab API or Home Assistant), Tailscale identity or token login, test connection,
  shown server, notifications, Face ID lock, demo mode, Diagnostics with a copyable report, reset everything.
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
- CI on Linux and macOS (free runners): tests, lint, IPA build and check, simulator screenshots.
- Release workflow: tag → GitHub Release with the IPA and SHA-256, SideStore source on GitHub Pages.
- Docs: setup, SideStore, server setup, security, device test checklist.
