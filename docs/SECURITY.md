# Security

Homelab is a remote control for your servers. This page says what it protects against, what it does, and what you
must do on the server side.

## Threat model

| Threat | What could happen | What limits it |
|---|---|---|
| Lost or stolen phone | Someone reads your homelab status, approves an action, or switches devices at home | The iPhone passcode. Optional Face ID lock in the app. Tokens are tied to this device (`ThisDeviceOnly`), so they don't move to another phone through a backup. Revoke tokens on the server or in HA, and remove the device from your tailnet |
| Malicious or broken text from a server | A card, problem, chat reply or action reason tries to run code, open another app or fake the UI | Text is shown as plain text with inline Markdown only (no HTML, no images, no block elements). Links must be `http`/`https`; others are removed. The app never runs anything a server sends |
| A server you don't fully trust (a friend's homelab, a test box) | It learns things about you, or sends you to a phishing page | The app sends it only its own token (or nothing, with Tailscale identity). Tokens are per server, never shared. No cookies. A link from it opens in Safari, where you see the address |
| Network attacker (public Wi-Fi, a hostile LAN) | Reads or changes traffic, steals a token | `https://` for every address outside your home network or tailnet; plain `http://` is refused there. Tailscale encrypts tailnet traffic end to end. No credential or cookie storage in the network layer |
| Shared tailnet (family, friends, a work tailnet) | Another person or device reaches your server | That is the server's job: allow only your login (`allowed_logins`) or use tokens. Tagged devices get no login header. Use Tailscale ACLs to limit who can reach the port |

Not in scope: a jailbroken phone, a compromised server (it can show you anything), and Apple or SideStore signing.

## What the app does

| Area | How |
|---|---|
| Token storage | iOS Keychain, one item per server, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synced to iCloud. Readable after the first unlock so background refresh works |
| Tokens elsewhere | Never in files, never in logs (a lint check in CI looks for token-ish values in log calls), never shown again after saving, never given to the widget. The widget can't read the Keychain item and never talks to the network |
| Deleting | Deleting a server deletes its token. Settings → Reset everything deletes all servers, tokens, cached data and settings |
| Cached data | The last status per server, as JSON files in the App Group container (iOS file protection: until first unlock). No tokens in them |
| Server text | Inline Markdown only, no HTML. Links from a server (services, host pages, card items, Markdown links) must be `http`/`https` with a host and no user name or password; everything else is dropped |
| Plain http | Only for local and tailnet addresses: private IPv4, `127.x`, `169.254.x`, `100.64–127.x` (Tailscale), `localhost`, `.local`, `.lan`, `.home.arpa`, `.internal`, single-label names, local IPv6. Shown with a warning in the editor |
| Network | An ephemeral `URLSession`: no cookies, no cache, no stored credentials. No `Origin` header. Short timeouts. User names or passwords in a URL are refused |
| Face ID lock | Optional, off by default. Asks for Face ID or the passcode when the app starts and when it comes back from the background. It is tested once before it is turned on, so you can't lock yourself out |
| Actions | Approve, Always and Deny each need a confirm tap. The app only sends back the signed button string the server gave it; the server checks the signature and decides. Forged, used or expired buttons get 403 |
| Notifications | Off by default. They contain the server name and the problem or action text, which shows on the lock screen. Turn off previews in iOS Settings if that matters |
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

## Reporting a problem

Please don't open a public issue for a security bug. Use GitHub's private vulnerability reporting: the repository's
**Security** tab → **Report a vulnerability** (https://github.com/Qantrex/homelab-ios/security). Say what you found,
how to reproduce it, and which version (Settings → About, or Diagnostics).
