# Device test: Homelab 1.0.0

The checks that only a real iPhone can do. Use the release IPA or the SideStore source, Tailscale on, and a real
server (the agent, or the reference server). Mark each row ✅ / ⚠️ / ❌ and add a note. Every ⚠️/❌ gets fixed or
decided before the release.

Date: ____  iPhone model: ____  iOS version: ____  App version (Settings → Diagnostics): ____

## Install

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| I1 | Add the source in SideStore | (after the first release) Sources → + → `https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json` shows "Homelab iOS" with the Homelab app | | |
| I2 | Install from the source | Installs without an error. SideStore → My Apps shows Homelab, active apps 2 of 3 | | |
| I3 | Icon and name | Home screen shows the Homelab icon (sharp, no white border) and the name "Homelab" | | |

## First start

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| F1 | Welcome screen | "Your homelab, in your pocket", a short text, four points, **Add a server**, **Try the demo** and a link to the server setup. No tabs yet | | |
| F2 | Try the demo | Overview with demo hosts and problems. Tabs: Overview, Actions (with badge), Chat, Home, Settings | | |
| F3 | Demo is alive | Demo chat answers a message. A demo toggle in Home flips. A demo Approve shows an answer | | |
| F4 | Demo off | Settings → Demo servers off → back to the welcome screen (when no own server exists) | | |

## Real server

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| R1 | Add server | Type Homelab API, address `https://<machine>.<tailnet>.ts.net[:port]`, Login Tailscale / proxy. Save works | | |
| R1b | Token stays with its server | Edit a token server and change only its address: the token field asks for a token again ("The address or type changed…"). Renaming keeps the token | | |
| R2 | Test connection | Green "Connected to `<name>`: status, hosts and …" (the features in words), and the name field fills in when empty | | |
| R3 | Bad address | `ftp://x` or `http://example.com` shows red text under the field, Save is greyed out | | |
| R4 | Tailscale off | Turn Tailscale off, pull to refresh: "Can't reach `<host>`. Is Tailscale (or your VPN) on?" with Retry. No crash. Turn it back on: Retry loads the data | | |
| R6 | Wrong login | With a token server: a wrong token gives "The server refused access…" or "The server wants a login or token…", not a crash | | |

## Overview

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| O1 | Status header | "All good" or "N problems", "checked … ago", and "N actions waiting" when there are any | | |
| O2 | Problems | Listed first, with icon and "since …" | | |
| O3 | Hosts | One tile per host, "x/y up" in the title, load/RAM/disk bars, a sleeping PC shows "Asleep", not red | | |
| O4 | Host detail | Tap a tile: Status, System, Disks, Maintenance, Flags as the host has them. "Open web interface" opens Safari | | |
| O5 | Cards | Server cards show (title, icon, items or text). A card item with a link opens Safari | | |
| O6 | Services | Service buttons are grouped and open the right page in Safari | | |
| O7 | Pull to refresh | Pull down: spinner, then "checked just now" | | |
| O9 | Offline banner with age | Tailscale off, wait 10+ min, open the app: orange banner with "Showing data from … ago", old data still visible | | |
| O10 | Actions shortcut | "N actions are waiting for you" jumps to the Actions tab | | |

## Actions

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| A1 | List and badge | Tab badge = number of pending actions. Each row: title, reason, job and id chips, age | | |
| A2 | Approve | Approve → dialog "Run once" → "Running…" → alert with the server's result text. The row goes away | | |
| A3 | Always | Always → "Run and always allow" with the explanation → result text. Only shown when the server offers it | | |
| A4 | Deny | Deny → red "Deny", "Drops the proposal. Nothing runs." → result text. Nothing ran on the server | | |
| A6 | Already handled | Approve the same action on another device (or web), then tap it here: "Didn't work" / "This button is no longer valid (already handled or expired)." | | |
| A7 | Nothing pending | "Nothing to approve" placeholder | | |

## Chat

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| C1 | Send | The message shows at once ("Sending…", then "Sent"), the reply arrives | | |
| C2 | Working… | "Working…" with a spinner while the agent runs, gone when the reply is in | | |
| C3 | Report chips | Scheduled reports (`morning`, `watchdog`, …) have a coloured chip with a clock | | |
| C4 | Copy | Long-press a bubble → Copy → paste in Notes gives the full text | | |
| C5 | Quick commands | With the agent: `/pending`, `/last`, `/memory`, `/usage`, `/autonomy`, `/help` each send and get an answer. A server without `commands` in /info shows no button row | | |
| C6 | Long text limit | Paste 4100 characters: a counter shows, red above 4000, the send button is greyed out | | |
| C7 | Send while offline | Tailscale off, send: "Not sent: … Tap to edit." Tap puts the text back in the field | | |
| C8 | No duplicates | Leave the app for a minute, come back: no message shows twice | | |

