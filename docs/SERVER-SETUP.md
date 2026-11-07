# Connecting your homelab

New here? [GETTING-STARTED.md](GETTING-STARTED.md) picks one of the three setups with you and walks through it from
installing the app to a working Today. This page has every detail.

The app talks to two kinds of server. You can add several of each in Settings → Add server.

| Type in the app | Speaks | What it fills |
|---|---|---|
| Homelab API | The Homelab Companion API v1 ([`server/openapi.yaml`](../server/openapi.yaml)) | Today, Lab, Actions, Chat, widgets |
| Home Assistant | Home Assistant's REST API | The Home tiles on Today |

There are three ways to connect your homelab:

- (a) the reference server from this repo: a Homelab API server for any Linux box, also as the Homelab Bridge in
  [Docker](#docker) with a Tailscale sidecar,
- (b) Home Assistant on its own: only the Home tiles on Today,
- (c) your own agent or script that speaks the Homelab API.

You can combine them, for example the reference server plus Home Assistant. Settings → "Show data from" picks the
Homelab API server, "Home tiles from" the Home Assistant.

All examples assume [Tailscale](https://tailscale.com) on the server and on the phone. Any VPN to your home network
works too; then use `https://` with a certificate the phone trusts, or plain `http://` on a local address.

## (a) Reference server

`server/reference_server.py` is one Python file (3.9+, no packages). It reports this machine (load, memory,
temperature, disks, Docker containers, apt updates), checks other hosts and web apps, and can serve cards, a service
launcher, actions and chat. All options: [REFERENCE_SERVER.md](REFERENCE_SERVER.md).

### The 5-minute path (Debian or Ubuntu, behind `tailscale serve`)

1. Copy the server and write a config:

   ```bash
   git clone https://github.com/Qantrex/homelab-ios /tmp/homelab-ios
   sudo mkdir -p /opt/homelab-companion /etc/homelab-companion
   sudo cp /tmp/homelab-ios/server/reference_server.py /opt/homelab-companion/
   sudo cp /tmp/homelab-ios/server/config.example.json /etc/homelab-companion/config.json
   sudo nano /etc/homelab-companion/config.json
   ```

   Change at least `name`, `allowed_logins` (your Tailscale login: the e-mail, or `name@github` for GitHub logins;
   a refused login is printed in the server log), and
   `this_host.disks`. Set `"docker": false` unless the service user may run `docker ps`. Delete the example `hosts`,
   `checks` and `services` you don't have. A minimal config:

   ```json
   {
     "name": "homeserver",
     "trust_identity_header": "Tailscale-User-Login",
     "allowed_logins": ["you@example.com"],
     "this_host": {"kind": "server", "disks": ["/"], "updates": true},
     "hosts": [{"id": "gaming-pc", "name": "Gaming PC", "kind": "desktop", "check": "ping://100.64.0.20", "sleeps": true}]
   }
   ```

   `"sleeps": true` shows a sleeping PC as "Asleep", not as a problem. Test it once with the PC awake: if it
   still shows Asleep, `ping` isn't allowed for the service user (the hardened unit blocks it); use a TCP check of
   a port the PC opens instead, for example `tcp://100.64.0.20:47989` (Sunshine). Use the PC's `100.x` address: a server
   running `tailscale up --accept-dns=false` can't resolve MagicDNS names (the app then shows a warning).

2. Run it with systemd. Copy the unit from [REFERENCE_SERVER.md → Run it with systemd](REFERENCE_SERVER.md#run-it-with-systemd)
   to `/etc/systemd/system/homelab-companion.service`, then:

   ```bash
   sudo useradd --system --home /var/lib/homelab-companion --shell /usr/sbin/nologin homelab-companion
   sudo systemctl daemon-reload && sudo systemctl enable --now homelab-companion
   journalctl -u homelab-companion -n 20
   ```

   The log should say `listening on http://127.0.0.1:8791`.

3. Publish it in your tailnet. Pick a free HTTPS port (`tailscale serve status` lists the used ones;
   `tailscale serve` replaces whatever already runs on that port). If your tailnet has an ACL policy, allow that
   port for your phone:

   ```bash
   sudo tailscale serve --bg --https=7443 http://127.0.0.1:8791
   ```

4. Test it from another tailnet device:

   ```bash
   curl https://<machine>.<tailnet>.ts.net:7443/api/v1/info
   ```

   You should see `{"api": 1, "name": "homeserver", ...}`. A 403 means your login is not in `allowed_logins`.

5. In the app: Add server → Type **Homelab API** → Address `https://<machine>.<tailnet>.ts.net:7443` → Login
   **Tailscale / proxy** → Test connection ("Connected to homeserver: status and hosts.") → Save.

### Docker

Run the **Homelab Bridge** (the reference server with its [sources](REFERENCE_SERVER.md#sources)) with Docker
Compose: the bridge and a Tailscale sidecar. The sidecar is a machine of its own in your tailnet, `homelab-bridge`.
The bridge listens on `127.0.0.1:8791` in the network namespace it shares with the sidecar, and nothing else; no port
is opened on the Docker host. `tailscale serve` in the sidecar is the only way in: it adds HTTPS and your login
(`Tailscale-User-Login`). **Never use Tailscale Funnel for it**: Funnel puts it on the public internet.

You need Docker with Compose 2.17 or newer on Linux (`/dev/net/tun`), and in the Tailscale admin console MagicDNS and
HTTPS certificates turned on (DNS page).

1. Get the files and make your copies (they stay out of git):

   ```bash
   git clone https://github.com/Qantrex/homelab-ios
   cd homelab-ios/server
   cp docker/config.example.json docker/config.json
   cp docker/bridge.env.example docker/bridge.env
   cp docker/tailscale.env.example docker/tailscale.env
   chmod 600 docker/bridge.env docker/tailscale.env
   ```

2. In `docker/config.json` set `name`, `allowed_logins` (your Tailscale login: the e-mail, or `name@github`) and your
   `sources`. The config names each key's env variable (`"key_env": "KUMA_KEY"`); the key itself goes in
   `docker/bridge.env` (`KUMA_KEY=...`).
3. In the admin console: Settings → Keys → **Generate auth key** (not reusable, not ephemeral; pre-approved if your
   tailnet approves devices). Put it in `docker/tailscale.env` as `TS_AUTHKEY=`. It is read once; the login then
   stays in the volume `tailscale-state`, and you can delete the key from the file.
4. Start it:

   ```bash
   docker compose up -d --build     # builds the image from this checkout
   docker compose ps                # both "healthy" after a minute
   docker compose logs bridge       # "listening on http://127.0.0.1:8791 (RealApp)"
   ```

5. Test it from another tailnet device:

   ```bash
   curl https://homelab-bridge.<tailnet>.ts.net/api/v1/info
   ```

   A 403 means your login is not in `allowed_logins`; `docker compose logs bridge` shows the refused login. A 401 means
   the request didn't come through the bridge's `tailscale serve` address. If the machine never appears in your tailnet,
   `docker compose logs tailscale` shows an expired or already used auth key (add `--profile docker` to step 4 if you
   use the `docker` source).
6. In the app: Add server → Type **Homelab API** → Address `https://homelab-bridge.<tailnet>.ts.net` → Login
   **Tailscale / proxy** → Test connection → Save.

Notes:

- **What it can reach.** Your LAN and the internet through the sidecar (`http://192.0.2.10:3001`), and other tailnet
  machines by their `100.x` address. `127.0.0.1` is the container itself, not the Docker host: use the host's LAN
  address for services on the same machine (a service bound only to the host's `127.0.0.1` can't be reached).
- **This machine** in the app is the container: load and memory are the Docker host's (same kernel), `/` is Docker's
  disk. The image has no `docker` CLI and no `apt`, so keep `this_host.docker` and `updates` off. For containers, the
  Docker source reads them through the socket proxy: `docker compose --profile docker up -d` starts it
  ([wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy), pinned by digest) with `GET
  /containers/json` and nothing else: no container details (they hold every container's env, so its keys), no logs,
  no files, no POST. The bridge reaches it at `http://socket-proxy:2375`. For Restart (`"actions": {"restart":
  [...]}`), add the commented `-allowPOST=/containers/(sonarr|gluetun)/restart` line in `compose.yaml` with exactly
  your containers. Never mount the Docker socket into the bridge.
- **Why the sidecar needs `NET_ADMIN` and `/dev/net/tun`.** It runs Tailscale with kernel networking
  (`TS_USERSPACE=false`). In userspace mode, tailscaled hands tailnet connections to the namespace's `127.0.0.1`
  ports, so any tailnet device could reach the bridge on `:8791` past `tailscale serve` and fake the login header.
  The image guards against it: with `trust_identity_header: Tailscale-User-Login` it refuses to start when
  `TS_USERSPACE=true` is in its env, and logs a `WARNING` when the shared namespace has no `tailscale0` interface a
  minute after the start (userspace mode has none). `HOMELAB_ALLOW_USERSPACE=1` in `docker/bridge.env` starts it
  anyway; do that only with the ACL below, and with tokens instead of the login header if you can.
- **Tokens** for tagged devices or `curl`: `HOMELAB_TOKENS` in `docker/bridge.env`. Devices with tags get no login
  header from `tailscale serve`.
- **ACLs.** Let your devices reach only port 443 of the bridge machine. Tag it `tag:bridge` (add the tag below to
  the access controls first, then pick it when you generate the auth key in step 3, or later on the machine's page)
  and allow only HTTPS to it:

  ```json
  {
    "tagOwners": {"tag:bridge": ["autogroup:admin"]},
    "grants": [
      {"src": ["autogroup:member"], "dst": ["tag:bridge"], "ip": ["tcp:443"]}
    ]
  }
  ```

  No other rule may reach `tag:bridge` on another port. The default policy's allow-all rule (`"src": ["*"], "dst":
  ["*"], "ip": ["*"]`) does: replace it with rules that name their destinations. With this, even a sidecar that
  ended up in userspace mode can't be reached on `127.0.0.1:8791` from the tailnet. The login header still comes
  from the device that connects (your phone, not tagged), so `allowed_logins` works as before.
- **Hardened.** The bridge runs as user 10001 with a read-only root, no capabilities and `no-new-privileges`; its
  only writable places are `/tmp` (in memory) and the `bridge-state` volume (chat history). Actions and chat run
  commands inside that container, which has only Python and BusyBox.
- **Health.** Each container has a healthcheck. The bridge's asks `/api/v1/info` once a minute, so its log has one
  `GET /api/v1/info 401` line a minute.
- **Updates.** `git pull && docker compose up -d --build`. The Tailscale image and the socket proxy are pinned by
  digest in `compose.yaml`; a newer one is a change to that line. The bridge image is never `latest`: by default it
  is `ghcr.io/qantrex/homelab-bridge:local`, built from your checkout. The published image (built by hand, see
  [RELEASE.md](RELEASE.md#homelab-bridge-image)) needs a pinned version in `server/.env`:
  `BRIDGE_TAG=2026.11.07-1a2b3c4` (`scripts/build-bridge-image` tags each image `<commit date>-<short sha>`; add
  `@sha256:<digest>` after it to pin the content too), then `docker compose pull bridge && docker compose up -d`.

### Containers without the docker group

`"docker": true` needs `docker ps`, and the docker group is root-equivalent. To show container counts without
it, let root write a card every 5 minutes with the script in this repo:

```bash
sudo install -m 755 /tmp/homelab-ios/server/examples/card-containers /usr/local/bin/card-containers
sudo install -d -m 755 /var/lib/homelab-companion/cards
echo '*/5 * * * * root /usr/local/bin/card-containers /var/lib/homelab-companion/cards' | sudo tee /etc/cron.d/homelab-containers
```

Then set `"cards_dir": "/var/lib/homelab-companion/cards"` in the config. (A script and not a one-line cron job:
cron cuts a line at every unescaped `%`.) Or read them through a socket proxy with the `docker` source below.

### Sources

With a `sources` list the reference server is the Homelab Bridge: it reads other services' APIs and shows what
they report on Today and in Lab. Copy the `server/sources/` folder next to `reference_server.py`. The common keys
(`name`, `type`, `url`, `every`, `timeout`, `*_env`) are in [REFERENCE_SERVER.md → Sources](REFERENCE_SERVER.md#sources),
one section per type there; each module's docstring has the details. Keys go in env variables, never in the config.

#### Pick your sources

Start with what tells you something is wrong, then add more. One source per service instance; two Kuma status pages
are two sources with different names.

| You run | Type | Gives you |
|---|---|---|
| Uptime Kuma | `uptime-kuma` | Down monitors as problems, a card "11 of 12 up" |
| Gatus | `gatus` | Failing endpoints as problems, a card |
| Game servers (Minecraft Java, Valheim, Palworld, CS2, ...) | `gameserver` | A card with each server's state, players and version. Only pings, never wakes a sleeping server |
| A script or another server that writes JSON | `json` ([REFERENCE_SERVER.md → JSON feed](REFERENCE_SERVER.md#json-feed)) | Whatever it sends: problems, hosts, cards, services. On the bridge's own machine, `cards_dir` is simpler |
| Docker (through a socket proxy) | `docker` | Unhealthy, restarting and crashed containers as problems |
| Proxmox VE | `proxmox` | Nodes as hosts with 24 h history, VMs and containers per node |
| Pi-hole or AdGuard Home | `pihole`, `adguard` | The ad blocking card (queries, blocked, on or off), a warning while it is off |
| Sonarr, Radarr | `sonarr`, `radarr` | Health problems, the download queue with progress, what comes in the next days |
| qBittorrent | `qbittorrent` | Running downloads with progress, torrents in error |
| Homepage (its `services.yaml`) | the `homepage` key | Its services in the launcher, its Kuma, Gatus, Proxmox, Pi-hole (v6), AdGuard, Sonarr, Radarr, qBittorrent and Minecraft widgets as sources ([Import from Homepage](#import-from-homepage)) |

Each source, its keys and the access it needs:

| Type | What it reads | Keys | Access it needs | Tested with |
|---|---|---|---|---|
| `json` | One URL that answers a subset of `/state` (your own script, or another Companion server) ([JSON feed](REFERENCE_SERVER.md#json-feed)) | `url`; `key_env`, `key_header` | None, or a token sent as a bearer token (or in `key_header`) | the shape of `server/openapi.yaml` |
| `uptime-kuma` | The monitors of one status page: down = problem; pending, slow (`slow_ms`) and a certificate that expires within `cert_days` (14) = warning; a pinned "danger" or "warning" incident. A card "11 of 12 up" in Lab, links as services with `services: true` ([Uptime Kuma](REFERENCE_SERVER.md#uptime-kuma)) | `url`, `slug`; `slow_ms`, `cert_days`, `services` | None: the public status page JSON. Only the monitors on that page show | 2.5.9 and 1.23.16 |
| `gatus` | All endpoints: failing = problem; failing only on `[RESPONSE_TIME]`, `[CERTIFICATE_EXPIRATION]` or `[DOMAIN_EXPIRATION]`, or slower than `slow_ms` = warning. A card "11 of 12 up" in Lab ([Gatus](REFERENCE_SERVER.md#gatus)) | `url`; `slow_ms`; `user` with `password_env` | None, or the `security.basic` user (OIDC can't be used) | v5.38.0 |
| `gameserver` | Minecraft Java (Server List Ping) and Valve A2S servers: online or offline, players, version, MOTD. A card in Lab; a down server is a problem only with `expect_up`. Status pings only, never a login, so a sleeping server behind `mc-router` stays asleep ([Game servers](REFERENCE_SERVER.md#game-servers)) | `servers` (`name`, `type`, `host`, `port`, `players`, `expect_up`) | None: the servers' public status ports (TCP for Minecraft, UDP for A2S) | Java 1.21 and A2S as documented by Valve |
| `docker` | One Docker host's containers: unhealthy, restarting, dead and crashed ones as problems ([Docker](REFERENCE_SERVER.md#docker)) | `url` (a socket proxy), `host`, `ignore`, `actions` | No key; a socket proxy that allows only `GET /containers/json` | Engine 29 (API 1.52) and older |
| `proxmox` | Nodes as hosts with 24 h history, VMs and containers as each node's container list ([Proxmox](REFERENCE_SERVER.md#proxmox)) | `url`, `token_id`, `key_env`, `ca_file`, `expect_running`, `actions` | An API token with `Sys.Audit` and `VM.Audit` (or PVEAuditor) | 9.0 |
| `pihole` | Queries, blocked and blocking as the `dns` card in Lab, the top blocked domains; blocking off = warning ([Pi-hole](REFERENCE_SERVER.md#pi-hole)) | `url`, `key_env`, `top`, `actions` | A Pi-hole v6 app password | FTL v6.8 |
| `adguard` | The same `dns` cards; protection off or DNS not running = warning ([AdGuard Home](REFERENCE_SERVER.md#adguard-home)) | `url`, `username`, `password_env`, `top`, `actions` | An AdGuard Home user (basic auth) | v0.107.80 |
| `sonarr`, `radarr` | Health as problems, the download queue in Lab with progress, the next episodes or releases as a countdown on Today ([Sonarr and Radarr](REFERENCE_SERVER.md#sonarr-and-radarr)) | `url`, `key_env`, `queue`, `calendar_days` | The API key (Settings → General) | Sonarr 4.0.20, Radarr 6.4.4 |
| `qbittorrent` | Running downloads in Lab (progress, speed, time left); errors and a lost connection = warning ([qBittorrent](REFERENCE_SERVER.md#qbittorrent)) | `url`, `key_env` or `username` and `password_env`, `limit` | An API key (5.2 and newer) or a WebUI login | 5.1 and 5.2 |

```json
"sources": [
  {"name": "Kuma", "type": "uptime-kuma", "url": "http://192.0.2.10:3001", "slug": "home"},
  {"name": "Gatus", "type": "gatus", "url": "http://192.0.2.10:8080", "slow_ms": 2000}
]
```

The slug is the part after `/status/` in the status page's address. A status page only for the bridge is fine.
Whole configs: [`sources-monitors.json`](../server/examples/sources-monitors.json) (Kuma and Gatus),
[`sources-docker-proxmox.json`](../server/examples/sources-docker-proxmox.json),
[`sources-dns-media.json`](../server/examples/sources-dns-media.json) (Pi-hole, AdGuard, Sonarr, Radarr, qBittorrent)
and [`sources-json.json`](../server/examples/sources-json.json).

All sources only read. Docker restart, Proxmox start and stop and the ad blockers' pause are off until you list the
containers, VMIDs or pause lengths under `actions` ([Source actions](REFERENCE_SERVER.md#source-actions)).

### Import from Homepage

If you already run [Homepage](https://gethomepage.dev), the bridge can read its `services.yaml` instead of you
writing `services` and `sources` again:

```json
"homepage": {"file": "/homepage/services.yaml"}
```

- **Launcher.** Every service with an `http(s)` `href` becomes an entry in the app's service launcher: its name,
  `href`, `description`, the innermost group as its group, and an SF Symbol for well-known icon names
  (`sonarr.png`, `mdi-jellyfin`, `si-proxmox` and about 100 more; others get the app's globe). Entries already in
  the config's own `services` (same name and URL) are not repeated.
- **Sources.** A widget whose `type` the bridge has a source for becomes that source, named after the service
  (`Uptime Kuma`, a second one `Uptime Kuma 2`), with the `every` of the `homepage` object. All other widgets are
  listed in the log at start as `not yet supported by the Homelab Bridge`, a Pi-hole v5 as `not supported`; their
  keys are never read.

| Homepage widget `type` | Bridge source | From the widget |
|---|---|---|
| `uptimekuma` | `uptime-kuma` | `url`, `slug`. The monitors' links are not added to the launcher (Homepage's entries are) |
| `gatus` | `gatus` | `url`; `username` + `password` (both, as Homepage sends HTTP Basic only then) become `user` + `password_env` |
| `proxmox` | `proxmox` | `url`; `username` (the API token's id, `user@realm!id`) becomes `token_id`, `password` (its secret) `key_env`. Proxmox mostly has a self-signed certificate and the bridge checks it: add `ca_file` (or `insecure`) with `extra` |
| `pihole` | `pihole` | `url`; `key` (the password or an app password) becomes `key_env`. Only with `version: 6` or newer: a widget without `version` or with `version: 5` (Homepage then reads the v5 API) is logged as `not supported` (Pi-hole v5 or older) and its key is not read |
| `adguard` | `adguard` | `url`; `username` + `password` (both, as Homepage sends HTTP Basic only then) become `username` + `password_env` |
| `sonarr`, `radarr` | `sonarr`, `radarr` | `url`; `key` (the API key) becomes `key_env`. `enableQueue` is Homepage's own view: the bridge's queue card is always on (`"queue": 0` with `extra` turns it off) |
| `qbittorrent` | `qbittorrent` | `url`; `key` (an API key, qBittorrent 5.2 and newer) becomes `key_env`; without `key`, `username` + `password` become `username` + `password_env`, as Homepage logs in only then |
| `minecraft` | `gameserver` | `url` (`udp://host:port`) becomes one server named like the service; the bridge pings over TCP, status only. `gamedig` is not imported (its server types are Gamedig's own names): write an `a2s` server by hand |
| `jellyfin`, `plex`, others | not yet | Logged as not yet supported; their keys are never read |

Imported sources never get `actions`: the pause button of a Pi-hole or AdGuard stays opt-in, written by hand in the
bridge's config (`"extra": {"Pi-hole": {"actions": {"pause": [5, 15, 30]}}}`), see
[REFERENCE_SERVER.md → Source actions](REFERENCE_SERVER.md#source-actions).

Docker containers that Homepage shows through `server` and `container` (its `docker.yaml`) are not imported: add a `docker` source through a socket proxy instead.

<!-- {% raw %} -->
**Keys stay in env variables.** Homepage replaces `{{HOMEPAGE_VAR_X}}` with the env variable `HOMEPAGE_VAR_X` and
`{{HOMEPAGE_FILE_X}}` with the content of the file that `HOMEPAGE_FILE_X` names. The bridge does the same for
addresses and descriptions, but for a key it only takes the variable's **name**: `password:
"{{HOMEPAGE_VAR_GATUS_PASSWORD}}"` becomes `"password_env": "HOMEPAGE_VAR_GATUS_PASSWORD"`, and the value is read
like any other source key and never answered or logged. So give the bridge the same variables as Homepage (the same
`env_file`, and the same mounted files for `HOMEPAGE_FILE_`). A key written in `services.yaml` itself, or a user,
password or key in a widget's `url`, stops the bridge at start for a widget it would import, with a message that
names the service and the variable to use. The key is never printed. Move it to the env, or leave that service
out with `skip`. A launcher entry whose address would hold a key is left out.
<!-- {% endraw %} -->

| Key in `homepage` | Default | Meaning |
|---|---|---|
| `file` | required | Homepage's `services.yaml`. A relative path is relative to the directory the bridge runs in |
| `sources` | `true` | `false`: only the launcher, no sources from widgets |
| `every` | `60` | Seconds between two reads of each imported source |
| `skip` | `[]` | Services or groups to leave out, by name (any case) |
| `extra` | `{}` | More keys for the source made from a service's widget, by service name: `{"Proxmox": {"ca_file": "/config/pve-root-ca.pem", "expect_running": [101]}}`. Checked like any source's keys (no keys in it; `actions` stay opt-in per item) |

With [Docker](#docker), mount Homepage's config folder read-only into the bridge (`- /path/to/homepage/config:/homepage:ro` under the bridge's `volumes` in `server/compose.yaml`) and put the `HOMEPAGE_VAR_` variables in `docker/bridge.env`. The file is read once at start: restart the bridge after editing it. The log says what became what (`homepage:
Monitoring / Gatus: widget gatus is the source 'Gatus' (gatus)`), and `/info` lists the imported sources like any
other. Reading YAML needs PyYAML: the Homelab Bridge Docker image has it; `reference_server.py` alone stays
stdlib-only and, without PyYAML, stops with `homepage: reading services.yaml needs PyYAML, ...` (install
`python3-yaml` or `pip install pyyaml`, or remove the key).
[`server/examples/sources-homepage.json`](../server/examples/sources-homepage.json) imports
[`server/examples/homepage-services.yaml`](../server/examples/homepage-services.yaml); its `_comment` has the
commands to run it against the fake upstreams.

Next steps, all optional: cards from your own scripts, a service launcher, actions and chat. See
[REFERENCE_SERVER.md](REFERENCE_SERVER.md). Actions and chat are off by default; read their safety notes first.

## (b) Home Assistant

Today shows the few devices you pin as tiles: lights, switches, fans, toggles, automations (tap to toggle), scripts,
scenes and buttons (tap to run), sensors and binary sensors (state only). Pin only what you use often; the Home
Assistant app stays the place for everything else.

1. In Home Assistant: your profile → Security → **Long-lived access tokens** → Create token. Copy it; HA shows it
   only once. A separate HA user just for the phone makes it easy to revoke later.
2. In the app: Add server → Type **Home Assistant** → Address as you open HA in a browser, for example
   `https://<machine>.<tailnet>.ts.net:8443` behind `tailscale serve` (see the notes below) → paste the token → Test connection ("Home Assistant
   answers.") → Save.
3. On Today, in the **Home** section → **Edit** (or "Pin the lights or scripts you use most") → pick them → Done.

Notes:

- Home Assistant needs `https://`: its token is a login to your home, and the app never sends a token over plain
  `http://` (not to `http://homeassistant.local:8123`, a LAN IP or a raw `100.x` tailnet IP either: anyone on that
  network could read it). Put HA behind `tailscale serve` (`sudo tailscale serve --bg --https=8443 http://127.0.0.1:8123`,
  then `https://<machine>.<tailnet>.ts.net:8443`) or use HA's own TLS. See [SECURITY.md](SECURITY.md) → Plain http.
- The token is stored in the iOS Keychain. Anyone with it can control your home, so delete it in HA if the phone is
  lost.
- If HA is behind a reverse proxy, HA must trust that proxy (`use_x_forwarded_for` and `trusted_proxies` in its
  `http:` block), or it answers 400.

## (c) Your own server

Anything that serves the JSON in [`server/openapi.yaml`](../server/openapi.yaml) works: your homelab agent, a
script, a small web app. Only `/api/v1/info` and `/api/v1/state` are needed. Add the rest when you want them:

| Path | Needed for | Feature in `/info` |
|---|---|---|
| `GET /api/v1/info` | Test connection, which tabs to show | – |
| `GET /api/v1/state` | Today, Lab, Actions list, widgets, notifications | `status`, `hosts`, `cards` |
| `POST /api/v1/button` | Approve / Always / Deny | `actions` |
| `GET` + `POST /api/v1/messages` | Chat | `chat` |
| `GET /api/v1/services` | Service launcher | `services` |

The app shows the Actions tab only with `actions`, and the Chat tab only with `chat` in `features`.

### Minimal example

Python, stdlib only. It reports this machine's load and root disk:

```python
#!/usr/bin/env python3
# Minimal Homelab API v1 server: /info and /state. Loopback only; tailscale serve goes in front.
import hmac, json, os, shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("HOMELAB_TOKEN", "")    # optional bearer token, for devices without a login header
LOGINS = {"you@example.com"}                   # Tailscale logins that may read

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        login = (self.headers.get("Tailscale-User-Login") or "").lower()
        bearer = (self.headers.get("Authorization") or "").encode()
        if login not in LOGINS and not (TOKEN and hmac.compare_digest(bearer, b"Bearer " + TOKEN.encode())):
            return self.reply(401, {"error": "unauthorized"})
        if self.path == "/api/v1/info":
            return self.reply(200, {"api": 1, "name": "My homelab", "features": ["status", "hosts"]})
        if self.path == "/api/v1/state":
            du = shutil.disk_usage("/")
            pct = round(du.used * 100 / du.total)
            problems = [{"id": "disk-root", "text": f"/ is {pct}% full", "severity": "warning"}] if pct >= 90 else []
            host = {"id": "server", "name": "Server", "kind": "server", "reachable": True,
                    "load": os.getloadavg()[0], "cpu_count": os.cpu_count(), "disks": {"/": pct}}
            return self.reply(200, {"status": "warning" if problems else "ok", "problems": problems, "hosts": [host]})
        self.reply(404, {"error": "not found"})

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

ThreadingHTTPServer(("127.0.0.1", 8792), Handler).serve_forever()
```

Then `sudo tailscale serve --bg --https=7444 http://127.0.0.1:8792` and add `https://<machine>.<tailnet>.ts.net:7444`
in the app. The login check only works because the server listens on `127.0.0.1` and `tailscale serve` is the only
thing in front of it. Any local process could fake the header, so don't run untrusted code on that machine.

### Auth: pick one

| | Identity header | Bearer token |
|---|---|---|
| How | `tailscale serve` adds `Tailscale-User-Login` to every request from a tailnet device. The app sends nothing | The app sends `Authorization: Bearer <token>` |
| In the app | Login: **Tailscale / proxy** | Login: **Token** |
| Server must | Listen on loopback only. Trust the header only from `127.0.0.1`. Check the login against a list | Compare in constant time. Use 16+ random characters. One token per device, so you can revoke one |
| Doesn't work for | Tagged devices (no login header), other VPNs | – |

Answer 401 when there is no identity and 403 when the identity is not allowed. The app shows a matching text for
each.

### Rules the app follows (so your server can be simple)

From `openapi.yaml`:

- Every field is optional except the ones marked `required` (`api` in Info, `id` in Host, Card, PendingAction and
  Message, `name` + `url` in Service).
- Unknown fields and unknown enum values are ignored. You may add fields at any time. Breaking changes go to
  `/api/v2/`.
- A problem can be an object or a plain string (treated as `{text}`).
- Times are ISO 8601. Without a time zone they mean the server's local time; the app reads them in the phone's
  time zone, which is the same in a homelab. Send a zone (`+01:00` or `Z`) if they can differ.
- All text from the server is untrusted plain text. Inline Markdown is shown (bold, code, links), no HTML, and only
  `http`/`https` links.
- The app never sends an `Origin` header and never sends cookies. A server may refuse requests that have an `Origin`
  (browsers).

What the app also does:

- An item that can't be read is skipped; the rest still shows.
- Status also accepts `healthy`/`up`/`green` (ok), `warn`/`degraded`/`yellow` (warning) and
  `error`/`alert`/`critical`/`down`/`red` (problem).
- An answer with `Content-Type: text/html` is treated as "not a Homelab API server".
- For 400, 413, 415 and 422, the app shows `{"error": "..."}` from the body (first 200 characters).
- Button strings come from `pending[].buttons` and are sent back unchanged in `POST /button` as `{"action": "..."}`.
  The app can't check them; your server must. A missing verb means that button isn't shown. Answer 403 for a forged,
  unknown or used button.
- Chat messages are 1–4000 characters. `busy` (in `/state` and `/messages`) makes the chat show "Working…".

To see what the app expects, compare your answers with the fixture files in `Sources/HomelabKit/Fixtures/`
(`info.json`, `state-ok.json`, `state-problem.json`, `messages.json`, `services.json`). Test with `curl`, the same way
as in step 4 above.
