# Getting started

From nothing to a working app, on your own homelab. You need no AI agent and no paid Apple account. The examples use
the made-up tailnet `tail1234.ts.net`; use yours.

## 1. Pick a setup

| You run | Setup | Today then shows |
|---|---|---|
| Home Assistant, nothing else you want to see | [A. Only Home Assistant](#a-only-home-assistant) | "Home." with what is on and what doesn't answer, and your Home tiles. No Lab, no widgets with data |
| Services like Uptime Kuma or Gatus, a Linux box with Docker | [B. Homelab Bridge](#b-homelab-bridge) | "All quiet." or "1 problem.", problems from your services, Lab with your machines and cards, widgets |
| Your own agent or scripts | [C. Your own server](#c-your-own-server) | What your server sends: from a status line up to actions and chat |

You can combine B or C with A: the app shows one Homelab server ("Show data from") and one Home Assistant ("Home
tiles from") at a time.

Not sure? Install the app and tap **Try the demo** on the first screen. It needs no server.

## 2. What you need

- An iPhone with iOS 18 or newer.
- [Tailscale](https://tailscale.com) on the phone and on the server (another VPN to your home works too; the steps
  here use Tailscale). In the Tailscale admin console → DNS, turn on **MagicDNS** and **HTTPS Certificates** once.
- A free Apple ID and one way to install:

| You have | Guide |
|---|---|
| A Linux PC and a USB cable | [INSTALL-FROM-LINUX.md](INSTALL-FROM-LINUX.md) |
| A Mac | [SETUP.md](SETUP.md) (the same xtool steps) |
| SideStore on the phone | [SIDESTORE.md](SIDESTORE.md) |

There is no release yet, so for now you build the app yourself (`xtool dev`; the first build takes a few minutes).

## A. Only Home Assistant

1. Make Home Assistant reachable over HTTPS in your tailnet. The app never sends a token over plain `http://`. On
   the machine that runs HA, with Tailscale on it:

   ```bash
   sudo tailscale serve --bg --https=8443 http://127.0.0.1:8123
   ```

   HA then sees requests from a proxy. Tell it to trust it, in `configuration.yaml`, and restart HA:

   ```yaml
   http:
     use_x_forwarded_for: true
     trusted_proxies:
       - 127.0.0.1
       - ::1
   ```

   Home Assistant OS: the Tailscale add-on can serve HA over HTTPS too (see the add-on's docs), or use HA's own TLS.
2. In HA: your profile → Security → **Long-lived access tokens** → Create token. Copy it; HA shows it only once. A
   separate HA user for the phone makes it easy to revoke.
3. In the app: **Add Home Assistant** → Address `https://ha.tail1234.ts.net:8443` → paste the token → **Save**.
4. "Found" lists your devices in words ("12 lights, 4 switches and 3 scenes"). **Home** is checked → **Start**.
5. The tile picker opens: tap the lights, scenes or scripts you use most → **Done**.

What you see: Today's headline is "Home." with what is true under it ("1 light on", "Front door open"). A device that
doesn't answer shows in gold ("Bedroom fan unavailable"). Your tiles are below; a tap switches them. The tabs are
Today and Settings. CI takes this as shot 29, `demo-ha-only` ([CI.md → Screenshots](CI.md#screenshots)).

Limits of this setup: no Lab, and the widgets stay empty (they read a Homelab server). For those, add B.

## B. Homelab Bridge

The Homelab Bridge is the [reference server](REFERENCE_SERVER.md) from this repo with `sources`: it reads the APIs of
your services and shows what they report. It runs in Docker next to a Tailscale sidecar, which is its own machine in
your tailnet (`homelab-bridge`). No port opens on your Docker host.

| Service | Source type | State |
|---|---|---|
| Uptime Kuma (a status page) | `uptime-kuma` | Works |
| Gatus | `gatus` | Works |
| Anything that answers JSON in the shape of `/state` | `json` | Works |
| Docker, Proxmox | `docker`, `proxmox` | Coming (plan M1.5) |
| Pi-hole, AdGuard Home, Sonarr, Radarr, qBittorrent | `pihole`, `adguard`, `sonarr`, `radarr`, `qbittorrent` | Coming (plan M1.6) |
| A Homepage `services.yaml` | import | Coming (plan M1.8) |

Details per source: [SERVER-SETUP.md → Sources](SERVER-SETUP.md#sources). Without Docker, the same server runs as
one Python file with systemd ([SERVER-SETUP.md → the 5-minute path](SERVER-SETUP.md#the-5-minute-path-debian-or-ubuntu-behind-tailscale-serve)).

You need Docker with Compose 2.17 or newer on Linux.

1. Get the files and make your copies (they stay out of git):

   ```bash
   git clone https://github.com/Qantrex/homelab-ios
   cd homelab-ios/server
   cp docker/config.example.json docker/config.json
   cp docker/bridge.env.example docker/bridge.env
   cp docker/tailscale.env.example docker/tailscale.env
   chmod 600 docker/bridge.env docker/tailscale.env
   ```

2. In `docker/config.json`: put your Tailscale login in `allowed_logins` (the e-mail, or `name@github`), and your
   services in `sources`. Use the LAN address of a service, not `127.0.0.1` (that is the container):

   ```json
   "sources": [
     {"name": "Kuma", "type": "uptime-kuma", "url": "http://192.0.2.10:3001", "slug": "home"},
     {"name": "Gatus", "type": "gatus", "url": "http://192.0.2.10:8080"}
   ]
   ```

   A source that needs a key names an env variable (`"key_env": "KUMA_KEY"`); the key goes in `docker/bridge.env`.
3. In the Tailscale admin console: Settings → Keys → **Generate auth key** (not reusable, not ephemeral). Put it in
   `docker/tailscale.env` as `TS_AUTHKEY=...`.
4. Start it and check it:

   ```bash
   docker compose up -d --build     # builds the image from this checkout
   docker compose ps                # both "healthy" after a minute
   curl https://homelab-bridge.tail1234.ts.net/api/v1/info   # from another tailnet device
   ```

   `{"api": 1, "name": "Homelab Bridge", ...}` means it works. A 403 means your login is not in `allowed_logins`
   (`docker compose logs bridge` shows the refused one).
5. In the app: **Add a Homelab server** → Address `https://homelab-bridge.tail1234.ts.net` → Login **Tailscale /
   proxy** → **Save**. "Found" lists what it offers; **Watch** is checked → **Start**.

What you see: Today says "All quiet." or "1 problem."; a down monitor is a problem ("Jellyfin: down"). Lab
shows the bridge as a machine, a card per monitor source ("11 of 12 up") and monitors with a public link in the
launcher. The status and
hosts widgets work, also with the app closed. Actions and Chat stay hidden: they are off on the bridge. Screenshots of
Today and Lab from the demo: [Today](https://github.com/Qantrex/homelab-ios/blob/main/docs/screenshots/01-today.png),
[Lab](https://github.com/Qantrex/homelab-ios/blob/main/docs/screenshots/04-lab.png) (the demo has more than a new
bridge).

More: other machines (`hosts`), web checks, cards from your own scripts, the socket proxy for containers, updates:
[SERVER-SETUP.md → Docker](SERVER-SETUP.md#docker) and [REFERENCE_SERVER.md](REFERENCE_SERVER.md). **Never use
Tailscale Funnel** for the bridge: it puts it on the public internet.

## C. Your own server

Anything that answers two JSON endpoints works: `GET /api/v1/info` and `GET /api/v1/state`. Add more endpoints when
you want actions, chat or a launcher.

1. Read [API.md](API.md) (the API in plain words) or [`server/openapi.yaml`](../server/openapi.yaml) (the contract).
   [SERVER-SETUP.md → Your own server](SERVER-SETUP.md#c-your-own-server) has a short Python server to start from.
2. Listen on `127.0.0.1` only and put `tailscale serve` in front (it adds HTTPS and your login), or check a bearer
   token.
3. Check it with the same test the owner's server passes (read-only, bash and python3):

   ```bash
   scripts/check-live-api https://nas.tail1234.ts.net:7444
   ```

4. In the app: **Add a Homelab server** → your address → Login **Tailscale / proxy** or **Token** → **Save**.

What you see depends on `features` in `/info`: `status` and `hosts` give Today and Lab; `actions` adds the Actions
tab, `chat` the Chat tab, `cards` the cards. A feature you leave out is a tab or section the app doesn't show. To
change the app itself: [ADAPTING.md](ADAPTING.md).

## Limits

| Limit | Why, and what to do |
|---|---|
| The app stops opening after 7 days | A free Apple ID signs for 7 days. Today warns 2 days before. Install again over USB (your data stays), or let SideStore refresh it |
| 3 sideloaded apps, 10 new App IDs a week | Free Apple ID. Homelab is one app; each install uses 3 App IDs (app, widget, share extension) |
| No push notifications, no Siri actions, no buttons in widgets | They need a paid account or App Intents. The app checks in the background when iOS lets it and sends a local notification |
| Tailscale must be on | The app reaches your servers only through your tailnet (or VPN). After a SideStore refresh, check that Tailscale is on again |
| Tokens only over HTTPS | A Home Assistant or token server at `http://` gets nothing. `tailscale serve` gives HTTPS with a real certificate |
| Tagged Tailscale devices | They get no login header. Use a token (`HOMELAB_TOKENS`) and Login **Token** |
| One Homelab server and one Home Assistant at a time | Settings → "Show data from" and "Home tiles from" pick them. The bridge merges your services into one |

## Troubleshooting

| You see | Fix |
|---|---|
| "Can't reach `<host>`. Is Tailscale (or your VPN) on?" | Turn Tailscale on. On the server: `tailscale serve status`, and the `curl` above from another tailnet device |
| "The server refused access. …" (403) | Your login is not in `allowed_logins`. The server log shows the refused login |
| "No login reached the server. …" (401) | The request didn't come through `tailscale serve`, or the Home Assistant token is wrong |
| Home Assistant: "The server rejected the request." (400) | HA doesn't trust the proxy: `use_x_forwarded_for` and `trusted_proxies` as in A, step 1 |
| "This server uses a token over plain http. …" | Use the `https://….ts.net` address from `tailscale serve` |
| "The server's answer couldn't be read. …" | The address points at a web page. Use the base address; the app adds `/api/v1` |
| A source shows as one warning, for example "Kuma: 401" | Its key, URL or slug is wrong, or the service is down. `docker compose logs bridge` and `/api/v1/info` (`sources`) say which |
| The widgets stay empty | Open the app once. With only Home Assistant they have nothing to show (see A) |
| The app doesn't open | It expired after 7 days: install it again |

Every message the app shows, with its fix: [SIDESTORE.md → Troubleshooting](SIDESTORE.md#troubleshooting). In the
app, Settings → Diagnostics → **Copy report** gives a report without tokens to paste into an issue.
