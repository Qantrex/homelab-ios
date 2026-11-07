"""Sonarr: health checks as problems, the download queue as a Lab card with progress, the episodes of the next days
as a countdown card. API v3 (also served by Sonarr v4); recordings (recordings/sonarr/) have the shapes of Sonarr
v4.0.20 (src/Sonarr.Api.V3/openapi.json).

Upstream (header X-Api-Key on every request, read-only):
    GET /api/v3/health
    GET /api/v3/queue?page=1&pageSize=10&includeSeries=true&includeEpisode=true
    GET /api/v3/calendar?start=2026-11-07&end=2026-11-14&includeSeries=true   (monitored episodes only)

Config:
    {"name": "Sonarr", "type": "sonarr", "url": "http://192.0.2.30:8989", "key_env": "SONARR_KEY",
     "queue": 10, "calendar_days": 7}

key_env: the API key (Settings > General > Security). `queue`: rows in the queue card (0: no queue request, no
card). `calendar_days`: how far ahead the countdown looks (0: no calendar). Episodes already downloaded are left out.
Air times are converted to the bridge's local time.
"""

from . import as_dict, as_list, as_text
from . import _arr

check = _arr.check


def _episode_code(ep):
    s, e = _arr.number(ep.get("seasonNumber")), _arr.number(ep.get("episodeNumber"))
    return "S%02dE%02d" % (s, e) if s is not None and e is not None else ""


def _row_title(r):
    series = as_text(as_dict(r.get("series")).get("title"))
    code = _episode_code(as_dict(r.get("episode")))
    return ("%s %s" % (series, code)).strip() if series else ""


def collect(cfg, fetch):
    h = {"X-Api-Key": fetch.secret()}
    problems = _arr.health(cfg, fetch.json("/api/v3/health", headers=h))
    cards = []
    rows = cfg.get("queue", 10)
    if rows:
        data = fetch.json("/api/v3/queue?page=1&pageSize=%d&includeSeries=true&includeEpisode=true" % rows,
                          headers=h)
        card, stuck = _arr.queue(cfg, data, _row_title, "tv")
        cards.append(card)
        problems += stuck
    if cfg.get("calendar_days", 7):
        items = []
        for ep in as_list(fetch.json("/api/v3/calendar?%s&includeSeries=true" % _arr.window(cfg), headers=h)):
            ep = as_dict(ep)
            series = as_text(as_dict(ep.get("series")).get("title"))
            due = _arr.local_time(ep.get("airDateUtc")) or _arr.day(ep.get("airDate"))
            if not series or not due or ep.get("hasFile") is True:
                continue
            sub = " · ".join(x for x in (_episode_code(ep), as_text(ep.get("title"))) if x)
            item = {"title": series, "due": due}
            if sub:
                item["subtitle"] = sub
            items.append(item)
        cards += _arr.calendar_card(cfg, items)
    return {"problems": problems, "cards": cards}
