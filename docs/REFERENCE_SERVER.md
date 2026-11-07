# Reference server

`server/reference_server.py` lets the Homelab iOS app talk to **any** homelab. It speaks the Companion API v1
(`server/openapi.yaml`). It is one Python file. It needs Python 3.9 or newer and nothing else.

It fits a typical setup: one Linux server with Docker apps on `127.0.0.1`, `tailscale serve` in front, maybe a PC
that sleeps. It needs no agent, no Home Assistant and no monitoring stack.

What it shows in the app:

| Tab / feature | Where the data comes from |
|---|---|
| Status, problems | Failing checks, unreachable hosts, full disks, hot CPU, unhealthy containers |
| Hosts | This machine (load, memory, temperature, disks, containers, updates) plus other hosts (reachable or not) |
| Cards | Every `*.json` file in `cards_dir` (your own scripts write them) |
| Services | The `services` list in the config |
| Actions | Opt-in. Files in `pending_dir`, approved in the app, run a whitelisted command |
| Chat | Opt-in. `chat_command` gets the message on stdin and prints the answer |
| Start (actions the app starts itself, `run-actions`) | Not here (only in fixture mode). The owner's agent has it; [API.md](API.md) describes it for your own server |

It has two modes:

| Mode | Command | Use |
|---|---|---|
| Real | `reference_server.py --config config.json` | Your homelab |
| Fixture | `reference_server.py --fixtures Sources/HomelabKit/Fixtures` | A mock for the app's tests and screenshots |

## Quick start

```bash
sudo mkdir -p /opt/homelab-companion
sudo cp server/reference_server.py /opt/homelab-companion/
cp server/config.example.json config.json      # edit it: name, logins, disks, hosts, checks, services
python3 /opt/homelab-companion/reference_server.py --config config.json
```

Then publish it in your tailnet. One example (use any free HTTPS port; `tailscale serve status` lists the used ones.
**`tailscale serve` replaces whatever is already served on that port**, so check first):

```bash
sudo tailscale serve --bg --https=7443 http://127.0.0.1:8791
```

In the app, add the server as `https://<machine>.<tailnet>.ts.net:7443`. With `trust_identity_header` set, the app
needs no token. Test it from another tailnet device:

```bash
curl https://<machine>.<tailnet>.ts.net:7443/api/v1/info
```

## Run it with systemd

`/etc/systemd/system/homelab-companion.service`:

```ini
[Unit]
Description=Homelab Companion API (reference server)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=homelab-companion
ExecStart=/usr/bin/python3 /opt/homelab-companion/reference_server.py --config /etc/homelab-companion/config.json
# HOMELAB_TOKENS=... and HOMELAB_BUTTON_SECRET=... (chmod 600, owned by root)
EnvironmentFile=-/etc/homelab-companion/env
StateDirectory=homelab-companion
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/homelab-companion
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd --system --home /var/lib/homelab-companion --shell /usr/sbin/nologin homelab-companion
sudo systemctl daemon-reload && sudo systemctl enable --now homelab-companion
journalctl -u homelab-companion -f
```

Notes:

- Set `"state_dir": "/var/lib/homelab-companion/state"` when chat is on.
- `"docker": true` needs `docker ps`. The `docker` group is root-equivalent, so think before you add the user to it.
- `NoNewPrivileges=yes` blocks `sudo`. Remove it only if an action needs `sudo` (see Actions).
- A user unit works too: put it in `~/.config/systemd/user/`, drop `User=` and the `Protect*` lines, and run
  `systemctl --user enable --now homelab-companion` (plus `loginctl enable-linger $USER`).

## Config keys

The config is JSON. Keys that start with `_` are comments and are ignored. Unknown keys are logged.

