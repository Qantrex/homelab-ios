# Device test: Homelab 1.0.0

The checks that only a real iPhone can do. Use the IPA you will release, installed with `xtool install` (or, once it
is verified, SideStore), Tailscale on, and a real server (the agent, or the reference server). Mark each row ✅ / ⚠️ /
❌ and add a note.

Date: ____  iPhone model: iPhone 12 mini  iOS version: 18.7.3  App version (Settings → Diagnostics): ____

Installed with: xtool 1.24.0 + App Group patch (docs/SETUP.md) / SideStore (not verified yet, error -80045)

## Release-blocking rows

Every ⚠️/❌ in these rows gets fixed or decided before a release ([docs/RELEASE.md](docs/RELEASE.md), step 4). All
other rows are nice-to-have: run them when the area changed, and note what you skipped.

| Area | Rows |
|---|---|
| Install with xtool | X1, X2, X3 |
| First start and demo | FS1 to FS4 |
| Real server | R1, R2, R4, R7, R8 |
| Today | T1, T2, T7 |
| Lab | O1, O3, O4 |
| Actions: approve and deny | A1, A2, A4, A6, A8, A10 |
| Home tiles | H1, H2, H3, T4, T6 |
| Deals basics | DL1, DL2, DL4, DL6 |
| Chat basics | C1, C2, C7, C8 |
| Widgets | W1, W4, W5, W6, W12 |
| Background | B1, B3, B4, B6 |
| Settings | ST1, ST2, ST4, ST5 |

## Install

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| I1 | Add the source in SideStore | (after the first release; SideStore is not verified yet) Sources → + → `https://github.com/Qantrex/homelab-ios/releases/latest/download/source.json` shows "Homelab iOS" with the Homelab app | | |
| I2 | Install from the source | (SideStore) Installs without an error. SideStore → My Apps shows Homelab, active apps 2 of 3 | | |
| I3 | Icon and name | Home screen shows the Homelab icon (sharp, no white border) and the name "Homelab" | | |

## Install with xtool (free Apple ID)

How the owner installs it (docs/INSTALL-FROM-LINUX.md). Set up servers, a token server, Home tiles and widgets first.

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| X1 | Reinstall before expiry | With the app set up, plug the phone in and run `scripts/install-dev` (or `xtool install` of the IPA) again before the 7 days end: the app opens with the same servers, settings, Home tiles (names and icons) and Face ID setting; the token server loads without asking for its token; Settings → Diagnostics → Install expires shows a date 7 days after the reinstall | | |
| X2 | Expiry warning | With 2 days or less left (Diagnostics → Install expires): Today shows a card with a gold triangle, "This install stops opening in 2 days (free Apple ID, 7 days). Plug the iPhone into the computer and reinstall; your data stays." Under one day it says "in N hours". With more than 2 days left: no card. After X1: the card is gone | | |
| X3 | Widgets after a reinstall | After X1: Diagnostics → Shared storage shows the same App Group as before (not "none"); the widgets on the Home Screen show data after opening the app once, without removing them; the share extension still sends | | |

## First start

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| FS1 | Welcome screen | "Your homelab, in your pocket", a short text, four points, **Add a server**, **Try the demo** and a link to the server setup. No tabs yet | | |
| FS2 | Try the demo | Today with the date, a status line, the "today" numbers, actions waiting and Home tiles. Tabs: Today, Actions (with badge), Chat, Lab, Settings | | |
| FS3 | Demo is alive | Demo chat answers a message. A demo Home tile on Today flips. A demo Approve shows an answer | | |
| FS4 | Demo off | Settings → Demo servers off → back to the welcome screen (when no own server exists) | | |

