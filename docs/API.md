# Companion API v1

A short guide to [`server/openapi.yaml`](../server/openapi.yaml). The YAML file is the contract; this page explains it.
To try it, run the reference server (`server/reference_server.py`, see [REFERENCE_SERVER.md](REFERENCE_SERVER.md)).

## Endpoints

All paths are under `/api/v1/`. JSON in and out, UTF-8.

| Method + path | Body | Reply | The app uses it for |
|---|---|---|---|
| `GET /info` | – | `{api, name, server, version, features, auth, commands, standing_approvals}` | "Test connection", which tabs to show |
| `GET /state` | – | `{time, status, checked, problems, hosts, pending, cards, busy, last_message}` | Today, Lab, Actions, widgets, background refresh |
| `GET /messages?after=<id>` | – | `{messages: [...], busy: [...]}` | Chat (polls; `after` is the last id it has). A message may carry `pending` and `cards` |
| `POST /messages` | `{text}` (1–4000 chars) | `{ok, id}` | Sending a chat message or slash command |
| `POST /button` | `{action: "<signed string>"}` | `{text}` | Approve / Always / Deny on a pending action |
| `GET /services` | – | `{services: [{name, url, group, icon, description}]}` | The service launcher |
| `GET /actions` | – | `{actions: [{name, label, icon, hint, destructive, arg, fields}]}` | Feature `run-actions`: the "Start" list on the Actions tab and its forms |
| `POST /actions/<name>` | `{arg, payload}` | `{ok, text, running}` | Starting one of them, after the app's confirm step |
| `POST /documents` | the raw PDF (`Content-Type: application/pdf`, headers `X-Homelab-Id`, `X-Homelab-Title`) | `202 {ok, id, text}` | Feature `documents`: the Scan tile and the share extension send PDFs to your document inbox (Paperless) |
| `GET /search?q=<text>` | – | `{query, cards}` | Feature `search`: the Find and request screen (movies and shows as a poster grid) |
| `GET /poster/<size>/<file>` (or any path an item's `image` names) | – | the picture | Posters for `poster-grid` cards; see "Pictures" |
| `POST /share` | `{id, kind: "url", url, title}` | `{ok, id, route, text}` | Feature `share`: the share extension sends a web link; the server routes it (a willhaben ad, or a read-later list) |

Status codes the app understands: 401/403 (identity missing or not allowed), 404 (feature not there), 400, 415, 429
(too many runs), 5xx. A forged or expired button gets 403; the app says "No longer valid" and refreshes the list.
A 5xx on `POST /actions/<name>` with `{"error": "..."}` shows that text as the reason it failed (say there whether
anything ran); a 5xx without it, or a broken connection, shows "Not sure it ran" (with "Check the chat" when the
server has `chat`).

## Documents and shares (`documents`, `share`)

Both are sent by the Scan tile and by the share extension (the iOS share sheet). Both carry a client-made `id` (a
lower-case UUID): a repeat of the same id must get the first answer and do nothing twice, because the app retries
(the outbox, a lost answer).

`POST /documents`: the body is the PDF itself, `Content-Type: application/pdf` and nothing else (415 otherwise).
Headers: `X-Homelab-Id` (required), `X-Homelab-Title` (optional, percent-encoded UTF-8, at most 128 characters
after decoding, control characters dropped). Send `Content-Length` (411 without), at most 25 MB (413 above), and the
body must start with `%PDF-` (400). Answer `202` with `{ok, id, text}`: the filing (Paperless OCR) happens in the
background and its result goes to the chat. 409 means the same id is still running, 429 means too many uploads
(20 an hour). The file is never given to a language model.

`POST /share`: JSON, `{id, kind: "url", url, title}` (`title` optional, at most 200 characters). The server decides
what the link is for: a willhaben ad (`willhaben.at/iad/...-<6-12 digits>` or `?adId=`) starts a price check
(`route: "willhaben"`), any other http(s) link goes to a read-later list (`route: "read-later"`). It never fetches the
link. It refuses other schemes, links with a user name or password, and links over 2048 characters with 400; text
that isn't a link is not accepted, because shared text is not owner-written and must never become a chat request.
Answer `200 {ok, id, route, text}`; 30 shares an hour.

A server that offers neither leaves `documents` and `share` out of `features`: the app then has no Scan tile and the
share extension says that the server doesn't take shares. Statuses the app treats as final (the item leaves its
outbox): 2xx, and 400, 413, 415, 422. Everything else (offline, 401, 403, 404, 409, 429, 5xx) keeps the item and is
retried: when the app comes to the foreground and in the background refresh, for up to 7 days.

