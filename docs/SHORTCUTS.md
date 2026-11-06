# Links, Shortcuts and quick actions

Homelab has no Siri or Shortcuts actions of its own (xtool can't build App Intents). Instead, every place in the app
has a `homelab://` link, and an action's form can be **filled in by its link**. The Shortcuts action **Open URL**
opens such a link, so a shortcut, a Home-screen icon, an NFC tag or a push can start an action with one tap. The
app always shows the filled form and asks once before anything runs: a link only types for you.

## Links

| Link | Opens |
|---|---|
| `homelab://today`, `homelab://actions`, `homelab://chat`, `homelab://lab`, `homelab://settings` | That tab |
| `homelab://scan` | Actions with the document camera (server feature `documents`) |
| `homelab://lab/<host-id>` | A host's details |
| `homelab://actions/<name>` | That action's form, as its Start tile opens it |
| `homelab://actions/<name>?arg=…&<field>=…` | That form, **filled in** |

`<name>` is the action's name from `GET /actions` (`todo-add`, `wake-set`, …; with Settings → Today → Overkill each
Start tile shows it). A form waits until the server's list is there; picking another tab by hand drops it,
and a newer link replaces it.

## Filling in a form

| In the link | Fills |
|---|---|
| `arg=<argument>` | The argument, when it fits one of the action's variants: `arg=2026-11-07T07:30` picks "Wake me" with that day and time, `arg=2026-11-07:off` picks "No wake-up". An argument that fits none is ignored |
| `<field>=<value>` | The payload field with that name (`summary=Milk`). A choice field only takes one of its option *values* (`list=shopping`, not `list=Shopping`) |

Rules the app keeps:

- **Hidden fields never come from a link.** A to-do's `uid` and the like only come from the server's own cards.
- Card-only actions (`"start": false`: tick off a to-do, parcel delivered) don't open from a link at all.
- Unknown names, empty values and values that aren't an option are left out; the form starts with its usual default
  there. Values are trimmed; for a repeated name the first one counts. At most 32 query items are read.
- Encode the values: a space is `%20`, `&` is `%26`, `+` is `%2B` (a `+` stays a plus sign, it is not a space). In
  Shortcuts, put the text through **URL Encode** first.
- Nothing runs without your tap on the confirm button. With the app lock on, Face ID comes first.

## Examples

With the actions of the demo and the fixtures (`Sources/HomelabKit/Fixtures/actions.json`):

| What | Link |
|---|---|
| Add a to-do | `homelab://actions/todo-add?summary=Call%20the%20dentist` |
| Add to the shopping list | `homelab://actions/todo-add?summary=Milk&list=shopping` |
| A to-do with a time (the phone reminds you) | `homelab://actions/todo-add?summary=Hand%20in%20project&due=2026-11-09T08:00` |
| Wake me at 07:30 on a day | `homelab://actions/wake-set?arg=2026-11-07T07:30` |
| No wake-up on a day | `homelab://actions/wake-set?arg=2026-11-07:off` |
| Lamps on | `homelab://actions/ha-control?arg=lamps-on` |
| Bike tomorrow | `homelab://actions/commute-mode?arg=2026-11-07:bike` |
| An event | `homelab://actions/calendar-add?title=Dinner&start=2026-11-08T19:00&location=Home` |

## Shortcuts recipes

**Add a to-do by voice** ("Hey Siri, To-do"):

1. Shortcuts → + → **Dictate Text** (or **Ask for Input**, Text).
2. **URL Encode** the Dictated Text.
3. **Text**: `homelab://actions/todo-add?summary=` followed by the URL Encoded Text variable.
4. **Open URLs** with that Text.
5. Name the shortcut "To-do". Siri runs it, Homelab opens the filled form, you tap Run.

**Wake-up for tomorrow at a time you pick:**

1. **Ask for Input**, Date and Time ("Wake me at").
2. **Adjust Date**: add 1 day to Current Date; **Format Date** custom `yyyy-MM-dd` → the day.
3. **Format Date** of the input, custom `HH:mm` → the time.
4. **Text**: `homelab://actions/wake-set?arg=` day `T` time, then **Open URLs**.

**One tap on the Home screen:** a shortcut with only **Open URLs** (`homelab://actions/ha-control?arg=lamps-on`),
then Share → Add to Home Screen.

## Home-screen quick actions

Long-press the Homelab icon:

- **Scan document** (always; it opens nothing on a server without `documents`).
- Up to three of the shown server's Start actions: the ones you started most often (counted on this phone, in the
  App Group; ties go to the most recent, then the server's order). Before you start anything they are the server's
  first three. Each opens `homelab://actions/<name>` (the plain form, no values).

They update after each refresh (in the app and in the background), after you start an action, and when you switch
servers. The count keeps only action names, never what you typed.

## Approve and Deny on notifications

With Settings → Notifications → "New actions to approve" on, the background refresh notifies about a new proposal. Long-press
(or pull down) the notification for **Approve** and **Deny** (red), only the buttons the server offers for it; "Always"
stays in the app. Both ask for the phone to be unlocked first. The app presses the button in the background (it finds
the signed button again in its data, never keeps it in the notification) and then posts a short result: "lab:
approved restart server jellyfin" with the server's answer, or why it didn't go through ("No longer valid" when it was
answered elsewhere). Tapping a notification still opens Actions.

With the **app lock** on the buttons stay: the notification names the action, and Approve or Deny runs only after
Face ID or the passcode (iOS asks for it before the press). iOS hides notification previews on the locked lock screen
by default (Settings → Notifications → Show Previews: When Unlocked), so the name shows once Face ID has recognised you;
with "Always" it would show on the locked screen too. The result notification then only says "Approved. Open the app
for the answer." Other notifications stay vague with the lock on ("Something needs a look.").

Notifications come only as often as iOS runs the background refresh (every 20 minutes at best, often less).
