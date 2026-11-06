# Changelog

## 1.0.0 (unreleased)

First release.

App:

- Your whole day: in the evening the "today" card can be tomorrow's (`date`): header "Tomorrow", countdown to the
  first stop, also in the Day widget. Cancelled lessons (`cancelled`) are struck through, substitutions get a gold dot,
  the weather card's line sits under the headline's facts.
- Today: a mood headline on top (calm when all is fine, gold or love with a glow and a haptic when not), the server's
  "today" card as a day line (clock times in order, filled up to now, countdown to the next stop), actions waiting,
  pinned Home Assistant tiles, the other cards and the last report. Sections can be reordered and hidden; Calm,
  Standard or Overkill density (Overkill adds every machine's numbers, exact times and busy jobs). Until the first
  answer the headline says "Checking…" in grey; "No signal." only once a fetch failed.
- Progress in cards (downloads, now playing) as rings with the percent inside.
- Checklist cards (to-dos): a circle per item, done ones struck through, the due day gold today and love when
  overdue; tap the circle to tick an item off (one confirm, then it runs at once; the item stays ticked until the
  server's list catches up, and its text is sent exactly as the server gave it). Countdown cards (deadlines): big
  mono "2 d", "5 h", "today", "3 d ago", soonest first. A due sent as a plain day counts in whole days and keeps its
  day after a time-zone change; a time at 00:00 stays a time. A card's header button ("+ Add") opens its action's
  form prefilled; a link to another form waits until that sheet is closed. All only when the server lets the app
  start that action.
- Lab (was Overview): overall status, problems first, a tile per host (load, RAM, worst disk, temperature, containers, flags),
  host details, a service launcher (opens Safari). Pull to refresh, refresh every 30 s while open, last data with its
  age when offline. Problems and warnings are counted apart like on Today ("1 problem · 1 warning"), each problem's
  border has its own colour, and a host the server lists a problem for takes that problem's level. On a narrow tile
  the host name keeps its room and the state word gives way to the dot; a sleeping machine is grey, with when it was
  last seen.
- Lab history and containers (servers that send `history` and `container_list` on hosts): a 24 h load sparkline on
  each host tile; host details with 24 h sparklines for load, memory, temperature and the fullest disk (min, max and
  now in mono, gold or love only when the newest value is over a limit, gaps where the host was down) and the
  host's containers, problems first (exited, dead, unhealthy in love, restarting in gold) with state, health and
  restarts. Containers on the host's restart list get a Restart button: a red confirm, then the server's
  `restart-container` action, its answer and a haptic ("started" when it still runs on the server); until the
  host's next check the row says "restarted HH:mm, waiting for the next check" instead of offering Restart again.
  Sparklines run on a 24 h time axis (a history that stopped ends left of the edge; old values are dimmed with
  "until HH:mm" and never colour the line). Overkill on Today shows each machine's load sparkline.
  `homelab://lab/<host-id>` and `-HomelabHost` open a host's details.
- Look: true black (white in light mode), monochrome, thin borders, mono numbers; colour only for problems (Rosé
  Pine love) and warnings (gold). No blue.
- Actions: proposed actions with reason and age. Approve, Always and Deny with a confirm step; shows the server's
  answer. Tab badge with the count.
- Start actions yourself (servers with `run-actions`): tiles under "Start" on the Actions tab open a form built from
  what the server describes (day and time pickers, choices, text, optional dates behind a switch), checked before it
  is sent; after a confirm step the server runs it at once and the app shows its answer (a server error with its own
  reason shows that reason; "Not sure it ran" instead of "Didn't run" when the connection breaks after sending). Links
  `homelab://actions/<name>` open a form directly; a form or host a link asked for waits with its tab, and picking
  another tab by hand drops it. For the owner's agent: add a to-do, tick one off, add an event,
  wake-up, bike or U6, living room, restart a container.
- Chat: chat with a homelab agent. "Working…" state, report tags, inline Markdown, copy, quick commands, 4000-character
  limit with a counter, failed messages can be edited and sent again. Proposals in a message get Approve, Always
  and Deny in the bubble (same confirm as the Actions tab), cards in a message show small under its text. A day line
  ("Today", "Yesterday", "Mon") above the first message of each day.
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
- Widgets in the app's look: status (small and lock screen: circular, rectangular, inline) with the mood headline and
  glow, day (small, medium, lock screen: the day line and the countdown to the next stop) and hosts (medium, large).
  Read-only, tap opens the right tab, old data is marked.
- Background refresh with optional local notifications for new problems and new actions. Off by default, no repeats,
  no alert storm after being offline.
- `homelab://` links for each tab.
- Security: tokens in the Keychain only (this device, after first unlock), inline Markdown and http(s) links only,
  plain http only for local and tailnet addresses, no cookies, no third-party code, no analytics.
- Scan and share (servers with `documents` / `share`): a Scan tile on the Actions tab opens the document camera (VisionKit),
  shows pages and size, takes a title ("Scan 2026-11-06 14:05" by default) and sends the PDF to the server's document
  inbox (Paperless). Also from a Home-screen quick action and `homelab://scan`. Without a camera (simulator) the screen
  says "Scan needs a camera" and offers a sample page. The share extension "Homelab" takes a link, a PDF, photos (one
  downsampled PDF, at most 20) or text with a link, shows what it got and where it goes ("Price check on willhaben",
  "Read later", "To Paperless"), sends it and shows the result. On an identity (Tailscale) server it sends directly;
  on a token server, offline, or on a server error it saves the item in an outbox in the App Group ("Saved, Homelab
  sends it when it can"): at most 10 items and 100 MB, sent again when the app opens and in the background refresh,
  dropped after a final answer (2xx or a refusal) or 7 days. A free Apple ID now uses 3 App IDs per install.
- Finds its App Group at runtime, so the widget works after SideStore renames it.
- Dark mode, Dynamic Type, VoiceOver labels.

Server and tooling:

- Homelab Companion API v1 (`server/openapi.yaml`).
- `POST /documents` (raw PDF) and `POST /share` (link) in the Companion API; the reference server's fixture mode
  implements both in memory with a fake result.
- Reference server (`server/reference_server.py`): one stdlib Python file for any homelab. Host and web checks, cards,
  services, opt-in actions and chat, and a fixture mode for tests.
- CI on Linux and macOS (free runners): tests, lint, simulator build, screenshots and simulator tests. The IPA is
  always built locally (`scripts/build-ipa`, which checks the widget and App Group).
- Releases by hand from a local build (`docs/RELEASE.md`): GitHub Release with the IPA, its SHA-256 and the SideStore
  `source.json`.
- Docs: setup, SideStore, server setup, security, device test checklist.
