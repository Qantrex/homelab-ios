# Design rules

How every screen, widget and extension looks. Based on Apple's Human Interface Guidelines (Layout, Typography,
Color, Branding; read 2026-11-06) and the owner's look: true black, monochrome, Rosé Pine only for status, never blue.
The idea comes from CARROT Weather (a bold "now", a voice with opinions about the facts), not its look.

When a screen breaks a rule here, change the screen, not the rule. When a rule is wrong, change it here first.

## 1. One voice per job: type

HIG: "Minimize the number of typefaces", use the system text styles, keep the hierarchy at every text size.

The scale is 48 / 28 / 20 / 17 / 15 / 13, every step at least 1.13x. At most five of them on one screen. All are named
roles in `Typo`; no screen picks a size by hand.

| Role | Font | Use for |
|---|---|---|
| Hero | `Typo.hero` via `.heroFont()` (SF Pro, heavy, 48 pt, scales like `.largeTitle`) | Today's headline only |
| Display | `Typo.display` 28 semibold; `Typo.displayData` the same with fixed-width digits | The one big number in a card: a chart's current value, the next stop |
| Title | `Typo.sectionTitle` (`.title3.bold()`, 20) | Section titles ("To approve", "Deals"), sheet titles |
| Headline | `Typo.headline` (17 semibold) | The name of a row or card ("restart media sonarr", "Living room"), the fact line |
| Body | `Typo.body` (17 regular) | Text people read: chat, the voice line |
| Secondary | `Typo.secondary` (15), `Palette.secondary` | What explains a row: reason, subtitle, the status line of a screen |
| Meta | `Typo.meta` (13), `Palette.tertiary` | When, where from ("checked 2 min ago"), column headers, footers, ids |
| Data | `Typo.data(…)` (SF Pro, fixed-width digits); `Typo.rowValue` (15 medium) | **Numbers only**: 3.10, 88%, 07:30. In a row's right-hand column: `rowValue` |
| Code | `Typo.code(…)` (SF Mono) | Code in chat only (code blocks, inline code) |

- One typeface: SF Pro. Numbers use its fixed-width digits (`Typo.data`), so columns line up without a second font.
  SF Mono only for code in chat. Owner, 2026-11-06: "too many different fonts and mono font".
- Words and ids are text, not data: "3 of 3 up" (not "3/3 up"), a proposal's id and an action's name in `Typo.meta`.
  Fixed-width digits only for numbers that change or sit in a column.
- No uppercase labels with tracking (the "terminal caption" look). Section titles are sentence case.
- No italics. Emphasis is weight or colour, not slant.
- Minimum 11 pt; prefer Regular, Medium, Semibold, Bold.

## 2. Space, not boxes: grouping

HIG: group related items with negative space, container shapes **or** separators; align things that belong together.

