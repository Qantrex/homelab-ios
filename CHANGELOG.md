# Changelog

## 1.0.0 (unreleased)

First release.

License: from 2026-11-08 the project is under PolyForm Noncommercial 1.0.0 (free for noncommercial use; commercial
use needs a license from the author). Earlier versions were MIT and stay MIT.

Highlights:

- `scripts/ship-to-phone` uploads your own build to your own server (checksum verified, last 3 kept, refuses an
  older build) so a Shortcuts automation can install it on your phone each day; the server side is the optional
  `GET /app/latest` and `GET /app/ipa` ([API.md](docs/API.md#app-updates-optional-owner-only), [SETUP.md](docs/SETUP.md#daily-updates-to-your-own-phone)).
- Today: the lab's state in two words, your day as a line with a countdown, actions to approve, Home Assistant tiles
  and the server's cards.
- Test round tooling: a neutral demo scene for Homelab Bridge users (`-HomelabDemoScene bridge`: Uptime Kuma problems,
  Proxmox hosts with history, Pi-hole, Docker, a game server, news; made-up data, no school or deals), a combination
  test for every detail level x personality x scene (`CombinationTests`), and a screenshot matrix of about 90 shots
  for a manual CI run (`gh workflow run ci -f matrix=true`, [CI.md](docs/CI.md#screenshot-matrix)).
- Home Assistant on its own (no Homelab server): Today's headline says what is true, "Home." with "1 light on" or
  "Front door open", and in gold what doesn't answer ("Bedroom fan unavailable"). Demo: `-HomelabDemoScene ha-only`.
- Personality: the lines were rewritten to sound like a quick remark about the fact instead of a template. Today's old
  Ultrakill lines moved to Snarky; Ultrakill is now a much harsher, profane, over-the-top tier of its own, and asks
  once before it is switched on (Enable / Back).
- Today is short by design: Standard fits two screens, Overkill three, Calm one. Urgent rows (a deadline within 3
  days, later ones always folded, a to-do past its time, proposals) never fold; longer lists fold behind "Show N more"; deals, recent
  downloads and grades are small tiles (a count and one line: "best −50 %", "Dune +7", "ITP 95 %"; 2 by 2, one row of
  3, 2 or 1 by count, one per row at large text) that open the full list in a sheet; departures show only inside the
  day card, at the top, while a "Leave by" is within the hour (a disruption alone shows nothing); Today has no "Lab ›"
  link (the headline and the machines line open Lab); Lab shows hosts as rows with Load, RAM and Disk in every
  density, never tiles; the weather card is left to the hero line; the Machines section moved to Lab only. Overkill adds detail per line instead of
  opening everything. What you open folds again on each launch. The demo shows a busy day to match.
- Settings → Today → Detail is a menu like Personality, with one line under it for each choice: Calm "The day and your
  Home tiles. One screen.", Standard "Folds long lists; urgent things stay open. About two screens.", Overkill "The
  same, with more detail in every line." The saved setting is unchanged.
- Settings is short, with an **Advanced** page for the rest (named by the personality: "Nerd section" for Snarky).
  There you can hide and reorder the Start tiles on Actions, the blocks in Lab and the tabs (never Settings), make the
  chat text one step smaller or larger, and fold long chat replies after 6 lines, 12 or never. Defaults are not
  stored, so old settings files are untouched.
- News: your server fetches and summarises the news (the phone never does). Today gets a **News** tile (a count and the
  top headline; Overkill the day's digest) that opens a sheet; each story opens in the in-app browser, in reader mode
  when the page has one. Settings → Advanced → Today → **News** (shown only when the server has news) picks country,
  sources, summaries or headlines, 3, 5 or 8 stories and a 12, 24 or 48 hour window, saved on the server. The demo has
  it.
- Show rules: Settings → Advanced → Sections says under each section when it shows, and a tap picks Always, When it
  needs me, a time (Mornings, Daytime, Evenings, Weekdays, Weekends) or Custom (from, to, days). While a rule hides
  something, Today ends with "Hidden now: Deals (evenings) · Show". Without rules Today is as before.
- Where you are and quiet hours (both off by default): Today's "At home" and "Away" rules follow a person or device
  tracker in Home Assistant (no location permission), and Settings → Advanced → Quiet hours holds back the app's
  notifications in a window such as 22–7.
- Actions: approve, always allow or deny proposals; start your own actions from small forms; Deals, Scan and Find.
- Lab: hosts, 24 h history, containers with Restart, web UIs.
- Chat with your homelab agent, with proposals and cards in the replies.
- Widgets (status, day, hosts, U6, deadlines, to-dos) and a "Leave by" Live Activity.
- Built on Linux with xtool, installed with SideStore on a free Apple ID; Today warns 2 days before the install stops opening.

Security review fixes:

- A token never goes over plain `http://`: a token server or Home Assistant needs `https://` (or `http://` to this
  device: `localhost`, `127.0.0.1`, `::1`; no longer to a `*.ts.net` name, which over http is only safe while
  Tailscale is on). A token server on a LAN IP, `.local`, a single name, a raw `100.x` address or a `.ts.net` name
  over http now gets nothing and says "This server uses a token over plain http. Use its https://….ts.net address (tailscale
  serve)."
  Identity (Tailscale) servers keep the old http rules; all-digit or `0x…` hosts and leading-zero IPs are no longer
  local.
- A card item's action sends exactly its argument; one that no longer fits the server's action is refused instead of
  running the form's default.
- Server numbers are put into range when read (a 3.4e38 °C sensor crashed the app); Double to Int only through a
  clamping helper, with a lint check.
- Posters: pixel size checked from the header (more than 4000×6000 refused) and decoded as thumbnails; absolute
  picture URLs must sit under the server's base path; pictures are cached per server and deleted with it.
- Share extension: only the item's title is sent, never its content text. Tokens left in the Keychain by a deleted
  install are wiped on the first launch. API answers stop at 8 MB (Home Assistant 32 MB).
- Homelab Bridge: a source key with a line break inside stops the start (a trailing one is stripped); it could leak
  through an http.client error into `/info`. Keys are hidden also escaped, `%`-encoded and in base64. Upstream texts
  lose URLs and `apikey=…` pairs and are cut to 200 characters (Markdown escaped where the app renders Markdown); at most 200 items per card and containers per host;
  links with a user or key are dropped. A key over plain `http://` to a non-loopback host shows as `plain_http` in
  Diagnostics. With sources, identity login needs `allowed_logins`. Uptime Kuma's `services` is off by default. The
  image refuses Tailscale userspace mode with the login header; the socket proxy is wollomatic's with only
  `GET /containers/json`; the compose image tag is `local` or a pinned version, never `latest`.
- Homelab Bridge: a `gameserver` source for Minecraft Java and Valve A2S servers (Valheim, Palworld, CS2, ...): one
  Lab card with each server's state, players, version and MOTD. It only sends status pings, never a login, so a
  sleeping server behind `itzg/mc-router` stays asleep; there is no wake action. A server that is down is only a
  problem with `expect_up`. Homepage's `minecraft` widget imports as one server.
- Homelab Bridge: an `rss` source for news. Headlines from RSS 2.0, RSS 1.0 and Atom feeds (ORF, Der Standard, heise,
  Hacker News, BBC, ...) become the card `news` on Today, with `GET /api/v1/news/sources` and `PUT
  /api/v1/news/prefs` so the app can choose country, sources, count and window. Headlines only (no summary); a
  feed that fails is a warning, all failing is no card; feeds that declare entities are refused. Servers without an
  `rss` source answer 404 to both.

App:

- Home tiles on Today can have a short name of your own: Today → Edit has a "Name on the tile" field under each
  pinned entity (empty shows Home Assistant's name; trimmed, one line, at most 24 characters). It is set in the app
  only, Home Assistant, its voice commands and its app keep their names. VoiceOver says the short name and then
  Home Assistant's name when they differ. Unpinning a tile drops its name; older saved settings still load. Launch
  argument `-HomelabTileNames "light.a=Living room,script.b=Alarm off"` sets them over USB.
- Home tiles can have an icon of your own: Today → Edit has an "Icon on the tile" menu under each pinned entity
  (Automatic = the icon for the kind of entity, or one of 16 symbols: lamps, relax, party, night, wake-up, alarm,
  music, TV and so on; filled while the tile is on). Unpinning drops the icon; older saved settings still load.
  Launch argument `-HomelabTileIcons "light.a=lamp.floor,script.b=moon.stars"`.
- A bike day shows a motorcycle (the Live Activity and the demo's commute action), not a bicycle.
- Two days before a free-Apple-ID install stops opening, Today says so ("This install stops opening in 2 days …
  reinstall; your data stays"); Diagnostics shows the date. Read from the app's own provisioning profile.
- Setup errors (token, address, certificate) have an "Edit server" button next to Retry that opens the server's
  editor in Settings. Lab's header says "No problems · 2 hosts with a warning" instead of "All good" above gold
  host dots (Today stays calm). Widgets follow the text size up to xxLarge.
- App review of 2026-11-07 (functional, intuitiveness, accessibility, Settings):
  - Fixed: editing the Home Assistant server (a new token or name) dropped the tiles' names and icons; Reset
    everything could bring deleted servers back from the copy made before the App Group; a swiped-away demo server
    couldn't come back (demo servers now only go with the Demo switch); the "New deals to act on" and Face ID switches
    could hide or lock while on; Test connection without a token showed the 401 text; a deals push on a cold launch
    lost the link on a server whose only Actions feature is deals; a running poll undid a pull to refresh on Deals; a
    deal with a time far in the future stayed "new"; duplicate ids in `-HomelabPins`.
  - Clearer: a new server without a typed name is called by its short host name ("nas", older saved ones
    too); Today → Edit has an "On Today" section with the pinned tiles in order (Order to move them), a visible "Name
    on the tile" label and the icon menu; the approve confirm uses the row's words (Approve, Always allow, Deny) and
    Deny isn't red there; "To approve" everywhere (Today's section, Lab, the empty state); a Start tile with nothing
    to fill in asks "Run now?" right away; Today shows "Lab ›" next to the date; Lab ends with a Diagnostics link;
    the leave-by switch only shows for a server that sends a commute; http and token messages say what works.
  - Accessibility: at the accessibility text sizes label and value stack instead of breaking words; the voice line,
    numbers' titles, tile states and not-sent reasons wrap instead of being cut; tertiary and light-mode gold pass
    4.5:1 on raised panels; VoiceOver hears which tile a name field or icon menu belongs to, which proposal Approve
    or Deny is for, and that a tile tap worked; sensor tiles read as text; the Live Activity reads "Leave by" in one
    stop; Chat's Show more is 44 pt; checklist links are buttons for Full Keyboard Access; ⌘↩ sends in Chat.
- `scripts/phone-shots` keeps your servers, Home Assistant token and pins: it no longer starts with
  `-HomelabResetState YES` (now `--reset`, opt-in, with `HOMELAB_SERVER`/`HOMELAB_PINS` to set them back at the end).
- Deals (feature `deals`, optional endpoint `GET /api/v1/deals`): used-market ads the server found clearly below their
  market value and judged. A Deals tile on Actions (with "N to act on" in gold when there are fresh strong ones) opens
  the list: "Act now", "Worth a look", "Skipped", each deal with its price, "−50 %" below the market value, the
  server's confidence, specs, place (a marker when it is in the pickup area), private or dealer, ships, condition, the
  server's verdict note, and its warnings in gold ("too good to be true?" is a warning, not an error). A deal opens
  its detail: the comparable ads with prices and links, Open the ad (willhaben app or Safari) and Copy link.
  `homelab://deals` (also the ntfy push) opens it; Today gets a "Deals to act on" section only while there is an "act
  now" deal from the last day. Settings → Notifications → "New deals to act on" (off by default, since the server
  already pushes them): a local notification for a new strong deal from the background refresh, never for one older
  than 6 hours or one seen before, the first list only learned, at most 3 per run, nothing about the deal while the
  app lock is on. A server that answers 404 gets no screen, tile, section or error; servers that don't list `deals`
  are asked once every 10 minutes. Launch argument `-HomelabDeals list|detail`.
- Lab rows: host names wrap to two lines instead of being cut, the sparkline drops first on a narrow row, the value
  columns have a fixed width that grows with the text size, and at accessibility sizes each value gets its own
  "Load 0.42" line. Numbers turn gold or love at the same limits as the sparkline's dot and the detail chart (load per
  core 1x / 2x, RAM 90 / 95 %, disk 75 / 90 %, temperature 80 / 90 C); VoiceOver says "high". Meta text and light-mode
  gold have enough contrast.
- Find and request (feature `search`): the Actions tab has a "Find a movie or show" tile (and `homelab://search?q=`);
  the search field asks the server 400 ms after the last key (2 to 100 characters) and shows the answered cards as a
  poster grid with a Request button per title (one confirm, then it runs). New card style `poster-grid` and item
  `image`: a path on the server or a URL on its own host; loaded with the API's login, 1 MB and JPEG/PNG/WebP at most,
  cached in memory and in a 20 MB disk cache, a quiet placeholder meanwhile. No other host is ever asked.
- Cards for Lab: `place: "lab"` puts a card in Lab (between Hosts and Services) instead of Today, drawn as rows with a
  status dot, the reason in grey and the value in the data font (tailnet nodes, ad blocking with "Pause 5 min",
  backups). Older apps show them on Today.
- At a glance (6c): a `departures` card (public transport: direction and next time, stop and the next three, a gold
  "+3" when late, disruption line with a gold triangle) and `commute` in `/state`. Widgets: U6 (lock screen
  rectangular, inline, circular; small for StandBy), Deadlines (rectangular, inline, circular, small, medium) and
  To-dos (rectangular, circular, small, medium). With the app lock on, deadlines and to-dos show counts only. Widgets
  fetch `/state` themselves for identity (Tailscale) servers when the shared snapshot is older than 5 minutes (no
  token, 8 s timeout). Live Activity "Leave by 07:26 · U6 07:31": starts when the app is open on a school morning,
  updates and ends from the background refresh; Settings toggle and Diagnostics lines. Still 3 App IDs.
- Widget fixes: Hosts shows "Disk 93%" in gold or love again; the Day widget's medium header follows the day mode
  (not the card title) and shows the card's date for tomorrow; tomorrow's countdown in widgets is whole hours
  ("in 10 h") and redraws when the hour changes.
- Platform: Approve / Deny right on a "waiting for you" notification (phone unlocked first, a short result
  notification after; no buttons while the app lock is on). Home-screen quick actions: Scan plus the three Start
  actions you use most. Links fill in forms: `homelab://actions/<name>?arg=…&<field>=…` for Shortcuts "Open URL"
  (never hidden fields; you always confirm). See docs/SHORTCUTS.md.
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
- Personality: Off (default), Dry, Snarky or Ultrakill. One line of commentary under Today's headline, on empty screens and as
  a notification's subtitle; it changes once a day, and the facts never change with it.
- Motion: tiles and panels give way under the finger (only dim with Reduce Motion), numbers roll when they change,
  panels slide in and out, rings and meters fill smoothly. Haptics on toggles, approve/deny results and sending.
- Accessibility (audit 2026-11-06): light love and iris are darker (4.5:1 on raised panels); Increase Contrast gives
  lighter panels and lines on black, darker type on white and makes meta text as strong as secondary; the hero grows
  with Dynamic Type (it stays bigger than the fact line). VoiceOver: ages and countdowns are read in words ("in 26
  minutes", "3 days ago", "3 minutes late"), values over their limit say "high", the hero reads line by line (the
  headline is the heading, "Next comment" on the voice line), Today's day panel has a heading, section titles are one
  heading with their count, Retry and Close are their own buttons, the error banner, search results and the share
  result are announced, Home tiles are toggles with a hint. Lab rows stack from xxLarge, Today's waiting rows, the
  Overkill machine list and the 24 h charts at accessibility sizes. Links in server text are iris and underlined.
  Reduce Motion also stops the rolling numbers, the glow and meter animations. Widgets no longer dim old data (the
  age with a clock says it), speak the host's state and the departure's delay, and tint their status glyphs.
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
