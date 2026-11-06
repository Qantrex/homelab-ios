# Security

Homelab is a remote control for your servers. This page says what it protects against, what it does, and what you
must do on the server side.

## Threat model

| Threat | What could happen | What limits it |
|---|---|---|
| Lost or stolen phone | Someone reads your homelab status, approves an action, or switches devices at home | The iPhone passcode. Optional Face ID lock in the app. Tokens are tied to this device (`ThisDeviceOnly`), so they don't move to another phone through a backup. Revoke tokens on the server or in HA, and remove the device from your tailnet |
| Malicious or broken data from a server | A card, problem, chat reply or action reason tries to run code, open another app or fake the UI; absurd numbers or a huge picture try to crash the app | Text is shown as plain text with inline Markdown only (no HTML, no images, no block elements). Links must be `http`/`https`; others are removed. The app never runs anything a server sends. Numbers are put into range when they are read; pictures come only from the server itself and are size-checked before they are decoded (see below) |
| A server you don't fully trust (a friend's homelab, a test box) | It learns things about you, or sends you to a phishing page | The app sends it only its own token (or nothing, with Tailscale identity). Tokens are per server, never shared. No cookies. A link from it opens in Safari, where you see the address |
| Network attacker (public Wi-Fi, a hostile LAN, a carrier network) | Reads or changes traffic, steals a token | `https://` for every address outside your home network or tailnet; plain `http://` is refused there. A token never goes over plain `http://` except to this device or a `.ts.net` name (see Plain http). Tailscale encrypts tailnet traffic end to end. No credential or cookie storage in the network layer |
| Shared tailnet (family, friends, a work tailnet) | Another person or device reaches your server | That is the server's job: allow only your login (`allowed_logins`) or use tokens. Tagged devices get no login header. Use Tailscale ACLs to limit who can reach the port |

Not in scope: a jailbroken phone, a compromised server (it can show you anything), and Apple or SideStore signing (but
see the Keychain caveat below).

## What the app does