## Real server

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| R1 | Add server | Type Homelab API, address `https://<machine>.<tailnet>.ts.net[:port]`, Login Tailscale / proxy. Save works | | |
| R1b | Token stays with its server | Edit a token server and change only its address: the token field asks for a token again ("The address or type changed…"). Renaming keeps the token | | |
| R2 | Test connection | Green "Connected to `<name>`: status, hosts and …" (the features in words), and the name field fills in when empty | | |
| R3 | Bad address | `ftp://x` or `http://example.com` shows red text under the field, Save is greyed out | | |
| R4 | Tailscale off | Turn Tailscale off, pull to refresh: "Can't reach `<host>`. Is Tailscale (or your VPN) on?" with Retry. No crash. Turn it back on: Retry loads the data | | |
| R6 | Wrong login | With a token server: a wrong token gives "The server refused access…" or "The server wants a login or token…", not a crash | | |
| R7 | No token over plain http | Edit a server: Homelab API, `http://<LAN IP>:<port>` or `http://100.x.y.z:<port>`, Login Token: the editor shows "This server uses a token over plain http…" as an error. Saved anyway (an old entry): Test and refresh show the same text and the server's log has no request. Login Tailscale on the same address, or the token server at its `https://….ts.net` address, still works | | |
| R8 | Edit server on a setup error | Edit a token server and paste a wrong token (or a bad address): the error banner on Today has Retry and **Edit server**. Edit server opens that server's editor in Settings. Tailscale off (a passing error): only Retry | | |

