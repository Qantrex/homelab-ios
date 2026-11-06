# Design rules

How every screen, widget and extension looks. Based on Apple's Human Interface Guidelines (Layout, Typography,
Color, Branding; read 2026-11-06) and the owner's look: true black, monochrome, Rosé Pine only for status, never blue.
The idea comes from CARROT Weather (a bold "now", a voice with opinions about the facts), not its look.

When a screen breaks a rule here, change the screen, not the rule. When a rule is wrong, change it here first.

## 1. One voice per job: type

HIG: "Minimize the number of typefaces", use the system text styles, keep the hierarchy at every text size.

| Role | Font | Use for |
|---|---|---|
| Hero | `Typo.hero` (SF Pro, heavy, 48 pt, scales) | Today's headline only |
| Title | `Typo.sectionTitle` (`.title3.bold()`) | Section titles ("Waiting for you", "Machines"), sheet titles |
| Headline | `.headline` | The name of a row or card ("restart media sonarr", "Living room") |
| Body | `.body` | Text people read: reasons, chat, the voice line |
| Secondary | `.subheadline`, `Palette.secondary` | What explains a row: reason, subtitle, due |
| Meta | `.footnote`, `Palette.tertiary` | When, where from ("checked 2 min ago") |
| Data | `Typo.data(…)` (SF Mono) | **Numbers and ids only**: 3.10, 88%, 07:30, ab12, 2026-11-07T07:00 |

- Mono is for values, never for labels, dates in sentences, titles or buttons.
- No uppercase labels with tracking (the "terminal caption" look). Section titles are sentence case.
- No italics. Emphasis is weight or colour, not slant.
- Minimum 11 pt; prefer Regular, Medium, Semibold, Bold.

## 2. Space, not boxes: grouping

HIG: group related items with negative space, container shapes **or** separators; align things that belong together.

- Screen margin 16 pt (the system's), one column. Everything on a screen starts at the same leading edge.
- 8-pt grid: 4 inside a label stack, 8 between a label and its value, 12 between rows, 24 between sections,
  32 under the hero.
- **One container style**: `.panel()`: filled `Palette.surface`, corner radius 16, no border. Rows inside a panel
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
- Test on the smallest phone (5.4") and at AX text sizes: `scripts/phone-shots`, CI shots.

## Checklist for a screen

1. Count the type styles: only the roles in 1.
2. Squint: is there exactly one most important thing, at the top leading edge?
3. Count borders: zero. Count nested panels: zero.
4. Count colours: only status things are coloured, and each says why in words.
5. Leading edges: one line down the screen.
