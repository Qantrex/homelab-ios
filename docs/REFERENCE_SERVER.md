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

In Docker, with a Tailscale sidecar and its sources: [SERVER-SETUP.md → Docker](SERVER-SETUP.md#docker).

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
| `allowed_logins` | `[]` | Logins allowed via the header. Empty = any login the proxy sends; with `sources` it must not be empty (the server stops at start) |
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
| `homepage` | none | `{"file": "/path/services.yaml"}`: Homepage's services as launcher entries, its Kuma, Gatus, Proxmox, Pi-hole (v6), AdGuard, Sonarr, Radarr, qBittorrent and Minecraft widgets as sources (never with actions). Needs PyYAML. See [SERVER-SETUP.md → Import from Homepage](SERVER-SETUP.md#import-from-homepage) |

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
`example` is the template for new ones and reads a made-up API. The real ones, their keys and the upstream versions
they are tested with: [SERVER-SETUP.md → Sources](SERVER-SETUP.md#sources).

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
| `insecure` | `false` | Skip the TLS certificate check (self-signed Proxmox or TrueNAS). Logged as a warning and flagged in `/info` |
| `ca_file` | none | A PEM file with the CA that signed the upstream's certificate (better than `insecure`) |
| `actions` | none | Opt-in, per type, only the listed items: `{"restart": [...]}` (docker), `{"start": [...], "stop": [...]}` (proxmox), `{"pause": [5, 15]}` (pihole, adguard). See [Source actions](#source-actions) |
| other keys | | Per type, in the module's docstring |

Rules the server enforces for every source:

- **Keys only in env variables.** The config names the variable (`"key_env": "PVE_TOKEN"`), never the key. A source
  key such as `key`, `api_key`, `token` or `password` in the config, or a key in the URL, stops the server at start.
  Put the variables in the systemd `EnvironmentFile` next to `HOMELAB_TOKENS`. A source sees only the variables its
  own `*_env` keys name. Their values are replaced by `***` in every answer and log line (also escaped, `%`-encoded
  and in base64, as error texts and Basic auth carry them), and commands from actions and chat don't get them. A
  value is stripped of spaces and line breaks at its ends; one with a line break or another control character inside
  stops the server at start, with the variable's name and never its value.
- **Keys over plain `http://`.** A source with a key (any `*_env`) whose `url` is `http://` to a host that is not
  `localhost` or `127.0.0.1` sends that key in clear text over the network. It still runs, but the log says so at
  start and `/info` flags it with `plain_http: true` (a gold warning in Diagnostics, like `insecure`). Use `https://`
  (with `ca_file` for a self-signed certificate), or reach the service over the tailnet.
- **Identity login needs `allowed_logins`.** With `trust_identity_header` and sources, an empty `allowed_logins` stops
  the server at start: the bridge holds other services' data and actions, so it names who may use it. Without
  sources an empty list still lets every login through, as before.
- **Texts and links from upstream.** A problem's text and a card's or item's `title`, `subtitle` and `value` lose
  their URLs (`<url>`) and every `key=value` or `token: value` with a secret-like name (`apikey=***`), and are cut
  to 200 characters (a card's `text` to 1000). A service or item link with a user or password (`user@host`) or a key
  in its query is dropped.
- **Read-only by default.** Buttons on a source's cards and items are removed. Only the docker, proxmox, pihole and
  adguard types can act (restart, start, stop, pause), and only for the items their config lists under `actions`:
  see [Source actions](#source-actions).
- **Ids are prefixed.** A Kuma monitor `m3` becomes the problem `Kuma:m3`, the host `pve1` of the source `Lab`
  becomes `Lab:pve1`. The card ids `today` and `departures` are refused.
- **A failing source is one warning.** A wrong key, a timeout, an odd answer or a bug in the module gives exactly one
  warning, for example `Kuma: 401` or `Lab: timeout`, and nothing else from that source. The rest answers as usual.
  The status is the worst of all problems.
- **Limits.** A request may take `timeout` seconds and return at most 8 MB. No redirects, no cookies, no proxy from
  the environment. At most 100 problems, 100 hosts, 50 cards and 100 services per source, 200 items per card and
  200 containers per host.
- Each source runs in its own thread, so a slow upstream never holds up the host checks or another source. An
  upstream that answers very slowly (a byte now and then) shows as `timeout` once the run is past `every + timeout`.
  `timeout` counts per wait for data, so such a request goes on in its thread until the upstream stops sending or
  8 MB have come; the source stays `timeout` and is not started again until then. The rest of the server is not
  held up.
- **Status in `/info`.** `/info` lists every source under `sources`: `state` (`ok`, `failing`, `never`), the last
  run, the last good run, the short error while failing, and `insecure: true` and `plain_http: true` as warnings. Without `sources` in the
  config the field is left out. Fields: [API.md → Source status](API.md#source-status-sources-in-info). The app
  shows them in Settings → Diagnostics → Sources.

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

### Uptime Kuma

Type `uptime-kuma` reads one public status page, the same two calls the page itself makes
(`/api/status-page/<slug>` and `/api/status-page/heartbeat/<slug>`). No key and no login: only the monitors on that
page are visible, so a status page just for the bridge is fine. Tested with Uptime Kuma 2.5.9 and 1.23.16.

```json
{"name": "Kuma", "type": "uptime-kuma", "url": "http://192.0.2.10:3001", "slug": "home"}
```

| Key | Default | Meaning |
|---|---|---|
| `slug` | required | The part after `/status/` in the status page's address |
| `slow_ms` | off | A monitor that is up but answered slower than this is a warning |
| `cert_days` | `14` | A certificate that expires within this many days is a warning (needs "Show Certificate Expiry" on the page; 0: off) |
| `services` | `false` | Monitors with a public link become launcher entries |

A down monitor is a problem, a pending one a warning, maintenance nothing; a pinned "danger" incident is a problem,
"warning" a warning. One list card in Lab: "11 of 12 up", a row per monitor with its state and 24 h uptime.

### Gatus

Type `gatus` reads `/api/v1/endpoints/statuses`, the call Gatus' own dashboard makes. Tested with Gatus v5.38.0.

```json
{"name": "Gatus", "type": "gatus", "url": "http://192.0.2.10:8080", "slow_ms": 2000}
```

| Key | Default | Meaning |
|---|---|---|
| `slow_ms` | off | An endpoint that passes but took longer than this is a warning |
| `user`, `password_env` | none | Only with Gatus' `security.basic`: that user and the plain password (OIDC can't be used) |

A failing endpoint is a problem with its first failed condition; failing only on `[RESPONSE_TIME]`,
`[CERTIFICATE_EXPIRATION]` or `[DOMAIN_EXPIRATION]` is a warning. One list card in Lab: "11 of 12 up". Gatus' error
texts are not shown (they hold the endpoint's URL). `server/examples/sources-monitors.json` has both monitor types.

### Docker

The `docker` type reads one Docker host through a **socket proxy**: a small container that holds the Docker socket
and lets through only the API calls you allow. Never mount `/var/run/docker.sock` into the bridge itself: whoever
can talk to that socket is root on the host. Tested against Docker Engine 29 (API 1.52) and older engines.

```json
{"name": "Docker", "type": "docker", "url": "http://socket-proxy:2375", "host": "nas", "ignore": ["backup-job"]}
```

| Key | Default | Meaning |
|---|---|---|
| `url` | required | The socket proxy |
| `host` | the name in lower case | The host id; `host_name` the shown name, `kind` the icon (`server`) |
| `ignore` | `[]` | Containers that never become problems (one-shot jobs) |
| `actions` | none | Opt-in: `{"restart": ["sonarr", "gluetun"]}`. See [Source actions](#source-actions) |

It reads `GET /containers/json?all=1` and gives one host with every container in its list (state and health) and
`containers: {up, total}`. Unhealthy, restarting and dead containers are problems; one that exited with a non-zero
code is a warning (`exited (137)`); exited with 0 is fine.

The socket proxy, in the compose file next to your containers:
[wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy), which lets through one regular expression
per method (it adds `^` and `$`), so exactly the container list and nothing else:

```yaml
services:
  socket-proxy:
    image: wollomatic/socket-proxy:1.13.2@sha256:ff95d6ff6c27853005ef85eb8f4ab5923dc3d2f1e055f98fb6aeeaceec3fe848
    restart: unless-stopped
    user: "0:0"            # uid 0 owns the socket; or "65534:<the docker group id>"
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges]
    command:
      - -listenip=0.0.0.0
      - -allowfrom=homelab-bridge          # the bridge's service name (server/compose.yaml: tailscale, its sidecar)
      - -allowGET=/containers/json         # only the list; every other GET and every POST is refused
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [socket-proxy]
  homelab-bridge:
    # ...the bridge, with "url": "http://socket-proxy:2375"
    networks: [socket-proxy]
networks:
  socket-proxy:
    internal: true      # no route out, and no published port
```

For Restart add exactly the containers under `actions.restart`, and only then:

```yaml
      - -allowPOST=/containers/(sonarr|gluetun)/restart
```

Don't use tecnativa/docker-socket-proxy for the bridge. Its `CONTAINERS=1` allows every GET under `/containers`,
not only the list: `/containers/<id>/json` holds each container's environment (so the keys of every other service on
that host), and `/logs`, `/archive` and `/export` give their logs and files. Its `ALLOW_RESTARTS=1` lets through
stop, restart and kill of every container, not only the ones on your list, and `POST=1` with `CONTAINERS=1` also
`POST /containers/create`, which is root on the host.

Which to pick: `this_host.docker: true` counts the containers of the machine the server runs on with `docker ps`
(the server's user needs the docker group, which is root-equivalent). The `docker` source reads any Docker host
through a socket proxy, lists every container, and is the one to use with the bridge in a container. Don't use both
for the same host, or its containers show twice.

### Proxmox

The `proxmox` type reads a Proxmox VE node or cluster with an **API token**. Tested against Proxmox VE 9.0 (and the
PVE 8 history format).

```json
{"name": "Proxmox", "type": "proxmox", "url": "https://192.0.2.20:8006", "token_id": "monitor@pve!bridge",
 "key_env": "PVE_TOKEN", "ca_file": "/etc/homelab/pve-root-ca.pem", "expect_running": [101]}
```

| Key | Default | Meaning |
|---|---|---|
| `url` | required | `https://<node>:8006` (plain `http://` only to `127.0.0.1` or `localhost`) |
| `token_id` | required | The token's name, `user@realm!id`. Not secret |
| `key_env` | required | The env variable with the token's secret (the UUID) |
| `ca_file` / `insecure` | system CAs | Proxmox's own certificate is self-signed: copy `/etc/pve/pve-root-ca.pem` and name it in `ca_file`. `insecure: true` skips the check instead and is logged and shown as a warning |
| `expect_running` | `[]` | VMIDs that are a problem while stopped |
| `disk_warning`, `disk_problem` | `90`, `95` | Percent of a node's root disk |
| `ui_url` | `url` | The link to the web UI on each node |
| `actions` | none | Opt-in: `{"start": [103], "stop": [101]}`. See [Source actions](#source-actions) |

Each node becomes a host (reachable, load, cores, memory, root disk) with its last 24 h from `rrddata` (load, memory
and disk in 5-minute steps, at most 288 points; PVE 8's 30-minute steps stay as they are). Its VMs and containers are
the host's container list (running, or stopped as exited; templates are left out). Problems: an offline node, a
full root disk, a stopped guest from `expect_running`, and a warning when the token can't read a node's details.

A read-only token (on any node, as root):

```bash
pveum role add HomelabBridge --privs "Sys.Audit VM.Audit"     # or use the built-in PVEAuditor
pveum user add monitor@pve --comment "Homelab Bridge"
pveum acl modify / --users monitor@pve --roles HomelabBridge
pveum user token add monitor@pve bridge --privsep 1           # prints the secret once
pveum acl modify / --tokens 'monitor@pve!bridge' --roles HomelabBridge
```

Put the secret in the bridge's environment as `PVE_TOKEN`, never in the config. With privilege separation the token
has at most what both the user and the token are given, so it can be revoked or narrowed alone.

### Pi-hole

Type `pihole` reads Pi-hole **v6** (`/api`; v5's `admin/api.php` is not supported). It logs in with an **app password**
(Settings → Web interface / API → Configure app password; Pi-hole has no read-only login), reads, and logs out again
after every run, so it never holds one of Pi-hole's few sessions.

```json
{"name": "Pi-hole", "type": "pihole", "url": "http://192.0.2.53", "key_env": "PIHOLE_APP_PASSWORD"}
```

| Key | Default | Meaning |
|---|---|---|
| `key_env` | none | The variable with the app password. Without it the Pi-hole must have no password |
| `top` | `5` | Blocked domains in the `dns-top` card (0: no card, no request) |
| `actions` | none | Opt-in: `{"pause": [5, 15, 30]}` (minutes). See [Source actions](#source-actions) |

It adds the card `dns` in Lab (Queries and Blocked in the last 24 h, Blocking `on`, `off · 4 min` while paused, `off`),
`dns-top` with the top blocked domains, and a warning while blocking is off for good or failed (a timed pause is not
a warning).

### AdGuard Home

Type `adguard` reads `/control/status` and `/control/stats` with basic auth. AdGuard Home has no read-only users or
API keys, so this password can change settings: keep it in the env file only.

```json
{"name": "AdGuard", "type": "adguard", "url": "http://192.0.2.54:3000", "username": "monitor",
 "password_env": "ADGUARD_PASSWORD"}
```

| Key | Default | Meaning |
|---|---|---|
| `username`, `password_env` | none | The AdGuard Home user and the variable with its password. Without `username` no auth is sent |
| `top` | `5` | As for `pihole` |
| `actions` | none | Opt-in: `{"pause": [5, 15, 30]}` (minutes). See [Source actions](#source-actions) |

It adds the same `dns` and `dns-top` cards (Queries for AdGuard's stats period: "24 h" or "7 days"), a warning while
protection is off for good and one while the DNS server is not running.

### Sonarr and Radarr

Types `sonarr` and `radarr` read the v3 API (Sonarr v3 and v4, Radarr v3 to v6) with the API key in `X-Api-Key`
(Settings → General → Security). They only read.

```json
{"name": "Sonarr", "type": "sonarr", "url": "http://192.0.2.30:8989", "key_env": "SONARR_KEY"}
```

| Key | Default | Meaning |
|---|---|---|
| `key_env` | required | The variable with the API key |
| `queue` | `10` | Rows in the queue card (0: no queue request, no card) |
| `calendar_days` | `7` | How far ahead the calendar looks (0: no calendar) |

- `/api/v3/health`: an error is a problem, a warning a warning, notices are left out.
- `/api/v3/queue`: card `queue` in Lab, one row per download (the episode as "Show S02E05", the movie with its year)
  with its state and reason ("Import blocked: Not an upgrade ..."), the time left and `progress`. A download that needs
  a hand (import blocked, failed) is also a warning.
- `/api/v3/calendar`: card `calendar` on Today (style `countdown`), what is not downloaded yet. Sonarr: each episode at
  its air time in the bridge's local time. Radarr: each movie's first digital, disc or cinema release in the window.

### qBittorrent

Type `qbittorrent` reads the WebUI API v2. With qBittorrent 5.2 and newer use an **API key** (Preferences → WebUI →
API key; sent as a bearer token, no login). Older versions log in with a WebUI user; the session cookie is sent back
as a header and the session is closed after every run.

```json
{"name": "qBittorrent", "type": "qbittorrent", "url": "http://192.0.2.20:8080", "key_env": "QBIT_API_KEY"}
```

| Key | Default | Meaning |
|---|---|---|
| `key_env` | none | The variable with the API key (5.2 and newer) |
| `username`, `password_env` | none | A WebUI login instead (older versions) |
| `limit` | `10` | Rows in the card, problems first, then soonest done |

It adds the card `downloads` in Lab (each running download with progress, speed and time left; the line under the
title has the total speeds) and warnings for torrents in error or with missing files and for a lost connection.

`server/examples/sources-dns-media.json` has all five of these types.

### Game servers

Type `gameserver` shows Minecraft Java servers and every server that answers Valve's A2S query (Valheim, Palworld,
CS2, Rust, ARK and more) as one card. It only **pings** and never wakes or changes anything: Minecraft gets the Server
List Ping (handshake, status request, read, close; never a login), Valve servers get A2S_INFO. So an
`itzg/mc-router` in front of a sleeping Paper server answers the ping itself and the backend stays asleep. There is no
wake action (a login wakes a server, and the bridge never sends one).

```json
{"name": "Games", "type": "gameserver", "servers": [
  {"name": "Survival", "type": "minecraft", "host": "mc.example.com", "port": 25565},
  {"name": "Valheim", "type": "a2s", "host": "nas.tail1234.ts.net", "port": 2457, "players": true, "expect_up": true}
]}
```

| Key (per server) | Default | Meaning |
|---|---|---|
| `name`, `type`, `host` | required | The shown name (unique in the source); `minecraft` or `a2s`; a host name or IP address |
| `port` | `25565` / `27015` | For `a2s` the **query** port, which for some games is not the game port (Valheim: game port + 1) |
| `players` | `false` | `a2s` only: also ask A2S_PLAYER for the player names (Minecraft sends a sample by itself) |
| `handshake_host` | `host` | `minecraft` only: the address the ping claims to connect to, for a router that picks the backend by name |
| `expect_up` | `false` | A server that does not answer is a problem. Off by default: game servers sleep and stop, so Offline is normal |

One list card in Lab, "2 of 3 up", a row per server: `Running · 2/10 · Paper 26.3 · alice, bob +3` (at most five
names), `Sleeping · 0/0 · mc-router · <MOTD>` when the MOTD says the server sleeps (a router answers for it; also
"Starting" for a MOTD that says starting or waking), `Offline` when nothing answers. Bots in A2S don't count as
players. A problem exists only for an `expect_up` server that does not answer, and it comes back with the next read
that fails, so don't set it for a server that restarts nightly. The source itself is never failing because a game
server is down.

The servers are asked in parallel, each for at most four seconds in all (DNS included), and a reply that is too big,
cut short, not JSON, not what the protocol says or sent one byte at a time is just Offline. MOTDs, version and player
names are shown as one line: `§` formatting codes, control characters and invisible characters are removed, links
become `<url>`. A Valve server since 2020 answers with a challenge first; that is handled. Only the plain ping is
used, so an `a2s` server must have its query port reachable from the bridge over UDP. `server/sources/gameserver.py`
has the details. Homepage's `minecraft` widget imports as one server; `gamedig` is not imported.

### Source actions

Off by default. A source acts only on the items its config lists under `actions`, and nothing else:

| Type | Config | In the app | Upstream call | Needs |
|---|---|---|---|---|
| `docker` | `"actions": {"restart": ["sonarr"]}` | Restart on the container (host page) and the Actions tab: `restart-container` | `POST /containers/<name>/restart` | a socket proxy that allows exactly that |
| `proxmox` | `"actions": {"start": [103], "stop": [101]}` | The Actions tab: `guest-start`, `guest-stop` (a clean shutdown) | `POST /nodes/<node>/<qemu or lxc>/<vmid>/status/start` or `shutdown` | `VM.PowerMgmt` on `/vms/<vmid>` for those guests |
| `pihole`, `adguard` | `"actions": {"pause": [5, 15, 30]}` (minutes) | "Pause 5 min" (the shortest) or "Resume" on the card's Blocking row, and the Actions tab: `dns-pause` with each listed length and Resume | Pi-hole `POST /api/dns/blocking`, AdGuard `POST /control/protection` | nothing more than the read (Pi-hole's app password, AdGuard's user) |

Then the server offers the app's `run-actions` (`GET /actions`, `POST /actions/<name>`); without `actions` there is
no `/actions` at all. The app asks before each press (a red button for restart and stop). The server checks every
press again:

- The argument must be exactly one from the list: `<source>:<host>:<container>` for Docker (what the app builds from
  the prefixed host id), `<source>:<vmid>` for Proxmox, `<source>:<minutes>` or `<source>:on` for a pause. It is looked up, never parsed, put in a shell or used to build
  a URL from what the app sent.
- No payload; at most 30 presses an hour in all; one press per item at a time; 404 for an action that isn't offered.
- The answer says what happened ("Restarted sonarr on nas.") or why not ("Docker: sonarr failed (403)"), without a
  URL or a key. Every press is logged. After a press that worked, the source is read again at once.
- A button on a source's card (the ad blockers' Blocking row) stays only when its action and argument are on
  the list; every other button from a source is removed.

For a Proxmox stop or start token, give `VM.PowerMgmt` only on those guests:

```bash
pveum role add HomelabBridgePower --privs "VM.PowerMgmt"
pveum acl modify /vms/101 --users monitor@pve --roles HomelabBridgePower
pveum acl modify /vms/101 --tokens 'monitor@pve!bridge' --roles HomelabBridgePower
```

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