The reference server (`--fixtures` mode) implements both endpoints in memory with a fake result, so you can try them.

## Search and pictures (`search`)

`GET /search?q=<text>`: `q` is 2 to 100 characters after trimming (the app removes control characters and makes runs of
white space one space, and does not ask for less or more); the server answers 400 otherwise. Reply:

```json
{"query": "quiet",
 "cards": [{"id": "search-media", "title": "Movies and shows", "icon": "film", "style": "poster-grid",
            "items": [{"title": "The Long Quiet", "subtitle": "Movie · 2024", "value": "in Plex",
                       "image": "/api/v1/poster/w342/ab12cd34ef56.jpg"},
                      {"title": "Harbour Lights", "subtitle": "Show · 2019", "value": "",
                       "image": "/api/v1/poster/w342/gh78ij90kl12.jpg",
                       "action": {"name": "seerr-request", "label": "Request", "arg": "tv:1399"}}]}]}
```

No cards (or cards without items) means nothing was found. Errors: 400 (bad `q`, with `error`), 429, and 5xx with
`{"error": "..."}` (the app shows that text, e.g. "Seerr did not answer"). The app shows the answered cards like any
card, so the server can answer with other styles too. The app asks 400 ms after the last key. The request button is the
item's `action` with the usual confirm ("Request <title>?"), `POST /actions/<name>`; after it ran, the poster shows
"requested" and no button. Without `search` in `features` the app has no search screen; the Actions tab shows for
`search` alone.

Link: `homelab://search?q=dune` opens the Actions tab with the search screen and the text in the field (`q` optional,
cut to 100 characters). Servers without the feature drop it.

**Card style `poster-grid`**: the items as posters, 3 columns (2 at accessibility text sizes), each poster 2:3 with the
`title` (2 lines), `subtitle`, `value` and the item's `action` button under it. Older apps show it as `list`.

