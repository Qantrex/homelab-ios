"""Shared by sonarr and radarr (the v3 API both speak). Not a source type (the leading _ keeps it out of the list).

    GET /api/v3/health      header X-Api-Key   -> [{"source", "type": ok|notice|warning|error, "message", "wikiUrl"}]
    GET /api/v3/queue?page=1&pageSize=N&...    -> {"totalRecords", "records": [{"id", "title", "size", "sizeleft",
                                                   "timeleft", "status", "trackedDownloadStatus", ...}]}
    GET /api/v3/calendar?start=DAY&end=DAY&... -> episodes (Sonarr) or movies (Radarr)

Health errors become problems, warnings warnings; notices are left out. The queue is a `list` card in Lab, each row
with `progress`; a download that needs a hand (import blocked, failed) is also a warning. What comes in the next
`calendar_days` days is a `countdown` card on Today.
"""

import datetime
import hashlib
import re

from . import as_dict, as_list, as_text

DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

TRACKED = {"importBlocked": "Import blocked", "importPending": "Waiting to import", "importing": "Importing",
           "imported": "Imported", "failedPending": "Failed", "failed": "Failed", "ignored": "Ignored"}
STATUS = {"queued": "Queued", "paused": "Paused", "downloading": "Downloading", "completed": "Downloaded",
          "failed": "Failed", "warning": "Warning", "delay": "Delayed", "downloadClientUnavailable":
          "Download client unavailable", "fallback": "Fallback", "unknown": "Unknown"}


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required")
    if not cfg.get("key_env"):
        raise ValueError("key_env is required (the env variable with the API key: Settings > General > Security)")
    for key, default, top in (("queue", 10, 50), ("calendar_days", 7, 60)):
        value = cfg.get(key, default)
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= top:
            raise ValueError("%s must be a whole number from 0 to %d" % (key, top))


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def timeleft(text):
    """"00:12:30" -> "12 min", "1.02:03:04" -> "1 d 2 h", "02:10:00" -> "2 h 10 min"; else ""."""
    text = as_text(text)
    days = 0
    if "." in text.split(":")[0]:
        d, _, text = text.partition(".")
        days = int(d) if d.isdigit() else 0
    parts = text.split(":")
    if len(parts) != 3 or not all(p.split(".")[0].isdigit() for p in parts):
        return ""
    h, m = int(parts[0]), int(parts[1])
    if days:
        return "%d d %d h" % (days, h) if h else "%d d" % days
    if h:
        return "%d h %d min" % (h, m) if m else "%d h" % h
    return "%d min" % max(m, 1)


def local_time(text):
    """An upstream UTC time ("2026-11-08T02:00:00Z") as local time without a zone ("2026-11-08T03:00"), the way
    `due` wants it. None when it is not a time."""
    text = as_text(text)
    try:
        t = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t.astimezone().strftime("%Y-%m-%dT%H:%M")


def day(text):
    """"2026-11-10T00:00:00Z" -> "2026-11-10" (a release day is a day, not a moment); None when it isn't one."""
    text = as_text(text)[:10]
    if not DAY_RE.fullmatch(text):
        return None
    try:
        datetime.date.fromisoformat(text)
    except ValueError:
        return None
    return text


def health(cfg, entries):
    problems, seen = [], set()
    for h in as_list(entries):
        h = as_dict(h)
        kind, message = as_text(h.get("type")), as_text(h.get("message")).strip()
        if kind not in ("error", "warning") or not message:
            continue
        source = as_text(h.get("source"), "check") or "check"
        pid = "health-" + source
        if pid in seen:
            pid += "-" + hashlib.sha256(message.encode("utf-8")).hexdigest()[:8]
        seen.add(pid)
        problems.append({"id": pid, "severity": "problem" if kind == "error" else "warning",
                         "text": "%s: %s" % (cfg["name"], message)})
    return problems


def queue(cfg, data, title_of, icon):
    """The queue card and a warning for each download that needs a hand. title_of(record) names a row."""
    data = as_dict(data)
    items, problems = [], []
    for r in as_list(data.get("records")):
        r = as_dict(r)
        title = title_of(r) or as_text(r.get("title"))
        if not title:
            continue
        status, tracked = as_text(r.get("status")), as_text(r.get("trackedDownloadState"))
        health_ = as_text(r.get("trackedDownloadStatus"))
        words = TRACKED.get(tracked) if tracked and tracked != "downloading" else None
        words = words or STATUS.get(status) or "Queued"
        reason = as_text(r.get("errorMessage"))
        for m in as_list(r.get("statusMessages")):
            for line in as_list(as_dict(m).get("messages")):
                reason = reason or as_text(line)
        item = {"title": title, "subtitle": "%s: %s" % (words, reason) if reason else words}
        size, left = number(r.get("size")), number(r.get("sizeleft"))
        if size and size > 0 and left is not None:
            item["progress"] = round(min(1.0, max(0.0, 1 - left / size)), 3)
        when = timeleft(r.get("timeleft")) if status == "downloading" else ""
        if when:
            item["value"] = when
        elif "progress" in item:
            item["value"] = "%d %%" % int(item["progress"] * 100)
        if health_ == "error" or status == "failed":
            item["tint"] = "red"
        elif health_ == "warning" or status in ("warning", "downloadClientUnavailable"):
            item["tint"] = "orange"
        if "tint" in item and r.get("id") is not None:
            problems.append({"id": "queue-%s" % as_text(r.get("id")), "severity": "warning",
                             "text": "%s: %s: %s" % (cfg["name"], title, item["subtitle"])})
        items.append(item)
    total = number(data.get("totalRecords"))
    total = int(total) if total is not None and total >= len(items) else len(items)
    card = {"id": "queue", "title": "%s queue" % cfg["name"], "icon": icon, "style": "list", "place": "lab",
            "subtitle": ("%d in the queue" % total) if total else "Nothing in the queue", "items": items}
    return card, problems


def calendar_card(cfg, items):
    if not items:
        return []
    items = sorted(items, key=lambda i: i["due"])[:10]
    return [{"id": "calendar", "title": "%s: coming up" % cfg["name"], "icon": "calendar", "style": "countdown",
             "items": items}]


def today():
    """The bridge's local day (tests pin it)."""
    return datetime.date.today()


def span(cfg):
    """(first day, last day) of the calendar: today and the next calendar_days days, as "YYYY-MM-DD"."""
    start = today()
    return start.isoformat(), (start + datetime.timedelta(days=cfg.get("calendar_days", 7))).isoformat()


def window(cfg):
    """The calendar query for span(cfg)."""
    return "start=%s&end=%s" % span(cfg)