## Home (Home Assistant)

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| H1 | Add HA | Type Home Assistant, address, long-lived token → Test connection "Home Assistant answers." → Save. Home tab appears | | |
| H2 | Pin devices | Choose devices → search works → pick a light, a switch, a script, a sensor → Done. Grouped as Lights, Switches, Scripts, Sensors | | |
| H3 | Toggle | Toggle a light: it changes in the room and the switch shows the real state after a moment | | |
| H4 | Run script | Run on a script or scene: it runs in HA | | |
| H5 | Unavailable | An unavailable device shows "Unavailable" (sensor) or a greyed-out toggle, no crash | | |
| H6 | Wrong token | Edit HA, paste a wrong token: a clear error text on the Home tab, no crash. Put the right one back | | |

## Widgets

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| W1 | Small | Long-press home screen → + → Homelab → "Homelab status": status icon, server name, first problem or "x/y hosts up", age, pending badge | | |
| W2 | Medium | "Homelab hosts" medium: 4 hosts with load, RAM and disk bar | | |
| W3 | Large | Large: up to 8 hosts and up to 4 problems | | |
| W4 | Lock screen | Circular, rectangular and inline widgets show status (and pending count) | | |
| W5 | Tap opens the right tab | Small with pending actions → Actions. Small without, medium, large, rectangular → Overview | | |
| W6 | Stale data marked | Tailscale off, wait 15+ min: "Data is old" and a grey question mark, not a green check | | |

## Background and notifications

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| B1 | Off by default | Settings → Notifications: both toggles off on a fresh install | | |
| B2 | Permission prompt | Turn on "New problems": iOS asks once. Deny → the note "Notifications are off for Homelab…" and the toggle stays off | | |
| B3 | Background runs | After a day of normal use: Diagnostics → Background → Last run has a time and Result starts with "ok" | | |
| B4 | One notification per new problem | Make a problem (stop a checked service): one notification "`<server>`: problem" within the next runs | | |
| B5 | No repeats | The same problem never notifies again while it lasts | | |
| B6 | New action | A new pending action gives "`<server>`: approve …?". Tapping it opens Actions | | |

## Face ID lock

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| L1 | Turn on | Settings → Lock with Face ID: Face ID is asked first, then the toggle is on | | |
| L2 | Locks | Leave the app, come back: "Homelab is locked", Face ID unlocks | | |
| L3 | Cancel | Cancel Face ID: stays locked, Unlock tries again. Kill and reopen: locked | | |
| L4 | Open dialogs close | Actions → Approve (confirm sheet open) → leave the app → come back: the sheet is gone, only the lock shows | | |
| L5 | App switcher | With the lock on, swipe up to the app switcher: the Homelab card shows a blurred lock, not your data | | |
| L6 | Notifications stay vague | With the lock on, a background notification says only "Something needs a look" / "An action is waiting" | | |

## Settings

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| S1 | Several servers | Add a second Homelab API server (for example the reference server): both listed, one has the checkmark | | |
| S2 | Switch | Shown server picker (or the Overview server menu) switches Overview, Actions, Chat and the widget | | |
| S3 | Delete removes the token | Swipe → Delete on a token server. Add it again: the token field is empty and Save says "Enter the token first." | | |
| S4 | Diagnostics | Version, bundle ID with the SideStore team suffix, App Group "ok", each server with "data … ago" | | |
| S5 | Reset everything | Confirm "Delete all data": welcome screen, no servers, widget shows "Open the app" | | |

## Accessibility

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| X1 | Dynamic Type XXL | iOS Larger Text at the biggest non-accessibility size and one accessibility size: no clipped text, action buttons stack instead of wrapping | | |
| X2 | VoiceOver | Host tiles read "`<name>`, `<status>`", the send button reads "Send", chat bubbles read "You: …" / "Agent: …" | | |
| X3 | Dark mode | Every tab and the widgets are readable in dark mode | | |

## SideStore refresh

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| D1 | Refresh All | SideStore → My Apps → Refresh All ends without an error | | |
| D2 | Data survives | Servers, pinned HA devices, settings and the Face ID lock are still there. No token error | | |
| D3 | Widget still works | Same App Group in Diagnostics as before, the widget shows data after opening the app once | | |
| D4 | Tailscale after refresh | After SideStore's VPN step, Tailscale is back on (or turning it on fixes "Is Tailscale on?") | | |

## Report

Paste Settings → Diagnostics → Copy report here:

```
```
