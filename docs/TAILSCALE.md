# Tailscale and HTTPS, for beginners

The app talks to your servers over **HTTPS**, and it only sends a password-like secret (a token) over HTTPS. This page
explains the easiest way to get there with Tailscale, and the other ways if you don't want it.

## What Tailscale is

[Tailscale](https://tailscale.com) is a VPN (a private network over the internet) that links your own devices: your
phone, your server, your Home Assistant. Each device gets a private name like `ha.tail1234.ts.net`, and only your
devices can reach it. Nothing is opened to the internet. Your network of devices is called your **tailnet**.

It is free for personal use (the free plan; check [tailscale.com/pricing](https://tailscale.com/pricing) for today's
limits). You sign in with an account you already have (Google, Microsoft or GitHub).

The app needs it switched on to reach your servers. The demo inside the app doesn't.

## 1. Install it

| Where | How |
|---|---|
| iPhone | App Store: "Tailscale", sign in, allow the VPN. More at [tailscale.com/download](https://tailscale.com/download) |
| Server, PC, NAS (Linux) | [tailscale.com/download/linux](https://tailscale.com/download/linux), then `sudo tailscale up` and open the link it prints |
| Docker | The Homelab Bridge brings its own Tailscale container: [GETTING-STARTED.md](GETTING-STARTED.md#b-homelab-bridge) |
| Home Assistant OS | The Tailscale add-on, see [below](#home-assistant-os) |

Sign in with the same account on every device.

## 2. Two switches in the admin console (once)

Open the [admin console](https://login.tailscale.com/admin/dns), page **DNS**:

1. Turn on **MagicDNS**. It gives every device its name (`machine.tail1234.ts.net`).
2. Under **HTTPS Certificates** click **Enable HTTPS**. It lets a device get a real certificate for its name. Tailscale
   publishes the names of such devices in a public log; if you don't want a name there, pick an unremarkable machine name.

## 3. Give a service HTTPS: `tailscale serve`

On the machine that runs the service, for example a service on port 8123 (Home Assistant):

```bash
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8123
tailscale serve status
```

The service is now at `https://<machine>.<tailnet>.ts.net:8443`, with a real certificate, for your devices only.
That address is what you type in the app. Don't use Funnel (`tailscale funnel`): it puts the service on the public
internet.

## Home Assistant OS

Home Assistant OS (the ready-made image on a Raspberry Pi or a mini PC) has no shell where you run commands. Use the
official Tailscale add-on from the [Home Assistant add-on store](https://github.com/hassio-addons/addon-tailscale)
(its [documentation](https://github.com/hassio-addons/addon-tailscale/blob/main/tailscale/DOCS.md) is the reference;
option names below are from it, 2026-11-08, not tried here by us):

1. Settings → Add-ons (newer versions: Apps) → Add-on store → **Tailscale** → Install → Start. Open its Web UI and
   sign in to link Home Assistant to your Tailscale account.
2. Do the two switches from step 2 above in the admin console.
3. In Home Assistant: Settings → System → Network → HTTP server. Turn off **SSL/TLS** there (Tailscale does the
   HTTPS). Under **Reverse proxy** turn on **Trust X-Forwarded-For** and add `127.0.0.1` to **Trusted proxies**. Restart
   Home Assistant.
4. In the add-on's Configuration, turn on the option **`share_homeassistant`** (Tailscale Serve: only your tailnet;
   leave Funnel alone). Set **`share_on_port`** to 443, 8443 or 10000 (default 443). Restart the add-on.
5. The address for the app is `https://<machine>.<tailnet>.ts.net` (no `:8123`; add `:8443` or `:10000` only if you
   changed the port).

Then in the app: Add Home Assistant, that address, a long-lived token
([GETTING-STARTED.md](GETTING-STARTED.md#a-only-home-assistant)).

## Other ways to get HTTPS

The app only needs an `https://` address with a certificate your iPhone trusts. Self-signed certificates don't work.

- **Nabu Casa** (Home Assistant Cloud, a paid subscription from the Home Assistant makers): Home Assistant gets an
  `https://….ui.nabu.casa` address that works from anywhere, with no Tailscale. The app's rules allow that address
  with a long-lived token (a token only goes over https), so it should work as it is; we haven't tried it. The
  traffic goes through their servers.
- **A reverse proxy with a real certificate** (Caddy, Nginx Proxy Manager or Traefik, with a domain of yours and, for
  example, Let's Encrypt). Home Assistant then needs `use_x_forwarded_for` and `trusted_proxies`
  ([GETTING-STARTED.md](GETTING-STARTED.md#a-only-home-assistant)), otherwise it answers HTTP 400. To keep it private,
  don't open the port to the internet: reach it over a VPN or your home network only.
- **Another VPN** (WireGuard and the like) works as long as the address is `https://` with a certificate the phone
  trusts. A server that uses no token can also use a plain `http://` address on a private network. The exact rules are
  in [SETUP.md](SETUP.md#launch-arguments) ("URL rules").