| Key | Default | Meaning |
|---|---|---|
| `name` | hostname | Title in the app |
| `listen` | `127.0.0.1:8791` | Address and port. `--port` overrides the port |
| `allow_remote` | `false` | Must be `true` to listen on a non-loopback address. Not recommended |
| `allowed_hosts` | `["localhost", "127.0.0.1", "::1", "*.ts.net"]` | Accepted `Host` headers (`*.` = any subdomain). Blocks DNS rebinding. Add your own name if you use a custom domain |
| `tokens` | `[]` | Bearer tokens. Env `HOMELAB_TOKENS` (comma-separated) adds more. Use 16+ random characters |
| `trust_identity_header` | none | Header set by the proxy, e.g. `Tailscale-User-Login`. Only trusted from `127.0.0.1` |
| `allowed_logins` | `[]` | Logins allowed via the header. Empty = any login the proxy sends |
| `interval` | `60` | Seconds between check rounds |
| `this_host.id` | hostname | Host id of this machine |
| `this_host.name` / `kind` / `url` | id / `server` / none | Shown in the app. `kind`: server, raspberry-pi, laptop, desktop, nas, vm |
| `this_host.disks` | `["/"]` | Mount points to report |
| `this_host.docker` | `false` | Count containers with `docker ps`. Unhealthy or restarting containers are problems |
| `this_host.updates` | `false` | Count `apt list --upgradable` |
| `this_host.updates_interval` | `21600` | Seconds between apt counts |
| `hosts[]` | `[]` | Other machines: `id`, `name`, `kind`, `url`, `check`, `sleeps`, `timeout` (5), `insecure` |
| `hosts[].check` | required | `tcp://host:22`, `ping://host` or `http(s)://...` (any HTTP answer = reachable) |
| `hosts[].sleeps` | `false` | Unreachable shows the flag `asleep` and is not a problem |
| `checks[]` | `[]` | `name`, `url`, `host`, `expect` (200, or a list), `severity` (`problem`/`warning`), `timeout` (5), `insecure` |
| `thresholds` | 90 / 95 / 80 | `disk_warning`, `disk_problem` (percent), `temp_warning` (°C) |
| `cards_dir` | none | Folder with card files. Turns on the `cards` feature |
| `services[]` | `[]` | `name`, `url`, `group`, `icon`, `description`. Turns on `services` |
| `pending_dir` | none | Folder with pending action files. Turns on `actions` |
| `actions` | `{}` | Action name → argv list, e.g. `["systemctl", "restart", "--", "{arg}"]` |
| `action_timeout` | `110` | Seconds an action may run |
| `chat_command` | none | argv list. Turns on `chat` |
| `chat_timeout` | `120` | Seconds the chat command may run |
| `state_dir` | `~/.local/state/homelab-companion` | Chat history (`messages.jsonl`, last 1000) |
| `sources[]` | none | Homelab Bridge sources: other services' APIs as problems, hosts, cards and services. See [Sources](#sources) |

`insecure: true` skips TLS certificate checks for that one URL (for self-signed local UIs such as Cockpit).
Checks never use an HTTP proxy from the environment.

`status` is `problem` if any problem has severity `problem`, else `warning` if there are any, else `ok`. It is
`unknown` until the first round is done. `/state` always answers at once with the last round.

## Cards from your own scripts

Write one JSON file per card into `cards_dir`. The server reads them on every `/state`. Bad files are skipped
and logged. A card needs a string `id`; all other fields are in `openapi.yaml` (`Card`). Without `updated`,
the file time is used. Delete the file to remove the card.

Write to a temp file and rename it, so the server never reads half a file:

```bash
#!/bin/sh
# cron: */15 * * * *  /usr/local/bin/card-backup
dir=/var/lib/homelab-companion/cards
last=$(date -r /var/log/restic-last.log '+%Y-%m-%d %H:%M' 2>/dev/null || echo never)
cat > "$dir/.backup.tmp" <<EOF
{"id": "backup", "title": "Backup", "icon": "externaldrive", "tint": "green", "style": "list",
 "items": [{"title": "restic", "subtitle": "last run", "value": "$last"}]}
EOF
mv "$dir/.backup.tmp" "$dir/backup.json"
```