## Today and Lab

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| T1 | Today header | Weekday and date, with "Lab ›" at the right of that line; the headline "All quiet." or "1 problem." (gold or love with a glow when not calm), "3 of 3 machines up". Tapping the headline opens Lab; VoiceOver hints that it does | | |
| T2 | Today content | The day line from the "today" card, "To approve" with up to 3 actions (tap opens Actions), Home tiles, the other cards, the last report (tap opens Chat) | | |
| T3 | Look | True black (dark) or white (light), no blue anywhere, red/yellow only for problems and warnings | | |
| T4 | Tile names | Today → Home → Edit: each pinned entity has a "Name on the tile" field (the placeholder is Home Assistant's name). Type "Living room", Done: the tile reads "Living room" (not cut off). Empty the field: HA's name is back. 25+ characters are cut at 24 | | |
| T5 | Tile names: VoiceOver and HA | VoiceOver on a renamed tile says "Living room, <HA's name>". The HA app and its voice assistants still use the HA name. Unpin and re-pin the tile: the field is empty again. After an app update the names are still there | | |
| T6 | Tile icons | Today → Home → Edit: under a pinned entity, "Icon on the tile" → Floor lamp, Done: the tile shows a floor lamp, filled while the light is on. Back to Automatic: the bulb is back. Unpin and re-pin: Automatic again | | |
| T7 | "On Today" section | Today → Home → Edit: "On Today" at the top lists the pinned tiles in tile order, each with its name, "Name on the tile" (a visible label above the field) and "Icon on the tile". **Order** → drag a tile → **Done ordering** → Done: the tiles on Today are in the new order. Editing the Home Assistant server (new token or name) keeps the names and icons | | |
| T8 | No "Lab ›" without Lab | With a server whose Lab tab is missing (none selected, only Home Assistant): no "Lab ›" next to the date | | |
| O1 | Lab header | "All good" or "N problems", "checked … ago", and "N actions waiting" when there are any. A host with a warning (gold dot) but no problem: "No problems · 1 host with a warning" (or "N hosts with a warning"), not "All good"; Today stays calm | | |
| O2 | Problems | Listed first, with icon and "since …" | | |
| O3 | Hosts | One tile per host, "x/y up" in the title, load/RAM/disk bars, a sleeping PC shows "Asleep", not red | | |
| O4 | Host detail | Tap a tile: Status, System, Disks, Maintenance, Flags as the host has them. "Open web interface" opens Safari | | |
| O5 | Sparklines | Real agent (step 4): each host tile has a thin load line; the detail shows "Last 24 h" with Load, Memory, Temperature, Fullest disk, each with now (top right), min and max. Lines are white/black, gold or love only when the newest value is high; a host that was down has a gap. Footer "One point every 5 min, until …" matches the last watchdog run. VoiceOver reads "Load, last 24 hours, now …, minimum …, maximum …" | | |
| O6 | Containers | Host detail → Containers: every container, problems first with a love (exited, dead, unhealthy) or gold (restarting) dot and "N problems" in the header; state, health and restarts in the normal font. Matches `docker ps -a` on the host | | |
| O7 | Restart a container | Restart only on containers from the host's restart list (none when the server has no `restart-container`). Tap → "Restart `<name>`?" with a red Restart → spinner in the row → alert "Restarted `<name>`" with the agent's output, success haptic. Until the host's next check (up to ~10 min) the row says "restarted HH:MM, waiting for the next check" and has no Restart button; after that check its state is running (demo: checked at once, so no such line). A refused restart: "Restart of `<name>` failed" or "Didn't run", error haptic | | |
| O8 | Overkill machines | Settings → Detail → Overkill: under each machine's numbers on Today a thin 24 h load line | | |
| O9 | Cards | Server cards show (title, icon, items or text). A card item with a link opens Safari | | |
| O9b | Parcels | Each parcel row has a trailing "Delivered" button: tap → "Delivered Keyboard?" → Delivered → the row turns into "delivered" without a button (the server keeps a parcel delivered today until midnight). A parcel with a tracking link opens it on tap (Safari); one without does nothing | | |
| O10 | Checklist card | To-dos: a circle per item, done items struck through and grey, the due day on the right (gold today, love when overdue). Tap a circle → "Tick off Milk?" → Tick off → a spinner in the circle, success haptic, the item is ticked at once and stays ticked (not tappable) until the server's list drops it (HA too, up to 3 min). A to-do with double spaces in its text ticks off too. Items without an action, or a server without `run-actions`: the circle does nothing. With nothing open: "Nothing open." and the Add button | | |
| O11 | Card button | To-dos "+ ADD" → the Add a to-do form. List: the card's list when the server sends one in the card action's `payload` (`{"list": "todo"}`), else "–" (pick one); both are fine → Run → sheet closes, alert with the agent's answer | | |
| O12 | Countdown card | Deadlines soonest first, the big value on the right: gold "today" / "5 h", love "3 d ago", grey "4 d" | | |
| O12b | Lessons card | Cancelled lessons struck through and grey, substitutions / room changes with a gold dot and a gold time, the change in the subtitle. VoiceOver says "cancelled" / "changed" | | |
| O12c | Weather line | Standard / Overkill: under "Checked 2 min ago" one grey line with the weather card's subtitle ("Rain from 15:00, take an umbrella"); Calm: no such line, only the card | | |
| O12d | Lab cards | Server with `place: "lab"` cards (tailnet, ad blocking, backups; demo has them): they show in Lab between Hosts and Services, not on Today. Rows: a dot, name, reason in grey, value at the right; a yellow tint gives a gold dot and value, red love. Nothing is cut at 5.4" or at the largest text size (values go under the name) | | |
| O12e | Pause blocking | Ad blocking card → "Pause 5 min" → "Pause 5 min Blocking?" confirm → the value reads "paused · 5 min" in gold with a "Resume" button (demo) | | |
| O13 | Services | Service buttons are grouped and open the right page in Safari | | |
| O14 | Pull to refresh | Pull down: spinner, then "checked just now" | | |
| O15 | Offline banner with age | Tailscale off, wait 10+ min, open the app: orange banner with "Showing data from … ago", old data still visible | | |
| O16 | Actions shortcut | "N actions are waiting for you" jumps to the Actions tab | | |
| O17 | Diagnostics in Lab | At the end of Lab a "Diagnostics" row opens the same screen as Settings → Diagnostics | | |

## Actions

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| A1 | List and badge | Tab badge = number of pending actions. Each row: title, reason, job and id chips, age | | |
| A2 | Approve | Approve → the confirm names the action, "Runs this action now, one time." and a button **Approve** → "Running…" → alert with the server's result text. The row goes away | | |
| A3 | Always | Always → **Always allow** with the explanation → result text. Only shown when the server offers it | | |
| A4 | Deny | Deny → **Deny** (not red in the confirm), "Drops the proposal. Nothing runs." → result text. Nothing ran on the server | | |
| A6 | Already handled | Approve the same action on another device (or web), then tap it here: "No longer valid" / "This button is no longer valid (already handled or expired)." | | |
| A7 | Nothing pending | "Nothing to approve" placeholder; with Start tiles above it, one quiet row instead | | |
| A8 | Start: tiles | Real server: "Start" shows a tile per action in the agent's `chat/app-actions.json` (icon and label; with Overkill also the action's name). Demo: seven tiles | | |
| A9 | Start: a form | Wake-up: "Wake me" / "No wake-up" switch, day picker starts at tomorrow, time at 07:00, the argument under it (`2026-11-07T07:00`). Add a to-do with an empty To-do: Run → gold "To-do is missing." and a warning haptic, nothing sent. Due switch on → a day; "At a time" on → a time | | |
| A10 | Start: run | Add a to-do "Test from the app" → confirm shows the fields and "Runs at once on …" → Run now → sheet closes, alert "Add a to-do" with the agent's output, success haptic. The to-do is in HA; the chat shows what I started and the result. Restart a container asks with a red button | | |
| A11 | Start: refused | Restart a container with a name not on the host's list → alert "Restart a container failed" with the helper's output; error haptic | | |
| A13 | Hidden uid and card-only actions | Start grid has no "Tick off a to-do", "Parcel delivered" or read-later-done tile. Tick off a to-do that has a twin with the same text: only the ticked one is done (needs the server's hidden `uid`) | | |
| A14 | Wake-up: Normal | Wake-up form → "Normal" → a day: arg `2026-11-07:clear`; after Run the one-off for that day is gone (HA helpers off) | | |
| A12 | Start: link | `homelab://actions/wake-set` (Safari or Shortcuts) opens the app on Actions with the Wake-up form. Right after a reset (before the server's info), open the link and tap another tab at once: the form doesn't pop up later | | |
| A15 | Link fills the form | Shortcuts → Open URLs `homelab://actions/todo-add?summary=Milk%20%2B%20eggs&list=shopping`: the Add a to-do form with "Milk + eggs" and List Shopping (Due hidden). Run → confirm → it is on the HA shopping list. `homelab://actions/wake-set?arg=<tomorrow>T06:45`: "Wake me" with that day and 06:45. Also from a cold start and with the app lock on (Face ID first) | | |
| A16 | Link can't do more | `homelab://actions/todo-done?item=Milk&uid=x` opens nothing (card-only). `homelab://actions/todo-add?list=fridge&uid=x`: List stays "–", nothing sent before Run; the server log shows no `uid`. Nothing ever runs without the confirm | | |
| A17 | Shortcuts recipe | The "To-do" recipe in docs/SHORTCUTS.md (Dictate → URL Encode → Open URLs) via "Hey Siri, To-do": the form opens with the dictated text | | |
| A18 | Start without a form | A Start tile with nothing to fill in (demo: "Living room"): the tap asks "Run now?" right away (no empty form), Run now runs it | | |

## Scan and share

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| SC1 | Scan tile | Real server with `documents`: Actions → "Scan a document" tile under Start. A server without `documents`: no tile. Demo: tile, camera "needs a camera" only on the simulator | | |
| SC2 | Camera | Tap the tile: the first time iOS asks for the camera; the document camera opens by itself. Scan 3 pages (it finds the edges), Save | | |
| SC3 | Preview and send | "Making the PDF…", then the page count and the size (about 1 MB or less), title "Scan <date> <time>". Edit the title, Send → alert with the server's text, sheet closes. The PDF is in Paperless with that title (OCR'd) | | |
| SC4 | Quick action | Long-press the app icon → "Scan document": opens Actions with the camera. Also from a cold start (app closed) and with Face ID lock on (unlock first) | | |
| SC4b | Action quick actions | After the app loaded a server with Start actions: long-press the icon → Scan document plus three actions (before any start: the server's first three). Start "Living room" twice from Actions, leave the app: it is first now. Tap it (also from a cold start): the Living room form. Switch the shown server: the list follows it. Demo off / no server: only Scan | | |
| SC5 | `homelab://scan` | The link opens Actions and the Scan screen (Safari or Shortcuts). On a server without `documents` nothing opens | | |
| SC6 | Share a link | Safari → Share → Homelab: "Read later", the host, "To <server>". Send → "Sent". The link is on the server's list | | |
| SC7 | Share a willhaben ad | willhaben app or site → Share → Homelab: "Price check on willhaben" with the AD number. Send → "Sent"; the answer comes in the chat | | |
| SC8 | Share a PDF | Files or Mail → a PDF → Share → Homelab: "To Paperless", size, editable title. Send → in Paperless | | |
| SC9 | Share photos | Photos → select 3 → Share → Homelab: "3 photos as one PDF", about 1-2 MB. Send → one PDF in Paperless; no crash with 10 photos (memory) | | |
| SC10 | Refused | Share a note with only text, a contact, a `file:` link: "Can't send this" with a reason, nothing sent | | |
| SC11 | Offline: outbox | Tailscale off. Share a link and a scan: "Saved, Homelab sends it when it can." The Scan tile shows "N WAITING" in gold. Tailscale on, open Homelab: the tile's count goes away, the items arrive once (no doubles) | | |
| SC12 | Token server | Server with a token: Share → "Saved, ..."; open the app: it is sent | | |
| SC13 | Big PDF | Share a PDF over 25 MB: "more than the 25 MB the server takes". A 20 MB PDF over Tailscale arrives (limit of `tailscale serve`) | | |
| SC14 | Share sheet listing | After install the Homelab icon is in the share row (More → Homelab on if missing). Works after a SideStore refresh | | |

## Find and request

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| FR1 | Entry | Server with `search`: Actions → Start has "Find a movie or show". A server without it: no tile | | |
| FR2 | Search | Type 1 letter: nothing is sent. 2+ letters: after a short pause posters appear (3 columns, grey placeholder first, then the picture). Typing on does not flicker. "zzzz": "Nothing found" | | |
| FR3 | Request | A poster with a "Request" button → "Request <title>?" confirm → alert with the server's text, the poster says "requested" and loses the button. Cancel does nothing | | |
| FR4 | Pictures | Posters come from the server only (check the server log: no other host). Airplane mode after one search: the same posters still show (cache); the search itself shows the offline banner | | |
| FR5 | `homelab://search?q=dune` | Opens Actions and the search with "dune" typed and results. On a server without `search` nothing opens | | |
| FR6 | Large text | At an accessibility size the grid has 2 columns and nothing is cut; VoiceOver reads title, subtitle, value, then the Request button | | |

## Deals

Needs a server with `/api/v1/deals` (or Settings → Demo servers: the demo has five deals).

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| DL1 | Entry | Actions → Start has a "Deals" tile, with a gold dot and "N to act on" when strong deals are fresh. A server that answers 404 on `/deals`: no tile, no Today section, no error text anywhere | | |
| DL2 | List | Deals: "5 deals · 2 to act on · updated …", sections "Act now", "Worth a look", "Skipped". A row: title, specs, place (a small arrow when near), private/dealer, ships, condition, confidence, the note, price, "−50 %", "worth € …". Pull to refresh works | | |
| DL3 | Warnings | A deal with "too good to be true?" shows it in gold with a triangle (not red). Low confidence is gold with its words. Nothing in the screen is blue | | |
| DL4 | Detail | Tap a deal: big price, "−50 %", the verdict and note, **Open the ad** and **Copy link**, "Look twice" warnings, "About the ad", "Comparable ads" with prices | | |
| DL5 | Open and copy | Open the ad opens willhaben (the app if installed) or Safari on the right ad. Copy link: "Copied", a haptic, pasting gives the ad URL. A comparable's title (iris, underlined) opens that ad | | |
| DL6 | Today | While an "act now" deal from the last day exists: Today shows "Deals to act on" under "Waiting for you" (Calm hides it), tap opens Deals. With none: the section is gone | | |
| DL7 | Push link | A ntfy push (or Safari) with `homelab://deals` opens the app on Deals, also from a cold start and with the app lock on (Face ID first) | | |
| DL8 | Notification | Settings → Notifications → "New deals to act on" on (only shown with deals). A new strong deal: one notification "`<server>`: deal at € 100 (−50 %)" within the next background runs, tap opens Deals. Not again for the same deal, not for old ones, not for the ones already there when the toggle went on. With the app lock on: "A deal is waiting for you." | | |
| DL9 | Large text | At an accessibility size the figures go under the title, nothing is cut, VoiceOver reads a row as one sentence ("…, 50 percent below the market value, act now, …, warning: …") | | |
| DL10 | Empty | A server with `{"deals": []}`: "No deals right now" with the voice line when a personality is on | | |

## Chat

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| C1 | Send | The message shows at once ("Sending…", then "Sent"), the reply arrives | | |
| C2 | Working… | "Working…" with a spinner while the agent runs, gone when the reply is in | | |
| C3 | Report chips | Scheduled reports (`morning`, `watchdog`, …) have a coloured chip with a clock | | |
| C4 | Copy | Long-press a bubble → Copy → paste in Notes gives the full text | | |
| C5 | Commands | With the agent: the "/" button left of the field lists `/pending`, `/last`, `/memory`, `/usage`, `/autonomy`, `/help`, each with one line saying what it does. `/pending` sends at once and gets an answer; `/last …` goes into the field as "/last " to type the job. Typing "/" in the field lists the commands over it, "/me" only `/memory`. A server without `commands` in /info shows no "/" button | | |
| C5b | Clear | Toolbar → Clear → the dialog says it hides the messages on this iPhone only and the server keeps them → "Clear on this iPhone": the chat is empty ("Cleared on this iPhone"). A new message shows. Quit and reopen the app: still cleared. "Show earlier messages" brings everything back. The web chat still has all messages | | |
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
| W6 | Stale data marked | Tailscale off (or a token server selected and the app closed), wait 2+ hours: the status turns grey (no green check, no glow) and a clock shows the age; the lock-screen rectangular reads "Data from … open the app" | | |
| W7 | Day | "Homelab day" small: next stop big with "in N min", the line as dots; medium: every stop like on Today; lock screen rectangular and inline: next stop and countdown. The countdown moves on its own within a few minutes; after the last stop it says "passed". App lock on: "Open the app" | | |
| W7b | Tomorrow | After the last lesson (server: the today card has tomorrow's `date`): Today's day card says "Tomorrow", the first stop (wake-up) is bright with "in 10 h 20 min", no stop is grey, the line is empty. Day widget small shows "Tomorrow" and the same countdown; after midnight it is the normal day again | | |

### At a glance (6c)

Needs a server with the `departures` card and `commute` (or Settings → Demo servers: the demo has both, moved to now).

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| W8 | U6 widget | Add "U6 departures": small shows the direction, the stop and the next 3 times; a late one has a gold "+3"; a disruption is a gold triangle with its words. Lock screen: rectangular (line and direction, 3 times, then "Disruption" or "Delay +n min" with a symbol), inline ("U6 20:54 · 20:59"), circular (countdown to the next train in the ring). Trains drop off at their time without opening the app | | |
| W9 | Deadlines widget | Rectangular: the next 2 with "2 d" / "5 h"; inline "SYT hand-in in 2 d"; circular: number due this week; small: 3, medium: 5 with subtitles. Overdue ones read "3 d ago" with a triangle on the lock screen | | |
| W10 | To-dos widget | Rectangular: 3 open titles; circular: the open count; small: 4; medium: 6. A tap opens Today | | |
| W11 | Locked privacy | Settings → Lock with Face ID on: deadlines and to-dos show only counts ("3 deadlines this week", "4 to-dos"), never titles; the U6 widget still shows times. On the lock screen of a locked phone the titles are blank | | |
| W12 | Widget fetches itself | A Homelab API server with Login Tailscale / proxy selected, close the app, Tailscale on: after 15 to 30 min the widgets' age is fresh without opening the app (Settings → Diagnostics → At a glance → Widget fetch: "ok"). Tailscale off: the cached data stays with its age, Diagnostics shows the error. A token server selected: the widget never fetches (only the app and its background refresh update it). StandBy (on its side, charging): the U6 small widget shows | | |
| LA1 | Live Activity starts | On a school morning (or with the demo server) open the app: "Leave by hh:mm" with a countdown and "U6 hh:mm · next hh:mm" is on the lock screen; the disruption is a gold triangle with its words | | |
| LA2 | It runs by itself | Lock the phone for 10 minutes: the countdown keeps counting. After the train time the activity is greyed (stale) | | |
| LA3 | Updates and ends | When the pick changes on the server (a delay), a background refresh updates it (Diagnostics → Leave-by: "background: updated"). At the first lesson it is gone. Turn "Leave-by on the lock screen" off in Settings: it ends | | |
| LA4 | Not allowed / not started | Live Activities off for Homelab in iOS Settings: Diagnostics says "off in iOS Settings", no crash. The activity never starts from the background (only opening the app starts it) | | |

(LA1 to LA4 are named so because L1 to L6 are the Face ID lock rows.)

W7b now also: the Day widget's medium header says "Tomorrow" with the card's date, the countdown reads "in 10 h" and turns "in 9 h" on the hour.
The Hosts widget shows "Disk 93%" in gold (from 75 %) or love (from 90 %).

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
| B9 | Already answered | Approve the proposal in the app or chat first, then press Approve on its old notification: "`<server>`: no longer valid" (with the app lock on: "That didn't go through. Open the app to see why.") | | |
| B10 | App lock and buttons | Lock on, iOS Settings → Notifications → Show Previews "When Unlocked" (the default). Lock the phone, wait for a new proposal notification: the locked lock screen shows only "Homelab" with no text. Look at it so Face ID unlocks: it names the action ("`<server>`: approve …?"). Long-press it: Approve and Deny. Approve asks for Face ID / the passcode if the phone isn't unlocked, then runs (no "open Homelab" refusal); the result notification only says "Approved. Open the app for the answer." A problem notification with the lock on still says only "Something needs a look." | | |
| B11 | Press with the app killed | Swipe the app away, then Approve on a notification: the result notification still comes (iOS starts the app in the background) | | |

## Face ID lock

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| L1 | Turn on | Settings → Lock with Face ID: Face ID is asked first, then the toggle is on | | |
| L2 | Locks | Leave the app, come back: "Homelab is locked", Face ID unlocks | | |
| L3 | Cancel | Cancel Face ID: stays locked, Unlock tries again. Kill and reopen: locked | | |
| L4 | Open dialogs close | Actions → Approve (confirm sheet open) → leave the app → come back: the sheet is gone, only the lock shows | | |
| L5 | App switcher | With the lock on, swipe up to the app switcher: the Homelab card shows a blurred lock, not your data | | |
| L6 | Notifications stay vague | With the lock on, a problem notification says only "Something needs a look", a proposal without buttons only "An action is waiting for you". A proposal with Approve / Deny names its action (B10) | | |

## Settings

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| ST1 | Several servers | Add a second Homelab API server (for example the reference server): both under Servers with "Homelab API · <host>", the demo ones with "Demo · example data". No checkmarks in that list | | |
| ST2 | Switch | Settings → Data → "Show data from" lists the Homelab API servers with their kind; picking one switches Today, Lab, Actions, Chat and the widget (so does the Lab server menu). "Home tiles from" lists only Home Assistant servers and switches the Home tiles on Today | | |
| ST2b | Token over plain http | Add a server, Login Token, address `http://192.168.1.10:8080`: a red error under the address ("uses a token over plain http …"), Test connection and Save stay off. `https://…` or Login "Tailscale / proxy": the error goes | | |
| ST3 | Delete removes the token | Swipe → Delete on a token server. Add it again: the token field is empty and Save says "Enter the token first." | | |
| ST4 | Diagnostics | Version and build, bundle ID (with the SideStore team suffix after SideStore), Install expires with a date and time (free Apple ID), App Group "ok", each server with "data … ago". Copy report: host names have the tailnet part masked, no tokens | | |
| ST5 | Reset everything | Confirm "Delete all data": welcome screen, no servers, widget shows "Open the app" | | |

## Accessibility

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| AX1 | Dynamic Type XXL | iOS Larger Text at the biggest non-accessibility size and one accessibility size: no clipped text, action buttons stack instead of wrapping | | |
| AX2 | VoiceOver | Host tiles read "`<name>`, `<status>`", the send button reads "Send", chat bubbles read "You: …" / "Agent: …". A to-do reads "Milk, Shopping, today, not done" (an overdue one "…, overdue, 3 days ago, …"); double tap asks to tick it off, and the action "Tick off" does too; a deadline "Tax return, Paperwork, today" | | |
| AX3 | Dark mode | Every tab and the widgets are readable in dark mode | | |

## SideStore refresh

Nice-to-have until SideStore is verified (its sign-in failed with error -80045 on the test phone).

| # | Test | Pass when | Result | Note |
|---|---|---|---|---|
| D1 | Refresh All | SideStore → My Apps → Refresh All ends without an error | | |
| D2 | Data survives | Servers, pinned HA devices, settings and the Face ID lock are still there. No token error | | |
| D3 | Widget still works | Same App Group in Diagnostics as before, the widget shows data after opening the app once | | |
| D4 | Tailscale after refresh | After SideStore's VPN step, Tailscale is back on (or turning it on fixes "Is Tailscale on?") | | |
| D5 | Keychain group | Read the entitlements SideStore signed Homelab with (from the installed app's IPA: `ldid -e Payload/Homelab.app/Homelab` on Linux, `codesign -d --entitlements - Payload/Homelab.app` on a Mac). `keychain-access-groups` is missing or lists only `<TEAMID>.com.qantrex.homelab…`, not `<TEAMID>.*`. With the wildcard, every app sideloaded with the same Apple ID can read the Homelab tokens: note it here (docs/SECURITY.md, "SideStore and the Keychain") | | |

## Report

Paste Settings → Diagnostics → Copy report here (host names with the tailnet part masked, no tokens):

```
```
