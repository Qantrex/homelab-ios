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
| Display | `Typo.display` 28 semibold; `Typo.displayData` the same in SF Mono | The one big number in a card: a chart's current value, the next stop |
| Title | `Typo.sectionTitle` (`.title3.bold()`, 20) | Section titles ("Waiting for you", "Machines"), sheet titles |
| Headline | `Typo.headline` (17 semibold) | The name of a row or card ("restart media sonarr", "Living room"), the fact line |
| Body | `Typo.body` (17 regular) | Text people read: chat, the voice line |
| Secondary | `Typo.secondary` (15), `Palette.secondary` | What explains a row: reason, subtitle, the status line of a screen |
| Meta | `Typo.meta` (13), `Palette.tertiary` | When, where from ("checked 2 min ago"), column headers, footers |
| Data | `Typo.data(…)` (SF Mono); `Typo.rowValue` (15 medium) | **Numbers and ids only**: 3.10, 88%, 07:30, ab12. In a row's right-hand column: `rowValue` |

- Mono is for values, never for labels, dates in sentences, titles or buttons.
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
- Text colours keep 4.5:1 on the panel: tertiary #808080 (dark) / #6E6E6E (light), light-mode gold #9A6100, love
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

- The personality lives in words: the hero's second line, empty screens, notification subtitles, problem comments.
- No mascot, no character art, no speech bubbles. The line is plain `.body`/`.title3` text in `Palette.secondary`,
  directly under what it comments on.
- The fact is always shown plainly next to the joke, so the joke can be ignored.
- Off by default; Dry, Snarky, Ultrakill in Settings.

## 5. Platform patterns

- Standard tab bar, navigation, sheets, confirmation dialogs, swipe and pull to refresh. Custom styling, standard
  behaviour.
- Large titles on the tab roots except Today (whose hero is its title).
- Dynamic Type: stack horizontally adjacent things vertically at accessibility sizes; no truncation of important text.
  The hero scales too (`.heroFont()`, relative to `.largeTitle`).
- VoiceOver: what the screen shortens, it says in full: ages and countdowns in words (`Format.spoken`, "in 26
  minutes"), a value over its limit "high", a dot's colour as its word. Buttons are their own stops (44 pt), headings
  are one element. Changes that appear by themselves (an error, search results, a send) are announced (`announce`).
- Reduce Motion: animations through `reducedMotionAnimation`, rolling digits through `reducedMotionNumericText`.
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
- Mono (the data font) only for times and numbers; titles and directions stay in the normal font.
- The Live Activity is true black with white text; its countdown runs by itself (`Text(timerInterval:)`).
- With the app lock on, widgets show counts only, except public data (the U6 times).

## 6. Row grammar

One row, everywhere (problems, hosts, containers): status glyph or dot (the only colour) · name 17 semibold · reason
15 secondary · right column: values 15 mono medium, or an age 13 tertiary. Hosts (Lab, Standard): dot · name ·
sparkline 56x20 · Load, RAM, Disk in three right-aligned columns under a 13 header; a meta line under the name only
when there is something to say. Overkill density keeps the host tiles. At accessibility sizes the values go under
the name with their labels.