| Area | How |
|---|---|
| Token storage | iOS Keychain, one item per server, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synced to iCloud. Readable after the first unlock so background refresh works. Keychain items outlive the app: when the app starts without a server list (first launch, or installed again after a delete) it deletes every token it finds |
| SideStore and the Keychain | The app declares no `keychain-access-groups`, so its tokens sit in its default group (`<TEAMID>.<bundle id>`). SideStore re-signs with your Apple ID's free profile; if it signs the app (or another app you sideload with the same Apple ID) with the profile's wildcard group `<TEAMID>.*`, those apps can read each other's Keychain items, Homelab's tokens included. Check it once (DeviceTest.md, D5). If you see the wildcard, prefer Tailscale identity over tokens, or sideload nothing else you don't trust with that Apple ID |
| Tokens elsewhere | Never in files, never in logs (a lint check in CI looks for token-ish values in log calls), never shown again after saving, never given to the widget or the share extension (they can't read the Keychain item) |
| Widget | Shows the selected server's last status from the App Group. For a Companion server reached by Tailscale identity (no token) it also fetches `GET /state` itself, at most every 5 minutes, with its own 8 s limit and answers up to 2 MB, no redirects, no cookies. It never fetches from a token server or Home Assistant |
| Deleting | Deleting a server deletes its token, its cached status and its cached pictures; a new address for a server drops its token and pictures too. Settings → Reset everything deletes all servers, tokens, cached data (pictures and outbox included) and settings |
| Cached data | In the App Group container (shared with the widget and the share extension), iOS file protection until first unlock, no tokens: the last status per server and the widget's copy (JSON), pictures per server (`images/<server>`, 30 days, 20 MB each), and the share outbox (see Scan and share) |
| Server text | Inline Markdown only, no HTML. Links from a server (services, host pages, card items, Markdown links) must be `http`/`https` with a host and no user name or password; everything else is dropped |
| Server numbers | Put into range when they are read, so nothing later can crash on them: temperatures outside -100…200 °C are dropped, load is clamped to 0…10000, RAM, disk and history percentages to 0…100, progress to 0…1, counts and minutes to ±10⁹, times past the year 5000 are dropped. NaN and infinity (also as `"nan"` or `"inf"` text) are dropped. Code turns a Double into an Int only through a clamping helper; a lint check in CI looks for bare conversions |
| Pictures | Poster pictures (`image` of a card item) come only from the server itself: a path, or an absolute URL with the server's scheme, host and port **under the server's base path**, so another service on the same host never gets the token. At most 1 MB, JPEG, PNG or WebP by their first bytes. The pixel size is read from the header before anything is cached; more than 4000×6000 (either way round) is refused, and posters are decoded as thumbnails at display size |
| Plain http | Without a token (Tailscale identity): only for local and tailnet addresses: private IPv4, `127.x`, `169.254.x`, `100.64–127.x` (Tailscale), `localhost`, `.local`, single-label names, local IPv6. Not `.lan`, `.home.arpa` or `.internal` (iOS blocks plain http there, so use https), and not a number written as one name (`134744072`, `0x08080808`) or with leading zeros (`010.8.8.8`): the resolver reads those as public IPv4 addresses. Shown with a warning in the editor. **With a token** (a token Companion server, Home Assistant): `https://` only, except `http://localhost`, `127.0.0.1`, `::1` and `*.ts.net` names (they resolve only inside the tailnet, so the traffic is WireGuard-encrypted). A raw `100.x` address is refused (without Tailscale it is carrier CGNAT), and so are LAN addresses, `.local` and single-label names: anyone on that network could read the token. The editor shows it as an error, and the app sends nothing to such a server ("This server uses a token over plain http. Use https (tailscale serve) or its .ts.net name.") |
| Network | An ephemeral `URLSession`: no cookies, no cache, no stored credentials. No `Origin` header. Short timeouts. User names or passwords in a URL are refused. Redirects are never followed (a token can't be carried to another host). Reading stops past a limit: Companion API answers 8 MB, Home Assistant 32 MB (`/api/states` of a big install), pictures 1 MB, the widget's answers 2 MB |
| Token targets | A saved token belongs to one server (kind + scheme + host + port + path). Editing the address or type drops it; the app asks for the token again |
| Copy | Copied chat text and the diagnostics report stay on this device (no Universal Clipboard) and expire after 10 minutes |
| Face ID lock | Optional, off by default. Asks for Face ID or the passcode when the app starts and when it comes back from the background. While locked, no screen exists behind the lock (open sheets and dialogs are closed), the app switcher shows a blur, notifications only say that something happened, and the widgets show the status without problem text and deadlines and to-dos as counts only (departure times stay: they are public). It is tested once before it is turned on, so you can't lock yourself out. It fails open: when the iPhone has no passcode at all (removed after the lock was turned on), the app opens without asking, because there is nothing to ask for. The lock protects the app only as well as the iPhone's passcode does |
| Live Activity | "Leave by" (on by default; Settings → Leave-by on the lock screen turns it off) shows the time to leave and the next departures ("Leave by 07:26 · U6 07:31") on the lock screen, in StandBy and as a banner, also while the app lock is on. It shows nothing from the server's status, problems or lists |
| Scan and share | The camera is used only in the Scan screen (VisionKit document camera; the system asks once). A PDF or link goes to the server's `POST /documents` or `POST /share` with the same login as everything else, only after you tap Send. The share extension holds no token (the Keychain is not shared with it): on an identity (Tailscale) server it sends directly, on a token server it saves the item in an outbox in the App Group and the app sends it. The outbox keeps at most 10 items and 100 MB, for 7 days, and its files use iOS file protection until first unlock. The extension only takes http(s) links (no `file:`, `javascript:`, user names or passwords), never plain text, and as a link's title only the shared item's title (never its content text, where some apps put the selected text or a whole note), PDFs up to 25 MB, at most 20 photos, which are shrunk to 2000 px one at a time. Servers must not hand uploaded files to a language model and must treat shared links as data (see below) |
| Actions | A card item's button (tick off, delivered, request, pause) sends exactly the argument the server gave the item; when it no longer fits the action the server lists (a changed or misspelled option), the app refuses ("This item's action no longer fits the server.") instead of sending the form's default. Approve, Always and Deny each need a confirm tap. The app only sends back the signed button string the server gave it; the server checks the signature and decides. Both servers in this project sign the action's content too, so an old button can't approve a new action that reuses the id. Forged, used, outdated or expired buttons get 403 |
| Notifications | Off by default. They contain the server name and the problem or action text, which shows on the lock screen, unless the app lock is on (then only "Something needs a look") |
| Diagnostics report | Has the app version, App Group, server kinds, host names and last errors. No tokens. Check it before you paste it in a public issue |
| Third parties | None. No analytics, no crash reporting, no third-party Swift packages |

## What server operators must do

For the reference server most of this is the default. For your own server, do the same.

- **Listen on loopback only** (`127.0.0.1`) and put `tailscale serve` in front. It adds HTTPS and the tailnet
  boundary.
- **Never use `tailscale funnel`** (or a public reverse proxy, or a port forward) for this API. Funnel puts it on the
  public internet.
- **Require auth on every request.** Trust the identity header only from `127.0.0.1`, and check the login against a
  list. Or use bearer tokens: 16+ random characters, one per device, compared in constant time, kept out of the config
  file (an environment file owned by root, mode 600).
- **Refuse browsers.** Answer 403 to requests with an `Origin` header, so a web page in the tailnet can't use your
  API.
- **Keep actions opt-in and narrow.** A whitelist of commands, strict argument checks, no shell, signed buttons that
  work once. Only trusted code may write proposals. See
  [REFERENCE_SERVER.md → Actions](REFERENCE_SERVER.md#actions-opt-in-dangerous).
- **Treat chat text as untrusted input.** It comes from anyone you let in.
- **Don't log secrets.** No tokens, no headers, no message text in the log.
- For Home Assistant: use a separate HA user for the phone, so you can revoke its token alone.

### If your server takes documents and shares

- Check `Content-Type: application/pdf`, `Content-Length`, the `%PDF-` start and the size before filing; keep a quota and a
  spool limit; make the id idempotent. Answer no CORS preflight: the raw PDF type then keeps websites out.
- Give the filing step its own account with only "add document" rights, not the one a read-only search uses.
- Never give an uploaded file, its text, or a shared link's page to an assistant with tools as a request. Shared links
  are untrusted data: build any request from the parts you checked (a willhaben ad id is digits only). Don't fetch
  shared links from inside your network (SSRF).

## Reporting a problem

Please don't open a public issue for a security bug. Use GitHub's private vulnerability reporting: the repository's
**Security** tab → **Report a vulnerability** (https://github.com/Qantrex/homelab-ios/security). Say what you found,
how to reproduce it, and which version (Settings → About, or Diagnostics).