- Screen margin 16 pt (the system's), one column. Everything on a screen starts at the same leading edge.
- 8-pt grid, tokens in `Space`: 2-4 inside a label stack, **8 from a section title to its panel**
  (`Space.titleToPanel`), 12 between separate rows, **32 between sections** (`Space.section`), 32 under the hero.
  Inside a group is always clearly smaller than between groups.
- **One container style**: `.panel()` (or `.rowsPanel()` when the rows bring their own padding): filled `Palette.surface`,
  corner radius 16, no border. Surfaces by lightness, not borders: `background` #000000, `surface` #141414 (panels),
  `raised` #1F1F1F (things inside a panel: buttons, a tile that is on), `line` #2A2A2A (tracks). Light mode:
  white, #F2F2F2, #E6E6E6, #D8D8D8. Rows inside a panel
  are split by separators (inset 16), never by nested panels.
- No hairline borders around panels, tiles or bubbles. Status is never a coloured border (see 3).
- A section = a title + one panel (or a grid of tiles). Not a panel per item.
- Tiles in a grid have equal heights; the grid's outer edges line up with the panels above and below.

## 3. Colour is information

HIG: colour sparingly, for status indicators and primary actions; the same colour always means the same thing; never
colour alone.

| Colour | Means | Where it may appear |
|---|---|---|
| `Palette.text` (white) | Normal | Text, primary buttons (filled), selected tab |
| `secondary` / `tertiary` | Less important | Explanations, meta |
| `love` #eb6f92 | Something is broken | The status dot/icon of that thing, its number, the hero's mood light |
| `gold` #f6c177 | Needs a look | Same as love |
| `iris` #c4a7e7 | A link | Links only |

- The hero headline stays white. The mood is the light behind it (`MoodGlow`) plus a status icon, not coloured text.
- Colour sits on symbols, dots and numbers only. A meter or sparkline is grey; only the value next to it (and the
  sparkline's last dot) turns gold or love. **One set of limits** (`HostHistory.Series.limits`, `Series.level`,
  `Meter.valueColor`) for the row, the tile, the dot and the detail chart: gold from / love from: load 1x / 2x the core
  count, RAM 90 / 95 %, fullest disk 75 / 90 %, temperature 80 / 90 C. Reaching the limit counts. A value over its limit
  also says "high" to VoiceOver.
- Text colours keep 4.5:1 on the panel: tertiary #8A8A8A (dark) / #666666 (light), light-mode gold #8F5A00 (also on raised panels), love
  #9E4A63, iris #735C8C (also on `raised`). Min and max numbers are secondary, not tertiary.
- Increase Contrast: `Palette` switches to stronger twins: surface #262626, raised #333333, line #5A5A5A, secondary and
  tertiary #B3B3B3 on black; surface #E8E8E8, raised #D9D9D9, line #8C8C8C, secondary and tertiary #3D3D3D and darker
  love, gold and iris on white.
- Links (iris) are also underlined: never colour alone.
- A broken item shows a coloured dot or SF Symbol next to it (with its word: "unhealthy", "93%"), not a coloured card.
- One accent per element: never coloured text in a coloured border in a coloured glow.
- Never blue, also not by default: every control sets `.tint(Palette.accent)`.

## 4. The voice

HIG Branding: "Use your brand's unique voice and tone", "branding always defers to content", don't repeat a logo.

- The personality lives in words: the hero's second line, Lab's header, an aside under each problem, empty screens
  and lists, the alert after an action ("Done." and a remark), notification subtitles. All text and picking is in
  HomelabKit (`Voice.line(for:)`, VoiceLines.swift); a view only shows the line.
- No mascot, no character art, no speech bubbles. The line is plain `.body`/`.title3` text in `Palette.secondary`,
  directly under what it comments on.
- The fact is always shown plainly next to the joke, so the joke can be ignored.
- Under the hero, plain text, never part of its button: the weather as one sentence with its symbol ("☁ Clear, 3 °C
  now", `Typo.secondary`), and where the data is from ("homelab · checked 4 min ago", meta) **only** while a pull to
  refresh runs, after a failed fetch, or when the data is older than 10 min (`FreshnessLine`; Overkill always).
  A line that is always there says nothing (owner, 2026-11-06).
- Off by default; Dry, Snarky, Ultrakill in Settings.
- Lines read like one quick human remark about the actual fact: short, varied rhythm, no setup without a punchline,
  no sentence pattern repeated from line to line (owner 2026-11-09: "feels forced"). Dry understates, Snarky teases
  the owner and the hardware with a little everyday politics, **Ultrakill is a different tier**: harsh, profane,
  absurd and merciless about the owner and the lab, with satire of politics and current events in general terms.
  Never slurs, jokes about who people are, anything sexual, self-harm, real people or threats (TakeTests enforces it).
- Ultrakill is special: choosing it asks once ("Ultrakill. It will insult you, your servers and your life choices. No
  refunds." with Enable / Back; Back keeps the previous level). "Seen" is `AppSettings.ultrakillWarned`, an optional
  that is omitted from `settings.json` until then (`UltrakillWarningModifier`, UltrakillWarning in Voice.swift).

## 5. Platform patterns

- Standard tab bar, navigation, sheets, confirmation dialogs, swipe and pull to refresh. Custom styling, standard
  behaviour.
- Large titles on the tab roots except Today (whose hero is its title).
- Dynamic Type: stack horizontally adjacent things vertically at accessibility sizes; no truncation of important text.
  The hero scales too (`.heroFont()`, relative to `.largeTitle`).
- VoiceOver: what the screen shortens, it says in full: ages and countdowns in words (`Format.spoken`, "in 26
  minutes"), a value over its limit "high", a dot's colour as its word. Buttons are their own stops (44 pt), headings
  are one element. Changes that appear by themselves (an error, search results, a send) are announced (`announce`).
- Test on the smallest phone (5.4") and at AX text sizes: `scripts/phone-shots`, CI shots.

## Checklist for a screen

1. Count the type styles: only the roles in 1.
2. Squint: is there exactly one most important thing, at the top leading edge?
3. Count borders: zero. Count nested panels: zero.
4. Count colours: only status things are coloured, and each says why in words.
5. Leading edges: one line down the screen.
6. Gaps: 8 under a section title, 32 between sections (use `Space`).

## Lock screen and Live Activity

- Lock-screen widgets (`accessory*`) draw in one colour (vibrant mode): gold and love disappear. Every status there is
  a symbol plus words ("Delay +3 min" with a clock badge, "Disruption" with a triangle), never colour alone. Gold is
  an addition on the home screen and in the Live Activity.
- The data font (`Typo.data`, fixed-width digits) only for times and numbers; titles and directions stay in the
  normal font. No SF Mono in widgets.
- The Live Activity is true black with white text; its countdown runs by itself (`Text(timerInterval:)`).
- With the app lock on, widgets show counts only, except public data (the U6 times).

## 6. Row grammar

One row, everywhere (problems, hosts, containers): status glyph or dot (the only colour) · name 17 semibold · reason
15 secondary · right column: values 15 medium (fixed-width digits), or an age 13 tertiary. Hosts (Lab): dot · name ·
sparkline 56x20 · Load, RAM, Disk in three right-aligned columns under a 13 header; a meta line under the name only
when there is something to say. Today has no machine list (see 8). At accessibility sizes the values go under
the name with their labels.

Cards use it too (to-dos, parcels, deadlines, lessons, downloads): the leading glyph at 17, the reason on at most two
lines, a progress ring 20 pt inline after the value (no number inside it; the value column has it).

Lab cards (tailnet, ad blocking, backups) are rows of the same grammar in one panel: dot · title · subtitle · value,
a thin bar only where there is progress. A row that needs a look has the warning glyph (gold / love, grey for a
tailnet device that is away) in the dot's place and its word in the value column; "online" says nothing. A list of more
than 3 rows shows 3 and a "Show N more" row (`LabRows`, `rowMotion`; "Show less" closes it).

Proposals (Actions, chat) are rows with Approve (filled white capsule), Always (`raised` capsule) and Deny (text)
inline; on the right the age with the clock time under it ("18 min ago" / "21:03", "Thu 21:03" another day), both meta.

## 7. Buttons, motion and haptics

- Buttons in rows and cards: `CapsuleButtonStyle` (filled = the one primary action, raised, or text), 15 semibold,
  a hit area of at least 44 x 44 pt around the visible shape. Labels never wrap, except in a narrow poster column.
- Motion lives in `Motion` (HomelabDesign): `motion(_:value:)` instead of `animation(_:value:)`, `rowMotion` for rows
  that come and go (spring 0.35 / 0.85), `numberMotion` or `Motion.numeric` for numbers, `Motion.symbol` for symbol
  swaps. With Reduce Motion all of them turn off; no view checks it by hand.
- Haptics (`Haptics.swift`): success when an Approve or a started action ran, a selection tick for a tick-off,
  toggle or Deny, an error buzz when it didn't run, a warning when a refresh brings a new problem (once, app-wide).

## 8. Today: short by design

Today is read in a few seconds, so it is short by default and long only when you ask (owner, 2026-11-08). Targets at
the default text size with typical data on an iPhone 12 mini:

| Detail | Length |
|---|---|
| Calm | One screen: the day card and the Home tiles. Unchanged |
| Standard | Two screens at most. The first screen has the hero, Tomorrow, the approvals and every urgent row |
| Overkill | Three screens at most |

- **Urgent rows never fold.** A row that needs you always shows, with a warm or red tint: a deadline that is overdue
  or due within 3 days; a to-do past its time; a proposal. Warm tints belong to urgent rows only, and
  colour is never the only sign (the row says why in words).
- **Standard folds the rest.**
  - The hero stays. The weather card is not drawn on Today: the hero line says it. The hero has no "Lab ›" link: the
    headline and the machines line lead to Lab, and the Lab tab is one tap away (owner, 2026-11-08).
  - The short "today" text is one plain line. Tomorrow's "No school" is a caption without a panel.
  - To approve shows 2 proposals and "and N more", which opens Actions.
  - To-dos and parcels fold after 3 rows. Deadlines show only the urgent ones (overdue or within 3 days), never topped up with later ones: everything
    later is behind "Show N more · next Fri", and with none urgent the card is just that row (owner, 2026-11-09).
    The briefing shows 3 lines and "Show more".
  - A small list card (a game server: "Mira is playing") is one line. An unknown card folds after 3 rows or 3 lines.
- **Tiles hold what is nice to know: deals, recent downloads and grades.** No panel title. Each tile has the icon and
  a short name ("Deals", "Downloads", "Grades"), the count as a big number and one short line ("best −50 %",
  "Dune +7", "ITP 95 %"). A tap opens the full list in a sheet (title and Done; the card as Lab and chat draw it; the
  deals sheet ends with "Open Deals"). Today never grows when a tile is tapped.
  - **Layout by count, never uneven** (`TodayFold.tileRows`): 4 tiles are 2 by 2, 3 are one row of 3, 2 one row of 2,
    1 full width; at accessibility text sizes one full-width tile per row. A row's tiles have equal heights.
  - A tile is a button of at least 44 pt, one VoiceOver element ("Deals, 2, best minus 50 percent. Opens the list."),
    never blue. A warm tint (gold icon and a faint gold fill, "needs you" for VoiceOver) only when a row in it is
    urgent.
- **Departures are not a tile and not on Today by default.** They show only while the day has an upcoming "Leave by"
  within 60 minutes (`TodayFold.departuresMatter`), and then at the top, inside the day card under the school stops
  and Leave by. A disruption counts only with such a Leave by: on a day without one (no school, tomorrow's card,
  Leave by already passed) departures stay hidden even with a disruption.
- **Overkill is the same design with more detail per line, not everything open.** The deals tile says "best −70 % ·
  GPU €140", downloads name two ("Dune, Arrival +6"), grades two ("ITP 95 %, SEW 88 %"), a few more rows before a
  fold (5 deadlines), about 6 briefing lines.
- **Machines are in Lab only**, in every detail level. The hero line ("3 of 3 machines up") stays. The saved layout
  keeps the `machines` case so old settings still load.
- **Lab hosts are always list rows, never tiles** (three hosts made an uneven grid): one full-width row per host in
  one panel, with Load, RAM and Disk in three right-hand columns under a small header, in every density and text size.
  From xxLarge the values stack under the name ("Load 0.42" per line). The 24 h load sparkline stays in the row (it
  drops when the row is too narrow), and a tap opens the host's details.
- **Expanding lasts for the session.** Everything folds again on each app launch; nothing is saved.
- **Accessibility.** A fold row says what it hides and its state: "Deadlines, 9 more, collapsed"; it is at least 44 pt
  high, and expanding announces itself. At accessibility text sizes the tiles are one per row and their lines wrap,
  so Today may be longer than the budget; the budget is for the default size.
- Colours as in 3: white and grey, never blue.

## 9. Settings and Advanced

Settings is short: what most people touch, then one row for the rest (owner, 2026-11-09: "too detailed settings should
live in an advanced section").

- **Top level:** Data (which server), Servers, Today (Detail, Personality), Notifications (the three toggles),
  Privacy (Face ID, Reset everything), the **Advanced** row, About (About Homelab, Version).
- **Advanced:** Today's Sections (order, hide, show rules) and Where you are; Layout (Start tiles, Lab, Tab bar);
  Chat (Text size, Long replies); Quiet hours; Leave-by on the lock screen; Diagnostics; Demo servers; a reset for the
  layout and chat options. The row says "Customized" while something there differs from the default.
- **The title follows the personality** (`AdvancedTitle`, its own small table): Off and Dry "Advanced", Snarky
  "Nerd section", Ultrakill "Nerd shit". The words never replace what is inside.
- **Order editors** (Start tiles, Lab, Tab bar; `OrderEditor`): a list in edit mode, each row is the name, an optional
  meta line and a switch; drag by the handle, or VoiceOver's Move up and Move down actions; rows are at least 44 pt;
  hidden rows say "hidden" to VoiceOver. "Standard order" resets one list.
- **Hide and reorder rules** (`ItemOrder`): things are named by a stable id (action `name`, lab card `id`, tab name).
  What the server adds later appears at the end and visible; a name that is gone is skipped, a hidden one stays hidden
  if it returns. Lab keeps Problems on top; the Hosts and Services blocks and every lab card can be hidden. The tab bar
  never hides Settings (also not from a hand-edited file); the first shown tab is where the app opens. A link or tap
  that wants a hidden tab (`homelab://chat`, the approvals row) leaves the shown tab and says "Chat is hidden" in an
  alert; a hidden Start tile can still be opened by `homelab://actions/<name>`.
- **Chat:** text size is one Dynamic Type step smaller or larger than the system's (Small, Default, Large). Long
  replies fold after 12 lines by default (Default), after 6 (Short), or never.
- Everything is optional in `settings.json` and written only once it differs from the default, so an older file saves
  back byte for byte (OwnerInvarianceTests).
