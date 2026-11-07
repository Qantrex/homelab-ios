"""Shared by the ad blockers (pihole, adguard): the `dns` card, the `dns-top` card and the opt-in `dns-pause` action.

Not a source type (the leading _ keeps it out of the type list). The card has the shape of the `dns` card in
docs/API.md#cards-for-lab-place: Queries, Blocked, Blocking. With `"actions": {"pause": [5, 15, 30]}` (minutes) the
source offers the action `dns-pause` through the bridge's SourceActions, with the arguments "<name>:5", "<name>:15",
"<name>:30" and "<name>:on" (resume), and the Blocking row gets a "Pause 5 min" (or "Resume") button.
"""

from . import SourceError, as_dict, as_list, as_text

ACTION = "dns-pause"   # the name the owner's agent and the app's demo use too
ACTIONS = {ACTION: {"label": "Pause ad blocking", "icon": "shield.slash", "part": "For",
                    "hint": "Blocking comes back on by itself."}}
MAX_PAUSE = 240   # minutes


def check_actions(cfg):
    """`actions`: missing, or {"pause": [minutes, ...]} with 1 to 240 minutes each."""
    actions = cfg.get("actions")
    if actions is None:
        return
    if not isinstance(actions, dict) or set(actions) - {"pause"}:
        raise ValueError('actions must be {"pause": [5, 15, 30]} (minutes)')
    mins = actions.get("pause", [])
    if not isinstance(mins, list) or not all(isinstance(m, int) and not isinstance(m, bool) and 1 <= m <= MAX_PAUSE
                                             for m in mins):
        raise ValueError("actions.pause must be a list of minutes from 1 to %d" % MAX_PAUSE)


def pauses(cfg):
    """The pause lengths the config lists, in minutes, shortest first."""
    return sorted({m for m in as_list(as_dict(cfg.get("actions")).get("pause")) if isinstance(m, int)})


def allowed(cfg):
    """What the config lets the app do: each listed pause, and resume once any pause is listed."""
    mins = pauses(cfg)
    if not mins:
        return []
    return [{"action": ACTION, "item": str(m), "label": minutes(m * 60)} for m in mins] + \
        [{"action": ACTION, "item": "on", "label": "Resume"}]


def pause_seconds(action, item):
    """The pause an allowed item asks for, in seconds; None to resume. SourceError for anything else."""
    if action != ACTION or not (item == "on" or item.isdigit()):
        raise SourceError("not allowed")
    return None if item == "on" else int(item) * 60


def number(value):
    """An int or float from upstream JSON, else None (bools are not numbers)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def count(n):
    """812, 23.4k, 1.2M."""
    if n is None:
        return "?"
    n = float(n)
    for size, unit in ((1e6, "M"), (1e3, "k")):
        if abs(n) >= size:
            return ("%.1f" % (n / size)).replace(".0", "") + unit
    return "%d" % n


def minutes(seconds):
    """A short duration: "4 min", "1 h 5 min"."""
    m = max(1, int(round(seconds / 60.0)))
    return "%d min" % m if m < 60 else ("%d h" % (m // 60) + (" %d min" % (m % 60) if m % 60 else ""))


def result(cfg, total, blocked, percent, state, timer=None, window=None, top=()):
    """The source's result: the `dns` card, `dns-top` when there are blocked domains, and a warning when blocking is
    off for good or broken. state: "on", "off", "failed" or "unknown"; timer: seconds until it changes by itself."""
    name = cfg["name"]
    if percent is None and total and blocked is not None:
        percent = 100.0 * blocked / total
    queries = {"title": "Queries", "value": count(total)}
    if window:
        queries["subtitle"] = window
    blocking = {"title": "Blocking"}
    problems = []
    mins = pauses(cfg)
    if state == "on":
        blocking["value"] = "on"
        action = {"name": ACTION, "label": "Pause %s" % minutes(mins[0] * 60), "arg": "%s:%d" % (name, mins[0])} \
            if mins else None
    else:
        paused = state == "off" and timer
        blocking["value"] = ("off · %s" % minutes(timer)) if paused else state
        blocking["tint"] = "orange" if state == "off" else "red"
        action = {"name": ACTION, "label": "Resume", "arg": "%s:on" % name} if mins else None
        if not paused:
            why = "ad blocking is off" if state == "off" else "ad blocking %s" % (
                "failed" if state == "failed" else "is in an unknown state")
            problems.append({"id": "blocking", "severity": "warning", "text": "%s: %s" % (name, why)})
    if action:
        blocking["action"] = action   # the bridge keeps it only when the arg is on the source's list
    cards = [{"id": "dns", "title": name, "icon": "shield", "style": "metrics", "place": "lab",
              "items": [queries, {"title": "Blocked", "value": "?" if percent is None else "%.1f %%" % percent},
                        blocking]}]
    rows = [{"title": d, "value": count(c)} for d, c in top if d]
    if rows:
        cards.append({"id": "dns-top", "title": "Top blocked", "subtitle": name, "icon": "hand.raised",
                      "style": "list", "place": "lab", "items": rows})
    return {"problems": problems, "cards": cards}


def top_pairs(entries, limit, single=False):
    """[(domain, count)], at most `limit`, from [{"domain": d, "count": n}] (Pi-hole) or, with single=True,
    [{d: n}] (AdGuard)."""
    out = []
    for e in as_list(entries):
        e = as_dict(e)
        if single and len(e) == 1:
            d, n = next(iter(e.items()))
            d, n = as_text(d), number(n)
        elif not single:
            d, n = as_text(e.get("domain")), number(e.get("count"))
        else:
            continue
        if d and n is not None:
            out.append((d, n))
        if len(out) >= limit:
            break
    return out