**Item `image`**: a picture for the item. A path on the server (`/api/v1/poster/w342/ab12.jpg`, resolved against the
server's address, a path prefix of the server is kept) or an absolute URL with the **same scheme, host and port** as the
server. Anything else (other hosts, `//host/...`, `file:`, user names, `..` segments, encoded slashes, backslashes,
over 512 characters) is dropped, and the app never asks any host but its server. The app loads it with the same login as
the API (token header, no cookies, no redirects), accepts at most **1 MB** and only JPEG, PNG or WebP (decided by the
first bytes; a `Content-Type` that is not `image/*` is refused too), caches it in memory and in a small disk cache
(20 MB, 30 days, oldest out) and shows a quiet placeholder (the card's icon) while it loads or when it fails. A failed
picture is not asked again for a minute. A server should send `Cache-Control` and keep names stable (the name changes
when the picture does).

## Cards for Lab (`place`)

A card may carry `"place": "lab"`: it shows in Lab, between Hosts and Services, and not on Today. Missing or unknown
means `today` (older apps ignore the field and show it on Today). A `metrics` card with `place: "lab"` is never taken
as the day card. Lab draws `list` and `metrics` cards as rows (DESIGN.md §6): a status dot, the item `title`, the
`subtitle` as its reason, the `value` in the data font at the right (under the name at accessibility sizes), a thin
bar for `progress`, and an item `action` as a button at the end (the usual confirm). `tint` is the status: `yellow` or
`orange` is a warning (gold), `red` a problem (love), anything else normal. The first three users:

| Card id | What | Rows |
|---|---|---|
| `tailnet` | The tailnet's nodes | name, "linux · direct", "online" or "seen 3 h ago"; a key that expires soon `yellow`, expired or an offline server `red` |
| `dns` and `dns-top` | Ad blocking | Queries, Blocked, Blocking with a "Pause 5 min" button (`dns-pause`); the blocked domains |
| `backups` | Backup runs | what, size or snapshots, "today 04:52", `progress` for space used |

## Auth

| Way | Who adds it | App setting |
|---|---|---|
| Identity header, e.g. `Tailscale-User-Login` from `tailscale serve` | The reverse proxy, never the app | Login "Tailscale / proxy" |
| `Authorization: Bearer <token>` | The app (token from the Keychain) | Auth "Token" |

The app never sends an `Origin` header or cookies. Plain `http://` only works for LAN names, `.local` and private or
tailnet IPs (iOS ATS rules); everything else needs `https://`. A token never goes over plain `http://`: a token server
(and Home Assistant) needs `https://`, except `http://localhost`, `127.0.0.1`, `::1` and `*.ts.net` names; the app
sends nothing to it otherwise (see [SECURITY.md](SECURITY.md)).

## Tolerant client: rules the app follows

Other people's servers send odd JSON, so the app is forgiving. A server can rely on this:

| You send | The app does |
|---|---|
| A field it doesn't know (at any level) | Ignores it |
| A missing field (all but `api` in `/info`, `id` in hosts, pending and cards, `text` in problems) | Shows nothing for it |
| An unknown enum value (`status`, `style`, `tint`, `severity`) | `status` → derived from problems or `unknown`; `style` → `list`; `tint` → `gray`; `severity` → `problem` |
| A number as a string (`"0.5"`), `"yes"`/`"no"` for booleans | Reads it |
| An object or list where a single value belongs | Drops that field, keeps the rest |
| A bad element in a list (no id, wrong type) | Drops that element, keeps the list |
| `mem_pct`, disk percent outside 0–100, `progress` outside 0–1 | Clamps it |
| A history value that isn't a number, more than 288 points | A gap; keeps the newest 288 |
| Duplicate ids | Keeps the first |
| A problem as a plain string | Treats it as `{text}` |
| A link that isn't `http`/`https` | Drops the link |
| An item or card `action` without a valid `name`, or a `payload` value that isn't a string | Drops the action; drops that value |
| Times: ISO 8601 with or without zone, or epoch s/ms/µs/ns | Reads them; without a zone they mean the server's local time, read in the phone's zone (the same in a homelab). Send a zone if they can differ |

The fixtures in `Sources/HomelabKit/Fixtures/` show all of this, and the tests check it. `state-unknown-fields.json`
is the "everything odd at once" example.

## Minimal examples

`GET /info`

```json
{"api": 1, "name": "My homelab", "features": ["status", "hosts", "actions", "chat"], "auth": "identity",
 "commands": ["/status", "/help"], "standing_approvals": false}
```

`GET /state`

```json
{"status": "warning", "checked": "2026-11-04T21:28:00",
 "problems": [{"id": "nas-disk", "text": "nas: disk / at 91%", "host": "nas", "severity": "warning"}],
 "hosts": [{"id": "nas", "name": "nas", "reachable": true, "load": 0.4, "mem_pct": 38, "disks": {"/": 91}}],
 "pending": [{"id": "ab12", "action": "restart", "arg": "nas smb", "reason": "smb is down",
              "buttons": {"approve": "HOMELAB_APPROVE_ab12_0123456789abcdef", "deny": "HOMELAB_DENY_ab12_2123456789abcdef"}}],
 "cards": [{"id": "note", "title": "Note", "style": "text", "text": "Backup at **6 of 8 GB**."}],
 "busy": []}
```

`GET /messages?after=0`

```json
{"messages": [{"id": 1762290600000000000, "ts": "2026-11-04T21:10:00", "from": "agent", "job": "watchdog",
               "status": "ALERT", "text": "nas: smb is down."}], "busy": []}
```

`POST /messages` with `{"text": "/status"}` → `{"ok": true, "id": 1762290600000000001}`

`POST /button` with `{"action": "HOMELAB_APPROVE_ab12_0123456789abcdef"}` → `{"text": "approved ab12"}`

`GET /actions` (feature `run-actions`)

```json
{"actions": [{"name": "wake-set", "label": "Wake-up", "icon": "alarm", "fields": [],
              "arg": [{"label": "Wake me", "parts": [{"kind": "date", "label": "Day"}, {"kind": "literal", "text": "T"},
                                                     {"kind": "time", "label": "Time"}]},
                      {"label": "No wake-up", "parts": [{"kind": "date", "label": "Day"}, {"kind": "literal", "text": ":off"}]}]},
             {"name": "todo-add", "label": "Add a to-do", "icon": "checklist",
              "fields": [{"name": "summary", "label": "To-do", "kind": "text", "max": 120, "required": true},
                         {"name": "due", "label": "Due", "kind": "date-or-datetime", "max": 25,
                          "hidden_when": {"list": ["shopping"]}}]}]}
```

A field may carry `hidden_when`: `{"<other field>": ["value", ...]}`. While that other field's current value is one of
the listed ones, the app hides the field and doesn't send it (Due on the shopping list). Unknown field names and
non-list values are ignored (the field stays visible). The server still refuses what the action refuses with 400.

`POST /actions/wake-set` with `{"arg": "2026-11-07T07:30", "payload": {}}` → `{"ok": true, "text": "Done: wake-set 2026-11-07T07:30"}`

`GET /services`

```json
{"services": [{"name": "Grafana", "url": "https://grafana.example.ts.net", "group": "Monitoring", "icon": "chart.xyaxis.line"}]}
```

## What `/info` changes in the app

| Field | Effect |
|---|---|
| `features` | Which tabs and sections show. No `actions` and no `run-actions` → no Actions tab; `run-actions` → the "Start" list on it; no `chat` → no Chat tab; no `services` → no launcher; `documents` → the Scan tile on the Actions tab (the tab shows for it alone); `search` → the "Find a movie or show" tile on the Actions tab (the tab shows for it alone) and the search link; `share` → the share extension sends links. Missing list = `status` + `hosts` only |
| `commands` | Quick buttons above the chat input. Only `/word` entries, at most 24 chars, no spaces, the first 8. Empty = no buttons |
| `standing_approvals` | `true`: the "Always" confirm says the action will run by itself from now on. `false`/missing: it says that is up to the server |
| `auth` | Informational (`identity`, `token`, `none`); the app sends what its server setting says |
| `api` | Must be `1`. Anything else: an error that asks to update the app |

## Actions the app starts (`run-actions`)

`pending` are actions the server **proposes**; the owner approves them. With `run-actions` the owner can also
**start** actions: the Actions tab lists `GET /actions` under "Start", each opens a form, and after a confirm step
the app sends `POST /actions/<name>`. The server runs it at once (the owner asked, not a model) and answers with its
output. It must check everything again; the form only keeps obviously wrong input from being sent.

| Part of an action | The form shows |
|---|---|
| `arg` (list of variants) | A picker between the variants when there are several ("Wake me" / "No wake-up"), then one control per part: `date` a day picker, `time` a time picker, `choice` a menu, `number` and `word` a text field. `literal` parts are fixed text. The argument is the parts joined: `2026-11-07` + `T` + `07:30`. A day starts at tomorrow, a time at 07:00, a choice at its first option |
| `fields` | The payload: `text` and `multiline` text fields, `date`/`datetime`/`date-or-datetime` a picker behind a switch when the field is optional (a day sends `2026-11-07`, with a time `2026-11-07T08:00`, local time), `number` a number field, `choice` a menu. Empty optional fields are not sent |
| `destructive` | The confirm button is red |
| `hint` | One line under the form |

A field may carry `"hidden": true` (a to-do's `uid`): the app never shows it and never asks for it, but when an action is
started from a card or an item (`action.payload`), every prefilled value of a known field is sent, hidden ones included.
A form started from a Start tile sends no hidden field. An action may carry `"start": false` (missing = true): no Start
tile, only card and item actions use it (`todo-done`, `read-later-done`, `parcel-done`). A parcel item in a list card can
carry `action: {"name": "parcel-done", "label": "Delivered", "arg": "<parcel id>"}` (a trailing button, with a confirm) and
`url` (its tracking page, https, opened on tap). `wake-set` may offer a third variant `{Day}:clear` ("Normal").

Links from pushes and notifications: `homelab://today`, `homelab://actions`, `homelab://chat`, `homelab://lab` open that
tab (`overview` and `home` still open Today). `homelab://search?q=` opens the search screen (see above).
`homelab://actions/<name>?arg=…&<field>=…` opens a Start action's form filled in (never a hidden field, never a
`start: false` action; the owner still confirms): see [SHORTCUTS.md](SHORTCUTS.md).

The result shows as an alert: `ok` false is an error, `running` says the result will come in the chat. A variant
with a part kind the app doesn't know is dropped; an action left with no usable variant is not shown.

A pending action only shows the buttons the server sends: a missing `always` means no Always button; no buttons at
all means the action is shown for information only. The app's "waiting for you" notification offers `approve` and
`deny` as notification buttons (not `always`) and sends the same `POST /button`; it looks the signed string up again
in its last `/state` (or a fresh one) when pressed, so a button that is spent by then gets the usual 403.

## Host history and containers (Lab)

Two optional fields on each host in `GET /state`. Without them Lab looks as before.

```json
{"id": "media", "name": "media", "reachable": true, "load": 3.1, "cpu_count": 4,
 "history": {"step": 300, "end": "2026-11-06T13:40:00",
             "load": [0.4, 0.5, null, 3.1], "mem_pct": [41, 42, null, 88], "temp": [48.2, 49.0, null, 71.2],
             "disk_pct": [91, 91, null, 93]},
 "container_list": [{"name": "sonarr", "state": "running", "health": "unhealthy", "restarts": 2, "restartable": true},
                    {"name": "gluetun", "state": "exited", "health": null, "restarts": 3, "restartable": true}]}
```

| Field | Meaning | The app shows |
|---|---|---|
| `history` | The last 24 h, one point every `step` seconds, oldest first; the last point is at `end` (local time, or with a zone; missing → the host's `checked`). Every series is optional and ends at `end`; `null` = no data for that slot (host unreachable). At most 288 points per series. `disk_pct` is the fullest disk | A load sparkline on each host tile and, in Overkill, under each machine on Today. Host details: load, memory, temperature and fullest disk for 24 h with min, max and now. Gaps break the line; the line turns gold or love only when the newest value is over a limit (load ≥ cores / ≥ 2 × cores, memory 90 / 95 %, temperature 80 / 90 °C, disk 75 / 90 %) |
| `container_list` | Every container of the host: `name`; `state` (Docker's: `running`, `exited`, `restarting`, `paused`, `created`, `removing`, `dead`; "Up 3 hours" also counts as running); `health` (`healthy`, `unhealthy`, `starting` or null); `restarts` (Docker's RestartCount); `restartable` (the host's restart list has it: `restart-container` with `<host>:<name>` would be accepted). `containers: {up, total}` stays | Host details: the list with problems first (exited, dead and unhealthy in love, restarting in gold), state, health and restarts in mono. A **Restart** button on each `restartable` one, when the server also offers `run-actions` with a `restart-container` action whose form can build `<host-id>:<name>`. It asks with a red button, runs the action like the Actions tab would and shows the answer |

## How the app shows cards

| You send | Today shows |
|---|---|
| A card with `id: "today"` (else the first `metrics` card) | The day under the headline. Items whose `value` is a clock time (`"06:20"`, `"7:05"`) become stops on a line through the day, in time order (not your order); the line fills up to now, past stops fade, the next one shows a countdown ("in 26 min"). Items without a clock time (`"?"`, `"too late"`, no value) are notes under the line. No clock times at all: the values in big numbers. No items: the card's `text` |
| `date` on a card (`"2026-11-07"`) | The day the card is about. On the `today` card: when it is the day after the phone's today, the card is **tomorrow's**: the header says "Tomorrow" (the card's `title`), no stop is past, nothing is filled, and the first stop counts down ("in 10 h 20 min"). Same for the Day widget. Missing, not a plain day, today or an old day: the normal day line |
| `cancelled: true` on an item | Struck through and grey (title, subtitle, value). A lesson that falls out |
| A `list` card with `id: "lessons"` | A row with a `tint` (`orange`) and not cancelled gets a gold dot in front: a substitution or room change (put the change in the subtitle). The time range goes in `value` |
| A card with `id: "weather"` | Drawn like any card (use `metrics`). Its `subtitle` (one plain line, "Rain from 15:00, take an umbrella") also shows under the headline's facts line in every density, Calm too (one secondary line). No location in it |
| Cards `briefing` (`text`), `grades` (`list`), `deadlines` | Conventions of the reference server, drawn by their style. A `text` card is Markdown |
| `progress` (0–1) on a `list` item | A ring with the percent in front of the row (a check mark at 1) |
| `tint` on an item | Warm tints (`orange`, `yellow`) are gold, `red` is love, `purple`/`pink` iris, the rest grey. Use it for status, not decoration |
| `style: "checklist"` | To-dos: a circle per item (filled when `done: true`), the title, the subtitle and `due` as a short day or time ("today 18:00", "tomorrow", "Mon", "13.11."). Tapping the circle of an item with an `action` asks once ("Tick off Milk?"), then runs it |
| `style: "countdown"` | Each item counts down to its `due` in big mono numbers: "40 min", "5 h", "2 d", "today" (a day without a time), "3 d ago". Gold when it's under 24 h ahead (or today), love when it's past. The app sorts the items by `due`, soonest first; items without `due` last |
| `due` on an item | A day (`"2026-11-07"`) or a time (`"2026-11-07T18:00"`, local without a zone). A time stays a time, 00:00 too ("Mon 00:00"); send a day without a time for a whole day |
| `action` on an item: `{name, label, arg, payload}` | One tap runs that action (`POST /actions/<name>` with `arg` and `payload`, all strings) after a confirm with `label` as its text, then Today refreshes. Shown only with `run-actions` and when `GET /actions` lists the action; payload fields the action doesn't have are dropped, and the server checks everything again |
| `action` on a card | A "+ `label`" button in the card's header (without `label`: the action's own label from `GET /actions`) that opens that action's form, **prefilled** with `payload` and `arg` (an `arg` that fits one of the action's variants picks it and fills its parts). Same rule: hidden unless `GET /actions` lists it |

| `style: "departures"` | Public transport (step 6c). One item per departure: `title` the direction ("Floridsdorf"), `subtitle` the stop ("Erlaaer Straße", plus ` · +3 min` when late and ` · planned` when only the timetable is known), `value` the clock text, `due` the time **with a zone**, `tint: "orange"` when late. Items with the same direction and stop form one row, in your order (put the relevant direction first); up to 4 per direction. Each row: direction and the next time (mono), the stop and the next three times; a late one has a gold "+3". Trains whose `due` has passed drop out every minute. `text` is the disruption line ("U6: Schadhaftes Fahrzeug") under the rows, with a gold triangle; set the card `tint` to `red` then. Also the **U6 widget** (lock screen rectangular, inline, circular; home screen small) |

Older apps show `checklist`, `countdown` and `departures` cards as `list` and ignore `done`, `due` and `action`.

```json
{"id": "todos", "title": "To-dos", "icon": "checklist", "style": "checklist",
 "action": {"name": "todo-add", "label": "Add", "payload": {"list": "todo"}},
 "items": [{"title": "Milk", "subtitle": "Shopping",
            "action": {"name": "todo-done", "label": "Tick off", "payload": {"item": "Milk", "list": "shopping"}}},
           {"title": "Water the plants", "done": true}]}
```

```json
{"id": "deadlines", "title": "Deadlines", "icon": "hourglass", "style": "countdown",
 "items": [{"title": "Project hand-in", "subtitle": "School", "due": "2026-11-09"},
           {"title": "Driving lesson", "due": "2026-11-05T08:00"}]}
```

Clock times are read in the phone's time zone, like times without a zone (see above).

## Commute (Live Activity "Leave by")

`state.commute` is optional. When it is there and `date` is today, the app can show **Leave by 07:26 · U6 07:31** on
the lock screen (a Live Activity) until the first lesson:

```json
{"commute": {"date": "2026-11-07", "mode": "u6", "line": "U6",
             "first_lesson": "2026-11-07T08:00:00+01:00", "leave_by": "2026-11-07T07:26:00+01:00",
             "train": "2026-11-07T07:31:00+01:00", "next": "2026-11-07T07:36:00+01:00", "next_too_late": true,
             "disruptions": ["U6: Schadhaftes Fahrzeug"], "updated": "2026-11-07T07:12:00+01:00"}}
```

| Field | Meaning |
|---|---|
| `date` | The day it is for. Required; anything else is ignored. A plan for another day is never shown |
| `mode` | `u6` (default when there is a `train`) or `bike` |
| `first_lesson`, `leave_by`, `train` | Needed for a train day; if one is missing there is nothing to show. Times with a zone |
| `next`, `next_too_late` | The train after it; `next_too_late` adds ", too late" |
| `disruptions` | Short titles; the first shows with a gold triangle (and "+1" for more) |
| `mode: "bike"` + `ride` | Bike day: `first_lesson`, `leave_by` and `ride` (minutes), no `train`/`next` |
| `{date, error}` / `{date, active: false, why}` | Nothing to show; a running activity ends |

The app starts it only **in the foreground**, from 90 minutes before `leave_by` until `first_lesson`, with the
Settings toggle "Leave-by on the lock screen" on and Live Activities allowed (iOS Settings). It updates (the pick
changed) or ends (first lesson, another day, error, toggle off) from the app and from the background refresh, which
iOS runs every 15 to 60 minutes or less. No push: the countdown runs by itself and the activity turns stale at the
train's time. The server's own "Leave by" notification stays the reliable alert.

## Widgets

The widgets read the app's last snapshot. For a server reached by identity (`auth: identity`, Tailscale) they also GET
`/state` themselves when that snapshot is older than 5 minutes (8 s timeout, no token, no redirects), so they stay fresh
with the app closed. Token servers are never fetched by widgets. With the app lock on, the deadlines and to-do widgets
show counts only; the U6 widget (public times) stays.

## Chat messages with proposals and cards

A message from `GET /messages` (and `state.last_message`) may carry two more lists:

| Field | The chat shows |
|---|---|
| `pending` | Proposals made in this message that are **still waiting**: the same objects, with the same signed buttons, as in `state.pending`. Approve / Always / Deny right in the bubble, with the same confirm and `POST /button` as the Actions tab. The server computes the list when it answers, so approved, denied or expired proposals disappear from the message |
| `cards` | Cards inside the bubble, compact, under the text. Any style |

```json
{"id": 1762290600000000000, "from": "agent", "job": "watchdog", "status": "ALERT",
 "text": "media: sonarr unhealthy. Proposed: `restart media sonarr` (ab12).",
 "pending": [{"id": "ab12", "action": "restart", "arg": "media sonarr",
              "buttons": {"approve": "HOMELAB_APPROVE_ab12_0123456789abcdef", "deny": "HOMELAB_DENY_ab12_2123456789abcdef"}}]}
```

## Checking a live server

`scripts/check-live-api [--token T] [-v] [BASE_URL]` (bash and python3, nothing to install) checks a server against
this contract. It only sends GETs: `/info`, `/state`, then `/actions`, `/services`, `/messages?after=0` and
`/search?q=matrix` when `features` lists `run-actions`, `services`, `chat` and `search`. It follows no redirects.
Without `BASE_URL` it uses `HOMELAB_URL` or the first line of `~/.config/homelab-ios/check-live-api.url`, so your
server's address stays out of the repo; the reference server is `http://127.0.0.1:8791`. On a tailnet `tailscale serve`
adds your identity; for a token server use `--token` or `HOMELAB_TOKEN`.

Every answer is checked against `server/openapi.yaml`, then against what the app relies on. The script prints a
PASS/WARN/FAIL/SKIP table and the details, and exits 1 on any error.

| Error (exit 1) | Warning |
|---|---|
| No answer, not 200, not a JSON object; `api` not 1; a missing required field (`api`, `id` in hosts, pending and cards, `text` in problems, `name` in actions, `name`/`url` in services); a required field of the wrong type | Something from the tolerance table above: unknown enum values, upper-case enums, numbers or booleans sent as strings, values out of range, objects or lists where a single value belongs, non-http(s) links, plain-string problems. Unknown fields are fine and not reported |
| Duplicate ids (hosts, problems, pending, cards, messages, actions, fields, containers per host, search results) | Messages out of id order or more than 200, a message's `pending` that differs from `state.pending` |
| A time the app can't read (`time`, `checked`, `since`, `created`, `ts`, `end`, `due`) | A history `end` after the answer's `time`, a series of only nulls or with non-numbers |
| A card or item `action` that `/actions` doesn't list, an `arg` that fits none of its variants, a one-tap item action without a field the action requires | Payload keys the action doesn't have, a card-only action (`todo-done`, `read-later-done`, `parcel-done`, or one with a hidden field) without `"start": false` |
| A field that is `hidden` and `required` (or `required` with `hidden_when`); an `arg` variant with a part kind the app doesn't know, a literal without text or a choice without options; an action left with no usable variant | `hidden_when` naming no other field, a choice field without options, two free parts (`word`, `number`) in a row |
| A history series over 288 points; a restartable container whose `<host>:<name>` restart-container can't build | A restartable container with no `restart-container`, `containers` counts that differ from `container_list`, a restart host option that isn't a host |
| A `poster`/`image`/`thumb`-like URL on another server (send it relative) | The same URL absolute on this server |
| The `today` card's `date` not a plain `YYYY-MM-DD` day | A `date` in the past or more than a day ahead |
| A long hex string (32+), a known token shape (GitHub, `sk-`, `tskey-`, Slack, AWS, JWT, private key, `Bearer ...`) or a field named `token`/`password`/`api_key` with a value, anywhere except signed `buttons` | |

## Versioning

- `api: 1` and the `/api/v1/` prefix stay for every compatible change.
- Servers may **add** fields, enum values, features and endpoints at any time: the app ignores what it doesn't know.
- Removing or renaming a field, or changing its meaning or type, is a breaking change: it goes to `/api/v2/` with
  `api: 2`. The app checks `api` and shows a clear error instead of guessing.
