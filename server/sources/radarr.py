"""Radarr: health checks as problems, the download queue as a Lab card with progress, the releases of the next days
(digital, disc or in cinemas) as a countdown card. API v3; recordings (recordings/radarr/) have the shapes of Radarr
v6.4.4 (src/Radarr.Api.V3/openapi.json).

Upstream (header X-Api-Key on every request, read-only):
    GET /api/v3/health
    GET /api/v3/queue?page=1&pageSize=10&includeMovie=true
    GET /api/v3/calendar?start=2026-11-07&end=2026-11-14   (monitored movies only)

Config:
    {"name": "Radarr", "type": "radarr", "url": "http://192.0.2.31:7878", "key_env": "RADARR_KEY",
     "queue": 10, "calendar_days": 7}

key_env: the API key (Settings > General > Security). `queue`: rows in the queue card (0: no queue request, no
card). `calendar_days`: how far ahead the countdown looks (0: no calendar). Movies already downloaded are left out;
each movie shows its first release in the window, digital first when two fall on one day.
"""

from . import as_dict, as_list, as_text
from . import _arr

check = _arr.check

RELEASES = (("digitalRelease", "Digital release"), ("physicalRelease", "Disc release"), ("inCinemas", "In cinemas"))


def _row_title(r):
    movie = as_dict(r.get("movie"))
    title, year = as_text(movie.get("title")), _arr.number(movie.get("year"))
    return "%s (%d)" % (title, year) if title and year else title


def collect(cfg, fetch):
    h = {"X-Api-Key": fetch.secret()}
    problems = _arr.health(cfg, fetch.json("/api/v3/health", headers=h))
    cards = []
    rows = cfg.get("queue", 10)
    if rows:
        data = fetch.json("/api/v3/queue?page=1&pageSize=%d&includeMovie=true" % rows, headers=h)
        card, stuck = _arr.queue(cfg, data, _row_title, "film")
        cards.append(card)
        problems += stuck
    if cfg.get("calendar_days", 7):
        start, end = _arr.span(cfg)
        items = []
        for m in as_list(fetch.json("/api/v3/calendar?%s" % _arr.window(cfg), headers=h)):
            m = as_dict(m)
            title = as_text(m.get("title"))
            if not title or m.get("hasFile") is True:
                continue
            found = sorted((d, i, label) for i, (key, label) in enumerate(RELEASES)
                           for d in [_arr.day(m.get(key))] if d and start <= d <= end)
            if found:
                items.append({"title": title, "subtitle": found[0][2], "due": found[0][0]})
        cards += _arr.calendar_card(cfg, items)
    return {"problems": problems, "cards": cards}
