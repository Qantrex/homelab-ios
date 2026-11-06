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
| F2 | Try the demo | Today with the date, a status line, the "today" numbers, actions waiting and Home tiles. Tabs: Today, Actions (with badge), Chat, Lab, Settings | | |
| F3 | Demo is alive | Demo chat answers a message. A demo Home tile on Today flips. A demo Approve shows an answer | | |
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

## Today and Lab

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| T1 | Today header | Weekday, date and server name; the status line says "All fine" or "N problems" with the first problem, "x/y up · checked … ago". Tap opens Lab | | |
| T2 | Today content | The "today" card in big numbers, "Waiting for you" with up to 3 actions (tap opens Actions), Home tiles, the other cards, the last report (tap opens Chat) | | |
| T3 | Look | True black (dark) or white (light), no blue anywhere, red/yellow only for problems and warnings | | |
| O1 | Lab header | "All good" or "N problems", "checked … ago", and "N actions waiting" when there are any | | |
| O2 | Problems | Listed first, with icon and "since …" | | |
| O3 | Hosts | One tile per host, "x/y up" in the title, load/RAM/disk bars, a sleeping PC shows "Asleep", not red | | |
| O4 | Host detail | Tap a tile: Status, System, Disks, Maintenance, Flags as the host has them. "Open web interface" opens Safari | | |
| O5 | Sparklines | Real agent (step 4): each host tile has a thin load line; the detail shows "Last 24 h" with Load, Memory, Temperature, Fullest disk, each with now (top right), min and max in mono. Lines are white/black, gold or love only when the newest value is high; a host that was down has a gap. Footer "One point every 5 min, until …" matches the last watchdog run. VoiceOver reads "Load, last 24 hours, now …, minimum …, maximum …" | | |
| O6 | Containers | Host detail → Containers: every container, problems first with a love (exited, dead, unhealthy) or gold (restarting) dot and "N problems" in the header; state, health and restarts in mono. Matches `docker ps -a` on the host | | |
| O7 | Restart a container | Restart only on containers from the host's restart list (none when the server has no `restart-container`). Tap → "Restart `<name>`?" with a red Restart → spinner in the row → alert "Restarted `<name>`" with the agent's output, success haptic. Until the host's next check (up to ~10 min) the row says "restarted HH:MM, waiting for the next check" and has no Restart button; after that check its state is running (demo: checked at once, so no such line). A refused restart: "Restart of `<name>` failed" or "Didn't run", error haptic | | |
| O8 | Overkill machines | Settings → Detail → Overkill: under each machine's numbers on Today a thin 24 h load line | | |
| O9 | Cards | Server cards show (title, icon, items or text). A card item with a link opens Safari | | |
| O9b | Parcels | Each parcel row has a trailing "Delivered" button: tap → "Delivered Keyboard?" → Delivered → the row turns into "delivered" without a button (the server keeps a parcel delivered today until midnight). A parcel with a tracking link opens it on tap (Safari); one without does nothing | | |
| O10 | Checklist card | To-dos: a circle per item, done items struck through and grey, the due day on the right (gold today, love when overdue). Tap a circle → "Tick off Milk?" → Tick off → a spinner in the circle, success haptic, the item is ticked at once and stays ticked (not tappable) until the server's list drops it (HA too, up to 3 min). A to-do with double spaces in its text ticks off too. Items without an action, or a server without `run-actions`: the circle does nothing. With nothing open: "Nothing open." and the Add button | | |
| O11 | Card button | To-dos "+ ADD" → the Add a to-do form. List: the card's list when the server sends one in the card action's `payload` (`{"list": "todo"}`), else "–" (pick one); both are fine → Run → sheet closes, alert with the agent's answer | | |
| O12 | Countdown card | Deadlines soonest first, the big value on the right: gold "today" / "5 h", love "3 d ago", grey "4 d" | | |
| O12b | Lessons card | Cancelled lessons struck through and grey, substitutions / room changes with a gold dot and a gold time, the change in the subtitle. VoiceOver says "cancelled" / "changed" | | |
| O12c | Weather line | Standard / Overkill: under "Checked 2 min ago" one grey line with the weather card's subtitle ("Rain from 15:00, take an umbrella"); Calm: no such line, only the card | | |
| O13 | Services | Service buttons are grouped and open the right page in Safari | | |
| O14 | Pull to refresh | Pull down: spinner, then "checked just now" | | |
| O15 | Offline banner with age | Tailscale off, wait 10+ min, open the app: orange banner with "Showing data from … ago", old data still visible | | |
| O16 | Actions shortcut | "N actions are waiting for you" jumps to the Actions tab | | |

