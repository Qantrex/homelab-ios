# Companion API v1

A short guide to [`server/openapi.yaml`](../server/openapi.yaml). The YAML file is the contract; this page explains it.
To try it, run the reference server (`server/reference_server.py`, see [REFERENCE_SERVER.md](REFERENCE_SERVER.md)).

## Endpoints

All paths are under `/api/v1/`. JSON in and out, UTF-8.

| Method + path | Body | Reply | The app uses it for |
|---|---|---|---|
| `GET /info` | – | `{api, name, server, version, features, auth, commands, standing_approvals}` | "Test connection", which tabs to show |
| `GET /state` | – | `{time, status, checked, problems, hosts, pending, cards, busy, last_message}` | Today, Lab, Actions, widgets, background refresh |
| `GET /messages?after=<id>` | – | `{messages: [...], busy: [...]}` | Chat (polls; `after` is the last id it has) |
| `POST /messages` | `{text}` (1–4000 chars) | `{ok, id}` | Sending a chat message or slash command |
| `POST /button` | `{action: "<signed string>"}` | `{text}` | Approve / Always / Deny on a pending action |
| `GET /services` | – | `{services: [{name, url, group, icon, description}]}` | The service launcher |
| `GET /actions` | – | `{actions: [{name, label, icon, hint, destructive, arg, fields}]}` | Feature `run-actions`: the "Start" list on the Actions tab and its forms |
| `POST /actions/<name>` | `{arg, payload}` | `{ok, text, running}` | Starting one of them, after the app's confirm step |

Status codes the app understands: 401/403 (identity missing or not allowed), 404 (feature not there), 400, 415, 429
(too many runs), 5xx. A forged or expired button gets 403; the app shows the error and refreshes the list.

## Auth

| Way | Who adds it | App setting |
|---|---|---|
| Identity header, e.g. `Tailscale-User-Login` from `tailscale serve` | The reverse proxy, never the app | Login "Tailscale / proxy" |
| `Authorization: Bearer <token>` | The app (token from the Keychain) | Auth "Token" |

The app never sends an `Origin` header or cookies. Plain `http://` only works for LAN names, `.local` and private or
tailnet IPs (iOS ATS rules); everything else needs `https://`.

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
| Duplicate ids | Keeps the first |
| A problem as a plain string | Treats it as `{text}` |
| A link that isn't `http`/`https` | Drops the link |
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
                         {"name": "due", "label": "Due", "kind": "date-or-datetime", "max": 25}]}]}
```

`POST /actions/wake-set` with `{"arg": "2026-11-07T07:30", "payload": {}}` → `{"ok": true, "text": "Done: wake-set 2026-11-07T07:30"}`

`GET /services`

```json
{"services": [{"name": "Grafana", "url": "https://grafana.example.ts.net", "group": "Monitoring", "icon": "chart.xyaxis.line"}]}
```

## What `/info` changes in the app

| Field | Effect |
|---|---|
| `features` | Which tabs and sections show. No `actions` and no `run-actions` → no Actions tab; `run-actions` → the "Start" list on it; no `chat` → no Chat tab; no `services` → no launcher. Missing list = `status` + `hosts` only |
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

The result shows as an alert: `ok` false is an error, `running` says the result will come in the chat. A variant
with a part kind the app doesn't know is dropped; an action left with no usable variant is not shown.

A pending action only shows the buttons the server sends: a missing `always` means no Always button; no buttons at
all means the action is shown for information only.

## How the app shows cards

| You send | Today shows |
|---|---|
| A card with `id: "today"` (else the first `metrics` card) | The day under the headline. Items whose `value` is a clock time (`"06:20"`, `"7:05"`) become stops on a line through the day, in time order (not your order); the line fills up to now, past stops fade, the next one shows a countdown ("in 26 min"). Items without a clock time (`"?"`, `"too late"`, no value) are notes under the line. No clock times at all: the values in big numbers. No items: the card's `text` |
| `progress` (0–1) on a `list` item | A ring with the percent in front of the row (a check mark at 1) |
| `tint` on an item | Warm tints (`orange`, `yellow`) are gold, `red` is love, `purple`/`pink` iris, the rest grey. Use it for status, not decoration |

Clock times are read in the phone's time zone, like times without a zone (see above).

## Versioning

- `api: 1` and the `/api/v1/` prefix stay for every compatible change.
- Servers may **add** fields, enum values, features and endpoints at any time: the app ignores what it doesn't know.
- Removing or renaming a field, or changing its meaning or type, is a breaking change: it goes to `/api/v2/` with
  `api: 2`. The app checks `api` and shows a clear error instead of guessing.
