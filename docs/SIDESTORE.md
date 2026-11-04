# Installing with SideStore

[SideStore](https://sidestore.io) installs apps on an iPhone with a free Apple ID, without a computer after the first
setup. It signs the app for you and refreshes it before it expires. Homelab needs nothing else: no paid developer
account, no TestFlight.

## 1. Install SideStore

Follow the official guide: https://docs.sidestore.io. In short, you need a computer once to install SideStore and
create its pairing file. After that, SideStore works on the phone alone.

You need iOS 18 or newer for Homelab.

## 2. Install Homelab

| Way | Steps |
|---|---|
| Add the source (gets updates) | SideStore → Sources → + → paste `https://qantrex.github.io/homelab-ios/source.json` → open the source → Homelab → install. Or open https://qantrex.github.io/homelab-ios/ on the phone and tap **Add to SideStore** |
| Import an IPA | Download `Homelab-<version>.ipa` from [GitHub Releases](https://github.com/Qantrex/homelab-ios/releases) (or build one, see [SETUP.md](SETUP.md)). In Files: Share → SideStore, or in SideStore: My Apps → + → pick the IPA |

The release IPA has a `.sha256` file next to it if you want to check the download. Each release also carries
`source.json`, so `https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json` works as the source
URL too, if the Pages site is down.

Slots: a free Apple ID allows 3 active sideloaded apps, and SideStore is one of them. The Homelab widget doesn't take
a slot, so SideStore + Homelab = 2 of 3. Each install also uses 2 of the 10 App IDs a free account may create per
week (app + widget).

## 3. The 7-day refresh

Apps signed with a free Apple ID stop opening after 7 days. SideStore refreshes them in the background over Wi-Fi.
To be safe, open SideStore every few days, or tap My Apps → Refresh All.

- SideStore needs its own VPN helper while it refreshes (see the SideStore docs). iOS runs only one VPN at a time, so
  turn Tailscale back on afterwards, or Homelab can't reach your servers.
- A refresh keeps everything: servers, tokens (Keychain), cached data and the widget. `DeviceTest.md` checks this.
- If the app expired anyway, it doesn't open. Refresh it in SideStore; the data is still there.
- Deleting the app, or installing it with a different Apple ID, starts from zero.

## App Group: why the widget works after SideStore

App and widget share data through an App Group. The app declares `group.com.qantrex.homelab`. SideStore signs with
your Apple ID's team, so it changes the IDs:

| | Declared | After SideStore (example) |
|---|---|---|
| App bundle ID | `com.qantrex.homelab` | `com.qantrex.homelab.ABCDE12345` |
| Widget bundle ID | `com.qantrex.homelab.HomelabWidget` | `com.qantrex.homelab.ABCDE12345.HomelabWidget` |
| App Group | `group.com.qantrex.homelab` | a renamed group, for example `group.com.qantrex.homelab.ABCDE12345` |

So the app never hard-codes the group. At start, app and widget each try, in order: the groups in their provisioning
profile, the declared group with the team ID added, then the declared group. They use the first one that exists and
is writable.

**Settings → Diagnostics → Shared storage** shows the group in use and each candidate (`ok`, `read-only` or `–`).
If it says "none (widget can't see data)", the app still works, but the widget shows "Open the app". Copy the report
(Diagnostics → Copy report) and open an issue.

## Troubleshooting

| You see | Likely cause | Fix |
|---|---|---|
| Widget shows "Open the app" or "Open Homelab to load your hosts." | The app has no data yet, or no App Group was found | Open the app and pull down on Overview. Then check Settings → Diagnostics → App Group. If it is "none", reinstall through SideStore and send the report |
| Widget shows "Data is old" and a grey status | The last data is more than 10 minutes old. Widgets never fetch by themselves | Open the app. With notifications on, background refresh also updates it when iOS allows |
| "Can't reach `<host>`. Is Tailscale (or your VPN) on?" | Tailscale is off (often after a SideStore refresh), the server is down, or `tailscale serve` doesn't serve that port | Turn Tailscale on. On the server: `tailscale serve status` and `curl https://<machine>.<tailnet>.ts.net:<port>/api/v1/info` from another tailnet device |
| "Can't find `<host>`. Check the address." | Typo, or MagicDNS is off | Check the name in the Tailscale app. Try the `100.x` address |
| "The server refused access. Is this login or token allowed?" (HTTP 403) | Your Tailscale login is not in the server's `allowed_logins`, the token is wrong, or the device is tagged (tagged devices get no login header) | Add the login on the server, or switch Login to **Token** and enter a token the server knows |
| "The server wants a login or token. Check the token in Settings." (HTTP 401) | Login is **Tailscale / proxy**, but the request didn't come through `tailscale serve`, or the server only takes tokens | Put the server behind `tailscale serve`, or use **Token** |
| "This button is no longer valid (already handled or expired)." | The action was already approved or denied, or the server restarted with a new button secret | Pull to refresh. Set `HOMELAB_BUTTON_SECRET` on the reference server so buttons survive restarts |
| "Enter the token first." when saving | Login is **Token** (or the server is Home Assistant) and no token is saved | Paste the token |
| Home Assistant: "The server wants a login or token" | The long-lived token is wrong or was deleted in HA | Create a new one: HA profile → Security → Long-lived access tokens, then edit the server and paste it |
| Home Assistant: "The server rejected the request." (HTTP 400) | HA is behind a reverse proxy that sends `X-Forwarded-For`, but HA's `http:` config doesn't trust it | Set `use_x_forwarded_for: true` and `trusted_proxies` in HA's `http:` block, or use HA's direct address |
| "The server's answer couldn't be read. Is it a Homelab API server?" | The address points at a web page, not the API | Use the server's base address (the app adds `/api/v1` itself) |
| "The secure connection failed (certificate?)." | Self-signed or expired certificate | Use `tailscale serve` (real certificates), or plain `http://` on a local address |
| "http:// is only allowed for addresses in your home network or tailnet." | Plain http to a public name, or to a `.ts.net` name | Use `https://`. `tailscale serve` gives HTTPS for free |
| Diagnostics → Background → Last run "never" | Notifications are off (background refresh only runs with them on), or iOS hasn't run it yet | Turn on a notification toggle in Settings and use the phone normally for a day. iOS decides when it runs |
| The app doesn't open | It expired (7 days) | SideStore → My Apps → Refresh All |
