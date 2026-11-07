# Installing with SideStore

> **Tested 2026-11-07** on an iPhone 12 mini (iOS 18.7.3) with SideStore 0.7.0 (nightly): Homelab installed, widgets
> and share sheet work. The sign-in first failed with error -80045; the fix is in
> [Sign-in error -80045](#sign-in-error--80045) below. There is no release yet: build the IPA yourself
> ([SETUP.md](SETUP.md)).

[SideStore](https://sidestore.io) installs apps on an iPhone with a free Apple ID, without a computer after the first
setup. It signs the app for you and refreshes it before it expires. Homelab needs nothing else: no paid developer
account, no TestFlight.

## 1. Install SideStore

Follow the official guide: <https://docs.sidestore.io>. In short, you need a computer once to install SideStore and
create its pairing file. After that, SideStore works on the phone alone.

You need iOS 18 or newer for Homelab.

## 2. Install Homelab

| Way | Steps |
|---|---|
| Add the source (gets updates) | SideStore → Sources → + → paste `https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json` → open the source → Homelab → install. |
| Import an IPA | Download `Homelab-<version>.ipa` from [GitHub Releases](https://github.com/Qantrex/homelab-ios/releases) (or build one, see [SETUP.md](SETUP.md)). In Files: Share → SideStore, or in SideStore: My Apps → + → pick the IPA |

The release IPA has a `.sha256` file next to it if you want to check the download. Releases are built by hand
from the owner's own build ([RELEASE.md](RELEASE.md)); each one carries `source.json`, which is why the source URL
above always points at the newest release.

Slots: a free Apple ID allows 3 active sideloaded apps, and SideStore is one of them. The Homelab widget and the
share extension don't take a slot, so SideStore + Homelab = 2 of 3. Each install also uses **3** of the 10 App IDs a
free account may create per week (app + widget + share extension). The U6, deadlines and to-do widgets and the
"Leave by" Live Activity all live in the existing widget extension, and the Live Activity needs no entitlement, so
there is **no fourth App ID**. Installing from Linux with `xtool dev` and
installing with SideStore each register their own set, so switching between the two in one week costs 3 more.

When SideStore asks about the app's extensions, either "Keep App Extensions" option works: "Use Main Profile" (1 App
ID) was tested with widgets on 2026-11-07; "Register App ID for Each Extension" uses 3.

## Sign-in error -80045

Since October 2026 Apple refuses sign-ins whose device data (from SideStore's "anisette" server) doesn't match.
SideStore then says "This action cannot be completed at this time. (-80045)". What fixed it on the test phone:

1. SideStore → Settings → User Customizations: turn off **On-Device Anisette**.
2. Settings → Anisette Servers: tick **SideStore (New)** (`new.ani.sidestore.io`) and turn off **Enable Auto
   Rotation** at the bottom. If it still fails later, try another server here (for example jkcoxson).
3. User Customizations → Anisette Client Configuration → Remote Server Sync: **Fetch** (it must show the server from
   step 2), then **Save as Overrides**.
4. User Customizations → **Reset adi.pb**.
5. Connect **LocalDevVPN**, then sign in with your Apple ID and its real password (an app-specific password doesn't
   work). Without the VPN the sign-in ends with "could not determine this device's UDID".
6. Confirm the code on a trusted Apple device (it may say "MacBook Pro": that's how SideStore signs in).

## 3. The 7-day refresh

Apps signed with a free Apple ID stop opening after 7 days. SideStore refreshes them in the background over Wi-Fi.
To be safe, open SideStore every few days, or tap My Apps → Refresh All. Homelab warns on Today 2 days before its
install stops opening, and Settings → Diagnostics → Install expires shows the date.

- SideStore needs its own VPN helper (LocalDevVPN) while it refreshes. iOS runs only one VPN at a time, so with
  Tailscale always on, background refresh never runs. A Shortcuts automation does it instead (Shortcuts →
  Automation → + → Time of Day, daily, Run Immediately), tested 2026-11-07:
  1. LocalDevVPN's own **Enable LocalDevVPN** action (the generic "Set VPN … Connect" did not start it in time)
  2. **Wait** 15 s
  3. **Open App** SideStore
  4. SideStore's **Refresh All Apps**, with "Show When Run" off (otherwise its "Done" dialog stops the shortcut)
  5. **Wait** 60 s
  6. Tailscale's own **Connect to your Tailscale network** action ("Set VPN Tailscale" did not reconnect), "Show
     When Run" off

  A second automation a few minutes later with only step 6 brings Tailscale back if a refresh ever fails (a failed
  action stops the shortcut before step 6).
- A refresh keeps everything: servers, tokens (Keychain), cached data and the widget. `DeviceTest.md` checks this.
- If the app expired anyway, it doesn't open. Refresh it in SideStore; the data is still there.
- Deleting the app, or installing it with a different Apple ID, starts from zero.

## App Group: why the widget and the share extension work after SideStore

App and widget share data through an App Group. The app declares `group.com.qantrex.homelab`. SideStore signs with
your Apple ID's team, so it changes the IDs:

| | Declared | After SideStore (example) |
|---|---|---|
| App bundle ID | `com.qantrex.homelab` | `com.qantrex.homelab.ABCDE12345` |
| Widget bundle ID | `com.qantrex.homelab.HomelabWidget` | `com.qantrex.homelab.ABCDE12345.HomelabWidget` |
| Share extension bundle ID | `com.qantrex.homelab.HomelabShare` | `com.qantrex.homelab.ABCDE12345.HomelabShare` |
| App Group | `group.com.qantrex.homelab` | a renamed group, for example `group.com.qantrex.homelab.ABCDE12345` |

So the app never hard-codes the group. At start, app and widget each try, in order: the groups in their provisioning
profile, the declared group with the team ID added, then the declared group. They use the first one that exists and
is writable.

**Settings → Diagnostics → Shared storage** shows the group in use and each candidate (`ok`, `read-only` or `–`).
If it says "none (widget can't see data)", the app still works, but the widgets say "No App Group: see Diagnostics".
Installed with xtool 1.24.0 or older from Linux, that is an xtool bug (SETUP.md, "Known xtool bug: no App Group");
after SideStore, copy the report (Diagnostics → Copy report: host names with the tailnet part masked, no tokens)
and open an issue.

## Troubleshooting

| You see | Likely cause | Fix |
|---|---|---|
| Widget shows "Open the app" or "Open Homelab to load your machines." | The app has no data yet | Open the app and pull down on Today |
| Widget shows "No App Group: see Diagnostics" | No App Group was granted: Settings → Diagnostics → App Group is "none" | Installed with xtool 1.24.0 or older: update xtool and install again (SETUP.md, "Known xtool bug: no App Group"). After SideStore: reinstall through SideStore and send the report |
| Widget is grey with a clock and its age, or says "Data from … open the app" | The last data is more than 2 hours old. Widgets fetch `/state` themselves only for a Homelab API server with the Tailscale login (when the data is older than 5 minutes; Diagnostics → At a glance → Widget fetch shows the last try). For a token server or with Tailscale off they show only what the app saved | Turn Tailscale on, or open the app. Background refresh also updates it when iOS allows |
| "Can't reach `<host>`. Is Tailscale (or your VPN) on?" | Tailscale is off (often after a SideStore refresh), the server is down, or `tailscale serve` doesn't serve that port | Turn Tailscale on. On the server: `tailscale serve status` and `curl https://<machine>.<tailnet>.ts.net:<port>/api/v1/info` from another tailnet device |
| "Can't find `<host>`. Check the address." | Typo, or MagicDNS is off (a `.ts.net` name that can't be found says "Can't reach … Is Tailscale on?" instead, the row above) | Check the name in the Tailscale app, and that MagicDNS is on (Tailscale app → Settings, and the admin console → DNS). The `100.x` address won't work with `tailscale serve`: its certificate is for the `.ts.net` name |
| "The server refused access. Is this login or token allowed?" (HTTP 403) | Your Tailscale login is not in the server's `allowed_logins`, the token is wrong, or the device is tagged (tagged devices get no login header) | Add the login on the server, or switch Login to **Token** and enter a token the server knows |
| "No login reached the server. … With a token: check it in Settings." (HTTP 401) | Login is **Tailscale / proxy**, but the request didn't come through `tailscale serve`, or the server only takes tokens | Put the server behind `tailscale serve`, or use **Token** |
| "This button is no longer valid (already handled or expired)." | The action was already approved or denied, or the server restarted with a new button secret | Pull to refresh. Set `HOMELAB_BUTTON_SECRET` on the reference server so buttons survive restarts |
| "Enter the token first." when saving | Login is **Token** (or the server is Home Assistant) and no token is saved | Paste the token |
| Home Assistant: "No login reached the server. …" | The long-lived token is wrong or was deleted in HA | Create a new one: HA profile → Security → Long-lived access tokens, then edit the server and paste it |
| Home Assistant: "The server rejected the request." (HTTP 400) | HA is behind a reverse proxy that sends `X-Forwarded-For`, but HA's `http:` config doesn't trust it | Set `use_x_forwarded_for: true` and `trusted_proxies` in HA's `http:` block, or use HA's direct address |
| "The server's answer couldn't be read. Is it a Homelab API server?" | The address points at a web page, not the API | Use the server's base address (the app adds `/api/v1` itself) |
| "The secure connection failed (certificate?)." | Self-signed or expired certificate | Use `tailscale serve` (real certificates), or plain `http://` on a local address (Tailscale login only: a token needs https) |
| "This server uses a token over plain http. Use its https://….ts.net address (tailscale serve)." | A token server or Home Assistant at `http://` on anything but this device (`localhost`, `127.0.0.1`, `::1`): a LAN IP, `.local`, a single name, a raw `100.x` address or a `.ts.net` name. The app sends nothing there: anyone on that network could read the token (a `.ts.net` name is only safe while Tailscale is on) | Put it behind `tailscale serve` and use `https://<machine>.<tailnet>.ts.net[:port]`, or switch the server to Login Tailscale |
| "http:// is only allowed for private addresses (home network, 100.x). Use https://, also for .ts.net names." | Plain http to a public name, or to a `.ts.net` name | Use `https://`. `tailscale serve` gives HTTPS for free |
| Diagnostics → Background → Last run "never" | iOS hasn't run it yet. It learns from how often you open the app | Use the phone normally for a day. Low Power Mode and turning off Background App Refresh (iOS Settings → General) stop it |
| The app doesn't open | It expired (7 days; Today warns 2 days before) | Installed with xtool: plug the phone in and install again (`scripts/install-dev`), your data stays. With SideStore: My Apps → Refresh All |
