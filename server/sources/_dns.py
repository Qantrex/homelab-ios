"""Shared by the ad blockers (pihole, adguard): the `dns` card, the `dns-top` card and the opt-in `pause` action.

Not a source type (the leading _ keeps it out of the type list). The card has the shape of the `dns` card in
docs/API.md#cards-for-lab-place: Queries, Blocked, Blocking (with a "Pause 5 min" button only when the config lists
`"actions": ["pause"]`).
"""

from . import as_dict, as_list, as_text

# arg -> seconds of the pause (None: blocking back on now)
PAUSE = {"5": 300, "15": 900, "30": 1800, "on": None}


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


def pause_spec(cfg):
    """The ActionSpec of `pause` for GET /actions (the bridge adds the name)."""
    return {"label": "Pause %s" % cfg["name"], "icon": "shield.slash",
            "hint": "Ad blocking comes back on by itself.",
            "arg": [{"label": "Pause", "parts": [{"kind": "choice", "label": "For", "options": [
                        {"value": "5", "label": "5 min"}, {"value": "15", "label": "15 min"},
                        {"value": "30", "label": "30 min"}]}]},
                    {"label": "Resume now", "parts": [{"kind": "choice", "label": "Do", "options": [
                        {"value": "on", "label": "Resume"}]}]}]}


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
    if state == "on":
        blocking["value"] = "on"
        action = {"name": "pause", "label": "Pause 5 min", "arg": "5"}
    else:
        paused = state == "off" and timer
        blocking["value"] = ("off · %s" % minutes(timer)) if paused else state
        blocking["tint"] = "orange" if state == "off" else "red"
        action = {"name": "pause", "label": "Resume", "arg": "on"}
        if not paused:
            why = "ad blocking is off" if state == "off" else "ad blocking %s" % (
                "failed" if state == "failed" else "is in an unknown state")
            problems.append({"id": "blocking", "severity": "warning", "text": "%s: %s" % (name, why)})
    if "pause" in (cfg.get("actions") or []):
        blocking["action"] = action
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
