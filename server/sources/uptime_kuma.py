"""Uptime Kuma: the monitors of one public status page as problems, plus one summary card.

Reads the status page's public JSON, the same two calls the status page itself makes. No API key and no login: only
the monitors you put on that status page are visible (a separate status page just for the bridge is fine).

    GET <url>/api/status-page/<slug>             config, incidents (2.x) or incident (1.x), publicGroupList
                                                 [{name, monitorList: [{id, name, type, url?,
                                                                        certExpiryDaysRemaining?}]}]
    GET <url>/api/status-page/heartbeat/<slug>   {"heartbeatList": {"<id>": [{status, time, msg, ping}, ...]},
                                                  "uptimeList": {"<id>_24": 0.998}}

Heartbeats come oldest first; the last one counts. Status: 0 down, 1 up, 2 pending, 3 maintenance.
Tested against the code of Uptime Kuma 2.5.9 and 1.23.16 (server/routers/status-page-router.js and the models it
uses); the recordings in server/recordings/uptime-kuma/ are made up in that shape. Kuma 1.23 never answers a slug
that does not exist (the request times out); 2.x answers 404 "Status Page Not Found".

Config:
    {"name": "Kuma", "type": "uptime-kuma", "url": "http://192.0.2.10:3001", "slug": "home"}
    optional: "slow_ms": 2000   a monitor that is up but answered slower than this is a warning (off by default)
              "cert_days": 14   a certificate that expires within this many days is a warning (needs "Show
                                Certificate Expiry" on the status page; 0 turns it off)
              "services": true  monitors with a public link become launcher entries (default false: the
                                status page shows its links to anyone, but the launcher is yours to fill)

What it gives:
    problems  down monitor: problem "Jellyfin: down"; pending (Kuma retries): warning "Jellyfin: pending";
              slow: warning "Jellyfin: slow (2300 ms)"; certificate: warning "Jellyfin: certificate expires in 5 d";
              a pinned incident: "danger" a problem, "warning" a warning, other styles nothing.
              Maintenance is not a problem.
    cards     one list card in Lab, "11 of 12 up", a row per monitor with its state and 24 h uptime
    services  the monitors the status page shows with a link (only with "services": true)
"""

import re

from . import SourceError, as_dict, as_list, as_text

SLUG_RE = re.compile(r"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$")   # Kuma's own slug rule
DOWN, UP, PENDING, MAINTENANCE = 0, 1, 2, 3
STATE = {DOWN: ("down", "red"), UP: ("up", "green"), PENDING: ("pending", "orange"),
         MAINTENANCE: ("maintenance", "gray")}


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required (the Uptime Kuma address, e.g. http://192.0.2.10:3001)")
    if not isinstance(cfg.get("slug"), str) or not SLUG_RE.fullmatch(cfg["slug"]):
        raise ValueError("slug is required: the status page's slug, the part after /status/ in its address")
    for key in ("slow_ms", "cert_days"):
        if key in cfg and (_number(cfg[key]) is None or cfg[key] < 0):
            raise ValueError("%s must be a number, at least 0" % key)
    if not isinstance(cfg.get("services", False), bool):
        raise ValueError("services must be true or false")


def _status(beat):
    s = as_dict(beat).get("status")
    return s if s in STATE and not isinstance(s, bool) else None


def collect(cfg, fetch):
    slug = cfg["slug"]
    page = fetch("/api/status-page/%s" % slug, ok=None)
    if page.status == 404:
        raise SourceError("status page %s not found" % slug)
    if not 200 <= page.status < 300:
        raise SourceError(str(page.status))
    page = as_dict(page.json())
    beats = as_dict(fetch.json("/api/status-page/heartbeat/%s" % slug))
    heartbeats = as_dict(beats.get("heartbeatList"))
    uptimes = as_dict(beats.get("uptimeList"))
    slow_ms = _number(cfg.get("slow_ms")) or 0
    cert_days = _number(cfg.get("cert_days"))
    cert_days = 14 if cert_days is None else cert_days

    problems, items, services, seen = [], [], [], set()
    counts = {"up": 0, "all": 0}
    for group in as_list(page.get("publicGroupList")):
        group = as_dict(group)
        group_name = as_text(group.get("name"))
        for mon in as_list(group.get("monitorList")):
            mon = as_dict(mon)
            mid, name = mon.get("id"), as_text(mon.get("name"))
            if isinstance(mid, bool) or not isinstance(mid, (int, str)) or as_text(mid) == "" or not name:
                continue
            mid = as_text(mid)
            if mid in seen:
                continue   # one monitor can sit in two groups; it counts once
            seen.add(mid)
            last = None
            for beat in reversed(as_list(heartbeats.get(mid))):
                if _status(beat) is not None:
                    last = as_dict(beat)
                    break
            status = _status(last) if last else None
            pid = "monitor-%s" % mid
            counts["all"] += 1
            if status is None:
                word, tint = "no data", "gray"
            else:
                word, tint = STATE[status]
            ping = _number(last.get("ping")) if last else None
            if status == DOWN:
                problems.append({"id": pid, "severity": "problem", "text": "%s: down" % name})
            elif status == PENDING:
                problems.append({"id": pid, "severity": "warning", "text": "%s: pending" % name})
            elif status == UP:
                counts["up"] += 1
                if slow_ms and ping is not None and ping > slow_ms:
                    word, tint = "slow", "orange"
                    problems.append({"id": pid, "severity": "warning",
                                     "text": "%s: slow (%d ms)" % (name, round(ping))})
            days = _number(mon.get("certExpiryDaysRemaining"))
            if cert_days and days is not None and days < cert_days and status != DOWN:
                problems.append({"id": "cert-%s" % mid, "severity": "warning",
                                 "text": "%s: certificate %s" % (name, "expired" if days <= 0 else
                                                                 "expires in %d d" % days)})
            item = {"title": name, "value": word, "tint": tint}
            uptime = _number(uptimes.get("%s_24" % mid))
            parts = [group_name] if group_name else []
            if uptime is not None and 0 <= uptime <= 1:
                parts.append("%s %% in 24 h" % _percent(uptime))
            if ping is not None and status == UP:
                parts.append("%d ms" % round(ping))
            if parts:
                item["subtitle"] = " · ".join(parts)
            items.append(item)
            url = as_text(mon.get("url"))
            if cfg.get("services", False) and url.startswith(("http://", "https://")):
                services.append({"name": name, "url": url, "icon": "globe"})

    incidents = as_list(page.get("incidents")) or [page.get("incident")]
    for inc in incidents:
        inc = as_dict(inc)
        severity = {"danger": "problem", "warning": "warning"}.get(inc.get("style"))
        title = as_text(inc.get("title")).strip()
        if severity and title and inc.get("active", True) is not False:
            problems.append({"id": "incident-%s" % as_text(inc.get("id"), title), "severity": severity,
                             "text": "%s: %s" % (cfg["name"], title[:100])})

    cards = []
    if items:
        title = as_text(as_dict(page.get("config")).get("title")).strip() or cfg["name"]
        cards.append({"id": "monitors", "title": title, "subtitle": "%d of %d up" % (counts["up"], counts["all"]),
                      "icon": "waveform.path.ecg", "style": "list", "place": "lab", "items": items})
    return {"problems": problems, "cards": cards, "services": services}


def _percent(fraction):
    """0.99812 -> "99.81", 1 -> "100"."""
    text = "%.2f" % (fraction * 100)
    return text.rstrip("0").rstrip(".") if "." in text else text