Only `*.json` files count, so `.backup.tmp` is ignored. At most 50 cards; each file at most 64 KB.
Data on another machine, or problems and hosts too: a [JSON feed](#json-feed) source.

## Actions (opt-in, dangerous)

Actions let the app run commands on your server. They are off until you set `pending_dir` **and** `actions`.

How it works:

1. Your script writes `pending_dir/<id>.json`:
   `{"id": "ab12", "job": "watchdog", "action": "restart", "arg": "jellyfin", "reason": "Jellyfin is down."}`
   The id is 1–32 of `A-Z a-z 0-9 -`. Add `"offer_always": true` to also show an "Always" button.
2. The app shows it with signed buttons: `HOMELAB_<APPROVE|ALWAYS|DENY>_<id>_<sig>`, where `sig` is the first
   16 hex digits of HMAC-SHA256(secret, `"<VERB>:<id>:<sha256 of action, arg, created>"`). So a button only works
   for exactly the action the user saw: if a script reuses an id for a different action, old buttons stop working.
   The secret is env `HOMELAB_BUTTON_SECRET`; without it, a random one is made at every start.
3. Approve runs the argv list from `actions[action]`. No shell. `{arg}` must be a whole argv item; the arg is
   split at spaces into separate items. Always works like Approve (the server keeps no standing approvals).
   Deny runs nothing.
4. The file is removed after Approve or Deny. The answer text has the exit code and up to 2000 characters of output.

Safety rules in the server:

- Only names in `actions` can run. The arg is 1–64 character words of `A-Z a-z 0-9 _ . @ -`, separated by single
  spaces, and no word may start with `-` (so an arg can never become an option). Anything else (like `; rm -rf /`
  or `--force`) gets no Approve button and is refused.
- Forged, outdated, unknown or already used buttons get 403.
- Commands run as the server's user, without `HOMELAB_TOKENS` or `HOMELAB_BUTTON_SECRET` in their environment.
  They get `HOMELAB_PENDING_ID`, `HOMELAB_ACTION` and `HOMELAB_ARG`.

Your own rules:

- Anyone who can write to `pending_dir` can propose a command. Keep it owned by the server's user, mode 700.
- Prefer small wrapper scripts that check the arg again, over raw `systemctl` or `docker`.
- If an action needs root, allow exactly that wrapper in sudoers (`sudo -n /usr/local/bin/restart-stack`).

## Chat (opt-in)

Set `chat_command` to an argv list. Each message runs it once with the text on stdin (UTF-8). Its stdout is the
answer. Non-zero exit marks the answer `ERROR`. Only one runs at a time; a second message gets 429. Without
`chat_command`, `/messages` answers 404 and the app hides the chat tab.

The command gets the message text from someone you let in. Treat it as untrusted input.

## Security notes

- **Loopback only.** The server listens on `127.0.0.1` and refuses other addresses unless `allow_remote` is true.
  `tailscale serve` adds HTTPS and the tailnet boundary.
- **Never use `tailscale funnel`** for this. Funnel puts it on the public internet.
- **Auth is required.** The server will not start without tokens or an identity header. No credentials → 401.
  Wrong token or a login not in `allowed_logins` → 403. Tokens are compared in constant time.
- The identity header is only trusted from `127.0.0.1`, because that is where `tailscale serve` connects from.
  Any local process could also set it, so do not run untrusted code on the server. Set `allowed_logins`.
  A refused login is written to the log (`refused login 'name@github'`), so you can copy the exact spelling.
- The `Host` header must be in `allowed_hosts` (default: loopback and `*.ts.net`). This stops a web page from
  reaching the server through DNS rebinding.
  Devices with tags get no login header from `tailscale serve`; give them a token.
- Keep tokens out of the config file: use `HOMELAB_TOKENS` in a root-only `EnvironmentFile`.
- Requests with an `Origin` header (browsers) get 403. The app never sends one.
- POST needs `application/json` (else 415), at most 16 KB (else 413), and text of 1–4000 characters (else 400).
- The log has one line per request: client, method, path, status. No query, no headers, no tokens, no message text.
- Slow clients are cut off after 30 s without data.
- Actions and chat are off by default. Turn them on only if you need them.

## Sources

With a `sources` list the reference server becomes the **Homelab Bridge**: it also reads the APIs of other services
(Uptime Kuma, Docker, Proxmox, ...) and adds what they report to `/state` and `/services`. The app sees ordinary
Companion API data and needs nothing new. Without the key nothing changes (a golden test checks it).

Sources are optional modules in `server/sources/`, next to `reference_server.py` (copy the folder too). They are
stdlib only. The types are the files in that folder: [`json`](#json-feed) reads a feed in the shape of `/state`;
`example` is the template for new ones and reads a made-up API.

```json
"sources": [
  {"name": "Lab", "type": "example", "url": "http://192.0.2.10:8080", "key_env": "LAB_KEY", "every": 60}
]
```

`server/examples/sources-example.json` is a whole config with this source; [BRIDGE.md](BRIDGE.md#try-it) runs it
against a fake upstream.

| Key | Default | Meaning |
|---|---|---|
| `name` | required | 1–40 of `A-Z a-z 0-9`, space, `_ . -`, unique. Shown in warnings, and every id gets `<name>:` in front |
| `type` | required | The module: `server/sources/<type>.py` (a `-` in the type is `_` in the file name) |
| `url` | per type | The upstream's base URL, `http://` or `https://`, without a user, password or key in it |
| `every` | `60` | Seconds between two reads of this source. Each source has its own |
| `timeout` | `10` | Seconds per request |
| `key_env` | none | The **name** of the env variable that holds the key. Other `*_env` keys work the same (`password_env`) |
| `insecure` | `false` | Skip the TLS certificate check (self-signed Proxmox or TrueNAS). Logged as a warning |
| `ca_file` | none | A PEM file with the CA that signed the upstream's certificate (better than `insecure`) |
| other keys | | Per type, in the module's docstring |

Rules the server enforces for every source:

- **Keys only in env variables.** The config names the variable (`"key_env": "PVE_TOKEN"`), never the key. A source
  key such as `key`, `api_key`, `token` or `password` in the config, or a key in the URL, stops the server at start.
  Put the variables in the systemd `EnvironmentFile` next to `HOMELAB_TOKENS`. A source sees only the variables its
  own `*_env` keys name. Their values are replaced by `***` in every answer and log line, and commands from actions
  and chat don't get them.
- **Read-only.** A source can't offer actions; buttons on its cards and items are removed.
- **Ids are prefixed.** A Kuma monitor `m3` becomes the problem `Kuma:m3`, the host `pve1` of the source `Lab`
  becomes `Lab:pve1`. The card ids `today` and `departures` are refused.
- **A failing source is one warning.** A wrong key, a timeout, an odd answer or a bug in the module gives exactly one
  warning, for example `Kuma: 401` or `Lab: timeout`, and nothing else from that source. The rest answers as usual.
  The status is the worst of all problems.
- **Limits.** A request may take `timeout` seconds and return at most 8 MB. No redirects, no cookies, no proxy from
  the environment. At most 100 problems, 100 hosts, 50 cards and 100 services per source.
- Each source runs in its own thread, so a slow upstream never holds up the host checks or another source.

Writing a new source: [BRIDGE.md](BRIDGE.md).

### JSON feed

Type `json` reads one URL that answers a subset of `/state`: any of `problems`, `hosts`, `cards` and `services`, in
the shapes of [`server/openapi.yaml`](../server/openapi.yaml). Other keys (`status`, `time`, `pending`, ...) are
ignored; the status follows the problems, and the bridge keeps its own `since` per problem id.

```json
"sources": [
  {"name": "Backups", "type": "json", "url": "http://192.0.2.20:8080/homelab.json"},
  {"name": "Pi", "type": "json", "url": "https://pi.tail1234.ts.net/api/v1/state", "key_env": "PI_TOKEN"}
]
```

| Key | Default | Meaning |
|---|---|---|
| `url` | required | The feed's full URL |
| `key_env` | none | Env variable with a key, sent as `Authorization: Bearer <key>` |
| `key_header` | none | Send the key raw in this header instead (`X-Api-Key`). Needs `key_env` |

```json
{"problems": ["Backup of nas failed"],
 "hosts": [{"id": "nas", "kind": "nas", "reachable": true, "disks": {"/": 63}}],
 "cards": [{"id": "backups", "title": "Backups", "place": "lab", "items": [{"title": "nas", "value": "failed"}]}],
 "services": [{"name": "NAS", "url": "https://nas.tail1234.ts.net"}]}
```

It reads the feed as leniently as the app reads `/state`: numbers in strings count, a plain string is a problem's
text, `"yes"` and `1` are true, entries without an `id` (problems without `text`) are skipped, fields of the wrong
type and unknown fields are dropped. It never takes actions (`pending`, a card's or item's `action`, `restartable`)
or item `image`s (the app loads pictures only from the server it talks to). An answer that is not a JSON object, a
401 or more than 8 MB is one warning, as for every source.

**Feed or `cards_dir`?** A script on the bridge's own machine writes [card files](#cards-from-your-own-scripts) into
`cards_dir` (push: no web server, the card stays until you delete it). Use a `json` feed when the data lives on
another machine or a service already serves it over HTTP, when you want problems, hosts or services and not only
cards, or to show a second Companion server's hosts and problems (pull: gone with a warning when the feed is down).
`server/examples/sources-json.json` runs it against `server/recordings/json/normal.json`.

## Fixture mode

A mock for the app's unit tests, UI tests and CI screenshots. It serves the files in `Sources/HomelabKit/Fixtures/`.

```bash
python3 server/reference_server.py --fixtures Sources/HomelabKit/Fixtures --port 8791 \
    [--state state-problem.json] [--token T]
```

| Request | Answer |
|---|---|
| `GET /api/v1/info`, `/state`, `/services` | `info.json`, the chosen state file, `services.json` |
| `GET /api/v1/messages?after=N` | `messages.json` plus what was posted. `busy` is `["chat"]` while an echo is pending |
| `POST /api/v1/messages` | Stores the message; about 1 s later adds the reply `echo: <text>` |
| `POST /api/v1/button` | Only button strings in the current state file → `{"text": "approved ab12 (fixture)"}`, else 403 |
| `GET /api/v1/actions`, `POST /api/v1/actions/<name>` | `actions.json`; a run checks the shape (arg only if the action has one, known and required fields, all text), runs nothing, answers `Done: <name> <arg> (fixture)` and adds both lines to the messages |
| `POST /api/v1/documents` | Raw `application/pdf` (415 otherwise, 411 without Content-Length, 413 over 25 MB, 400 unless it starts with `%PDF-` or the `X-Homelab-Id` UUID is bad, 429 after 20 an hour). Keeps title and size in memory, files nothing, answers 202; the same id gets the first answer |
| `POST /api/v1/share` | JSON `{id, kind: "url", url, title}`: a willhaben ad id → route `willhaben`, other http(s) links → `read-later`; other schemes, user:password, over 2048 characters → 400; 30 an hour. Nothing is fetched or stored beyond memory |
| `GET /__control?state=state-ok.json` | Switches the state file. `&reset=1` resets the messages. No auth |

It binds `127.0.0.1` only. Without `--token` there is no auth.

## Tests

```bash
python3 -m unittest -v server/test_*.py
```

Stdlib only, no network beyond `127.0.0.1`. `test_reference_server.py` starts both modes, a tiny local web app for
the checks, and the CLI with SIGTERM; its `NoSourcesGolden` freezes the answers of a config without `sources`.
`test_sources.py` tests the [sources](#sources) rules against `server/fake_upstream.py`, which replays recordings
from `server/recordings/`; each source type has its own `test_source_<type>.py`.