## Actions

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| A1 | List and badge | Tab badge = number of pending actions. Each row: title, reason, job and id chips, age | | |
| A2 | Approve | Approve → dialog "Run once" → "Running…" → alert with the server's result text. The row goes away | | |
| A3 | Always | Always → "Run and always allow" with the explanation → result text. Only shown when the server offers it | | |
| A4 | Deny | Deny → red "Deny", "Drops the proposal. Nothing runs." → result text. Nothing ran on the server | | |
| A6 | Already handled | Approve the same action on another device (or web), then tap it here: "No longer valid" / "This button is no longer valid (already handled or expired)." | | |
| A7 | Nothing pending | "Nothing to approve" placeholder; with Start tiles above it, one quiet row instead | | |
| A8 | Start: tiles | Real server: "Start" shows a tile per action in the agent's `chat/app-actions.json` (icon, label, name in mono). Demo: seven tiles | | |
| A9 | Start: a form | Wake-up: "Wake me" / "No wake-up" switch, day picker starts at tomorrow, time at 07:00, the argument in mono under it (`2026-11-07T07:00`). Add a to-do with an empty To-do: Run → gold "To-do is missing." and a warning haptic, nothing sent. Due switch on → a day; "At a time" on → a time | | |
| A10 | Start: run | Add a to-do "Test from the app" → confirm shows the fields and "Runs at once on …" → Run now → sheet closes, alert "Add a to-do" with the agent's output, success haptic. The to-do is in HA; the chat shows what I started and the result. Restart a container asks with a red button | | |
| A11 | Start: refused | Restart a container with a name not on the host's list → alert "Restart a container failed" with the helper's output; error haptic | | |
| A13 | Hidden uid and card-only actions | Start grid has no "Tick off a to-do", "Parcel delivered" or read-later-done tile. Tick off a to-do that has a twin with the same text: only the ticked one is done (needs the server's hidden `uid`) | | |
| A14 | Wake-up: Normal | Wake-up form → "Normal" → a day: arg `2026-11-07:clear`; after Run the one-off for that day is gone (HA helpers off) | | |
| A12 | Start: link | `homelab://actions/wake-set` (Safari or Shortcuts) opens the app on Actions with the Wake-up form. Right after a reset (before the server's info), open the link and tap another tab at once: the form doesn't pop up later | | |
| A15 | Link fills the form | Shortcuts → Open URLs `homelab://actions/todo-add?summary=Milk%20%2B%20eggs&list=shopping`: the Add a to-do form with "Milk + eggs" and List Shopping (Due hidden). Run → confirm → it is on the HA shopping list. `homelab://actions/wake-set?arg=<tomorrow>T06:45`: "Wake me" with that day and 06:45. Also from a cold start and with the app lock on (Face ID first) | | |
| A16 | Link can't do more | `homelab://actions/todo-done?item=Milk&uid=x` opens nothing (card-only). `homelab://actions/todo-add?list=fridge&uid=x`: List stays "–", nothing sent before Run; the server log shows no `uid`. Nothing ever runs without the confirm | | |
| A17 | Shortcuts recipe | The "To-do" recipe in docs/SHORTCUTS.md (Dictate → URL Encode → Open URLs) via "Hey Siri, To-do": the form opens with the dictated text | | |

## Scan and share

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| S1 | Scan tile | Real server with `documents`: Actions → "Scan a document" tile under Start. A server without `documents`: no tile. Demo: tile, camera "needs a camera" only on the simulator | | |
| S2 | Camera | Tap the tile: the first time iOS asks for the camera; the document camera opens by itself. Scan 3 pages (it finds the edges), Save | | |
| S3 | Preview and send | "Making the PDF…", then 3 PAGES and a size in mono (about 1 MB or less), title "Scan <date> <time>". Edit the title, Send → alert with the server's text, sheet closes. The PDF is in Paperless with that title (OCR'd) | | |
| S4 | Quick action | Long-press the app icon → "Scan document": opens Actions with the camera. Also from a cold start (app closed) and with Face ID lock on (unlock first) | | |
| S4b | Action quick actions | After the app loaded a server with Start actions: long-press the icon → Scan document plus three actions (before any start: the server's first three). Start "Living room" twice from Actions, leave the app: it is first now. Tap it (also from a cold start): the Living room form. Switch the shown server: the list follows it. Demo off / no server: only Scan | | |
| S5 | `homelab://scan` | The link opens Actions and the Scan screen (Safari or Shortcuts). On a server without `documents` nothing opens | | |
| S6 | Share a link | Safari → Share → Homelab: "Read later", the host, "To <server>". Send → "Sent". The link is on the server's list | | |
| S7 | Share a willhaben ad | willhaben app or site → Share → Homelab: "Price check on willhaben" with the AD number. Send → "Sent"; the answer comes in the chat | | |
| S8 | Share a PDF | Files or Mail → a PDF → Share → Homelab: "To Paperless", size, editable title. Send → in Paperless | | |
| S9 | Share photos | Photos → select 3 → Share → Homelab: "3 photos as one PDF", about 1-2 MB. Send → one PDF in Paperless; no crash with 10 photos (memory) | | |
| S10 | Refused | Share a note with only text, a contact, a `file:` link: "Can't send this" with a reason, nothing sent | | |
| S11 | Offline: outbox | Tailscale off. Share a link and a scan: "Saved, Homelab sends it when it can." The Scan tile shows "N WAITING" in gold. Tailscale on, open Homelab: the tile's count goes away, the items arrive once (no doubles) | | |
| S12 | Token server | Server with a token: Share → "Saved, ..."; open the app: it is sent | | |
| S13 | Big PDF | Share a PDF over 25 MB: "more than the 25 MB the server takes". A 20 MB PDF over Tailscale arrives (limit of `tailscale serve`) | | |
| S14 | Share sheet listing | After install the Homelab icon is in the share row (More → Homelab on if missing). Works after a SideStore refresh | | |

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
| C9 | Proposal in a bubble | A watchdog message with a proposal shows it under the text with Approve / Always / Deny → the same dialogs as Actions → result alert and haptic; the buttons go away once it is answered (here, in Actions or by /approve) | | |
| C10 | Card in a bubble | A reply with a card shows it small under the text (at most 6 rows, "and N more") | | |
| C8 | No duplicates | Leave the app for a minute, come back: no message shows twice | | |

## Home (Home Assistant)

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| H1 | Add HA | Type Home Assistant, address, long-lived token → Test connection "Home Assistant answers." → Save. A Home section appears on Today | | |
| H2 | Pin devices | Today → Home → Edit → search works → pick the living room lamps and "stop morning routine" → Done. Two tiles show | | |
| H3 | Toggle | Toggle a light: it changes in the room and the switch shows the real state after a moment | | |
| H4 | Run script | Run on a script or scene: it runs in HA | | |
| H5 | Unavailable | An unavailable device shows "Unavailable" (sensor) or a greyed-out toggle, no crash | | |
| H6 | Wrong token | Edit HA, paste a wrong token: a clear error text in the Home section on Today, no crash. Put the right one back | | |

## Widgets

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| W1 | Small | Long-press home screen → + → Homelab → "Homelab status": date, headline in its colour (glow when not calm), first problem or "x of y machines up", server and age, pending badge | | |
| W2 | Medium | "Homelab hosts" medium: 4 hosts with load, RAM and disk bar | | |
| W3 | Large | Large: up to 8 hosts and up to 4 problems | | |
| W4 | Lock screen | Circular, rectangular and inline widgets show status (and pending count) | | |
| W5 | Tap opens the right tab | Status with pending actions → Actions. Status without, day, rectangular → Today. Hosts (medium, large) → Lab | | |
| W6 | Stale data marked | Tailscale off, wait 15+ min: "Data is old" and a grey question mark, not a green check | | |
| W7 | Day | "Homelab day" small: next stop big with "in N min", the line as dots; medium: every stop like on Today; lock screen rectangular and inline: next stop and countdown. The countdown moves on its own within a few minutes; after the last stop it says "passed". App lock on: "Open the app" | | |
| W7b | Tomorrow | After the last lesson (server: the today card has tomorrow's `date`): Today's day card says "Tomorrow", the first stop (wake-up) is bright with "in 10 h 20 min", no stop is grey, the line is empty. Day widget small shows "Tomorrow" and the same countdown; after midnight it is the normal day again | | |

## Background and notifications

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| B1 | Off by default | Settings → Notifications: both toggles off on a fresh install | | |
| B2 | Permission prompt | Turn on "New problems": iOS asks once. Deny → the note "Notifications are off for Homelab…" and the toggle stays off | | |
| B3 | Background runs | After a day of normal use: Diagnostics → Background → Last run has a time and Result starts with "ok" | | |
| B3b | Push opens the app | Tap a push whose link is `homelab://chat` / `actions` / `lab` / `today`: the app opens on that tab (also from a cold start) | | |
| B4 | One notification per new problem | Make a problem (stop a checked service): one notification "`<server>`: problem" within the next runs | | |
| B5 | No repeats | The same problem never notifies again while it lasts | | |
| B6 | New action | A new pending action gives "`<server>`: approve …?". Tapping it opens Actions | | |
| B7 | Approve on the notification | Lock the phone, wait for a new proposal notification. Long-press it: Approve and Deny (red), no Always. Approve asks for Face ID / the passcode first, then (without opening the app) a second notification "`<server>`: approved …" with the server's answer. The action ran (chat / server log); Actions no longer lists it, the badge and widget follow at the next refresh | | |
| B8 | Deny on the notification | Same with Deny: "`<server>`: denied …", nothing ran. A proposal with only an approve button shows only Approve; one without buttons none | | |
| B9 | Already answered | Approve the proposal in the app or chat first, then press Approve on its old notification: "`<server>`: no longer valid" | | |
| B10 | App lock and buttons | Lock on: a new proposal notification says only "An action is waiting for you." and has no buttons. Press Approve on a notification from before the lock was on: "The app lock is on: open Homelab to answer.", nothing ran | | |
| B11 | Press with the app killed | Swipe the app away, then Approve on a notification: the result notification still comes (iOS starts the app in the background) | | |

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
| S2 | Switch | Shown server picker (or the Lab server menu) switches Today, Lab, Actions, Chat and the widget | | |
| S3 | Delete removes the token | Swipe → Delete on a token server. Add it again: the token field is empty and Save says "Enter the token first." | | |
| S4 | Diagnostics | Version, bundle ID with the SideStore team suffix, App Group "ok", each server with "data … ago" | | |
| S5 | Reset everything | Confirm "Delete all data": welcome screen, no servers, widget shows "Open the app" | | |

## Accessibility

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| X1 | Dynamic Type XXL | iOS Larger Text at the biggest non-accessibility size and one accessibility size: no clipped text, action buttons stack instead of wrapping | | |
| X2 | VoiceOver | Host tiles read "`<name>`, `<status>`", the send button reads "Send", chat bubbles read "You: …" / "Agent: …". A to-do reads "Milk, Shopping, today, not done" (an overdue one "…, overdue, 3 days ago, …"); double tap asks to tick it off, and the action "Tick off" does too; a deadline "Tax return, Paperwork, today" | | |
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
