# Connecting your homelab

The app talks to two kinds of server. You can add several of each in Settings → Add server.

| Type in the app | Speaks | Tabs it fills |
|---|---|---|
| Homelab API | The Homelab Companion API v1 ([`server/openapi.yaml`](../server/openapi.yaml)) | Overview, Actions, Chat, widgets |
| Home Assistant | Home Assistant's REST API | Home |

There are three ways to get a Homelab API server: (a) the reference server from this repo, (b) Home Assistant on its
own (Home tab only), (c) your own agent or script.

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

   Change at least `name`, `allowed_logins` (your Tailscale login, the e-mail shown in the Tailscale app), and
   `this_host.disks`. Set `"docker": false` unless the service user may run `docker ps`. Delete the example `hosts`,
   `checks` and `services` you don't have. A minimal config:

   ```json
   {
     "name": "homeserver",
     "trust_identity_header": "Tailscale-User-Login",
     "allowed_logins": ["you@example.com"],
     "this_host": {"kind": "server", "disks": ["/"], "updates": true},
     "hosts": [{"id": "gaming-pc", "name": "Gaming PC", "kind": "desktop", "check": "ping://gaming-pc", "sleeps": true}]
   }
   ```

   `"sleeps": true` shows a sleeping PC as "Asleep", not as a problem.

2. Run it with systemd. Copy the unit from [REFERENCE_SERVER.md → Run it with systemd](REFERENCE_SERVER.md#run-it-with-systemd)
   to `/etc/systemd/system/homelab-companion.service`, then:

   ```bash
   sudo useradd --system --home /var/lib/homelab-companion --shell /usr/sbin/nologin homelab-companion
   sudo systemctl daemon-reload && sudo systemctl enable --now homelab-companion
   journalctl -u homelab-companion -n 20
   ```

   The log should say `listening on http://127.0.0.1:8791`.

3. Publish it in your tailnet. Pick a free HTTPS port (`tailscale serve status` lists the used ones):

   ```bash
   sudo tailscale serve --bg --https=7443 http://127.0.0.1:8791
   ```

4. Test it from another tailnet device:

   ```bash
   curl https://<machine>.<tailnet>.ts.net:7443/api/v1/info
   ```

   You should see `{"api": 1, "name": "homeserver", ...}`. A 403 means your login is not in `allowed_logins`.

5. In the app: Add server → Type **Homelab API** → Address `https://<machine>.<tailnet>.ts.net:7443` → Login
   **Tailscale / proxy** → Test connection ("Connected to homeserver (2 features).") → Save.

Next steps, all optional: cards from your own scripts, a service launcher, actions and chat. See
[REFERENCE_SERVER.md](REFERENCE_SERVER.md). Actions and chat are off by default; read their safety notes first.

## (b) Home Assistant

The Home tab shows the devices you pin: lights, switches, fans, toggles, automations (tap to toggle), scripts,
scenes and buttons (tap **Run**), sensors and binary sensors (state only).

1. In Home Assistant: your profile → Security → **Long-lived access tokens** → Create token. Copy it; HA shows it
   only once. A separate HA user just for the phone makes it easy to revoke later.
2. In the app: Add server → Type **Home Assistant** → Address as you open HA in a browser, for example
   `https://ha.<tailnet>.ts.net` or `http://192.168.0.10:8123` → paste the token → Test connection ("Home Assistant
   answers.") → Save.
3. Open the Home tab → **Choose devices** → pick them → Done.

Notes:

- Plain `http://` only works for local and tailnet addresses (private IPs, `100.x`, `.local`, …), not for public
  names. See the URL rules in [SETUP.md](SETUP.md#launch-arguments).
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
| `GET /api/v1/state` | Overview, Actions list, widgets, notifications | `status`, `hosts`, `cards` |
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
- Times are ISO 8601. Without a time zone they mean the server's local time.
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
