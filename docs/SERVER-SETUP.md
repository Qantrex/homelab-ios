# Connecting your homelab

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

   A 403 means your login is not in `allowed_logins`; `docker compose logs bridge` shows the refused login.
6. In the app: Add server → Type **Homelab API** → Address `https://homelab-bridge.<tailnet>.ts.net` → Login
   **Tailscale / proxy** → Test connection → Save.

Notes:

- **What it can reach.** Your LAN and the internet through the sidecar (`http://192.0.2.10:3001`), and other tailnet
  machines by their `100.x` address. `127.0.0.1` is the container itself, not the Docker host: use the host's LAN
  address for services on the same machine (a service bound only to the host's `127.0.0.1` can't be reached).
- **This machine** in the app is the container: load and memory are the Docker host's (same kernel), `/` is Docker's
  disk. The image has no `docker` CLI and no `apt`, so keep `this_host.docker` and `updates` off. For containers, the
  Docker source reads them through the socket proxy: `docker compose --profile docker up -d` starts it (read-only,
  container list only); the bridge reaches it at `http://socket-proxy:2375`. Never mount the Docker socket into the
  bridge.
- **Why the sidecar needs `NET_ADMIN` and `/dev/net/tun`.** It runs Tailscale with kernel networking
  (`TS_USERSPACE=false`). In userspace mode, tailscaled hands tailnet connections to the namespace's `127.0.0.1`
  ports, so any tailnet device could reach the bridge on `:8791` past `tailscale serve` and fake the login header.
- **Tokens** for tagged devices or `curl`: `HOMELAB_TOKENS` in `docker/bridge.env`. Devices with tags get no login
  header from `tailscale serve`.
- **ACLs.** If your tailnet has an ACL policy, allow port 443 of `homelab-bridge` for your phone.
- **Hardened.** The bridge runs as user 10001 with a read-only root, no capabilities and `no-new-privileges`; its
  only writable places are `/tmp` (in memory) and the `bridge-state` volume (chat history). Actions and chat run
  commands inside that container, which has only Python and BusyBox.
- **Health.** Each container has a healthcheck. The bridge's asks `/api/v1/info` once a minute, so its log has one
  `GET /api/v1/info 401` line a minute.
- **Updates.** `git pull && docker compose up -d --build`. The Tailscale image is pinned by digest in
  `compose.yaml`; a newer one is a change to that line. The published image `ghcr.io/qantrex/homelab-bridge` (built
  by hand, see [RELEASE.md](RELEASE.md#homelab-bridge-image)) works too: `docker compose pull bridge && docker compose
  up -d`, and `BRIDGE_TAG=<version>` in `server/.env` pins a version.

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

With a `sources` list the reference server becomes the Homelab Bridge and also reads other services' APIs
([REFERENCE_SERVER.md → Sources](REFERENCE_SERVER.md#sources)). Keys go in env variables, never in the config.

| Type | Reads | Config keys | What the key needs |
|---|---|---|---|
| `docker` | One Docker host's containers: unhealthy, restarting, dead and crashed ones as problems | `url` (a socket proxy), `host`, `ignore`, `actions` | No key; a socket proxy that allows only `GET /containers` ([Docker](REFERENCE_SERVER.md#docker)) |
| `proxmox` | Nodes as hosts with 24 h history, VMs and containers as each node's container list | `url`, `token_id`, `key_env`, `ca_file`, `expect_running`, `actions` | An API token with `Sys.Audit` and `VM.Audit` (or PVEAuditor) ([Proxmox](REFERENCE_SERVER.md#proxmox)) |

Restart, start and stop are off until you list containers or VMIDs under `actions`
([Source actions](REFERENCE_SERVER.md#source-actions)).

### Sources

With a `sources` list the reference server is the Homelab Bridge: it reads other services' APIs and shows what
they report on Today and in Lab. Copy the `server/sources/` folder next to `reference_server.py`. The common keys
(`name`, `type`, `url`, `every`, `timeout`, `*_env`) are in [REFERENCE_SERVER.md → Sources](REFERENCE_SERVER.md#sources);
each module's docstring has the details.

| Type | What it reads | Keys | Access it needs | Tested with |
|---|---|---|---|---|
| `uptime-kuma` | The monitors of one status page: down = problem; pending, slow (`slow_ms`) and a certificate that expires within `cert_days` (14) = warning; a pinned "danger" or "warning" incident. A card "11 of 12 up" in Lab, links as services | `url`, `slug`; `slow_ms`, `cert_days`, `services` | None: the public status page JSON. Only the monitors on that page show | 2.5.9 and 1.23.16 |
| `gatus` | All endpoints: failing = problem; failing only on `[RESPONSE_TIME]`, `[CERTIFICATE_EXPIRATION]` or `[DOMAIN_EXPIRATION]`, or slower than `slow_ms` = warning. A card "11 of 12 up" in Lab | `url`; `slow_ms`; `user` with `password_env` | None, or the `security.basic` user (OIDC can't be used) | v5.38.0 |

```json
"sources": [
  {"name": "Kuma", "type": "uptime-kuma", "url": "http://192.0.2.10:3001", "slug": "home"},
  {"name": "Gatus", "type": "gatus", "url": "http://192.0.2.10:8080", "slow_ms": 2000}
]
```

The slug is the part after `/status/` in the status page's address. A status page only for the bridge is fine.
[`server/examples/sources-monitors.json`](../server/examples/sources-monitors.json) is a whole config with both.

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
