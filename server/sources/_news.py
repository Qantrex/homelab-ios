"""The News module's shared parts (not a source type; the rss source and the reference server use it): the feed list
of the config, the catalog (GET /api/v1/news/sources), the user's prefs (validate, load, save) and URL helpers. It
is the one place that touches files (the prefs file in the state dir) and parses URLs, so server/sources/rss.py can
keep the source rules (fetch only, no os, no open).
"""

import json
import os
import re
import tempfile
import threading
import urllib.parse

from . import SECRET_QUERY, as_list

MAX_FEEDS = 30
DEFAULT_MAX = 8
DEFAULT_WINDOW_H = 24
DEFAULT_BYTES = 2 * 1024 * 1024
MAX_BYTES = 8 * 1024 * 1024
COUNTS = (3, 5, 8)
WINDOWS = (12, 24, 48)
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,23}$")
COUNTRY_RE = re.compile(r"^[a-z]{2,8}$")
TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9 _-]{0,23}$")
FEED_KEYS = ("id", "name", "url", "country", "topic")
COUNTRY_NAMES = {"at": "Austria", "de": "Germany", "ch": "Switzerland", "gb": "United Kingdom", "us": "United States",
                 "fr": "France", "it": "Italy", "es": "Spain", "nl": "Netherlands", "int": "International"}
PREFS_FILE = "news-prefs.json"
_TRACKING = re.compile(r"(?i)^(utm_[a-z]+|fbclid|gclid|mc_[a-z]+|ref|ref_src|at_medium|at_campaign|wt_mc|cmp)$")

_LOCK = threading.Lock()   # one writer of the prefs file at a time


def feeds_of(cfg):
    return [f for f in as_list(cfg.get("feeds")) if isinstance(f, dict)]


def check_config(cfg):
    """ValueError for a bad rss source config (called by rss.check)."""
    feeds = cfg.get("feeds")
    if not isinstance(feeds, list) or not feeds:
        raise ValueError("feeds must be a list with at least one feed")
    if len(feeds) > MAX_FEEDS:
        raise ValueError("at most %d feeds" % MAX_FEEDS)
    seen = set()
    for i, f in enumerate(feeds):
        where = "feeds[%d]" % i
        if not isinstance(f, dict):
            raise ValueError("%s must be an object" % where)
        for k in f:
            if k not in FEED_KEYS:
                raise ValueError("%s: unknown key %r (known: %s)" % (where, k, ", ".join(FEED_KEYS)))
        fid = f.get("id")
        if not isinstance(fid, str) or not ID_RE.fullmatch(fid):
            raise ValueError("%s.id must be 1-24 of a-z 0-9 - _, got %r" % (where, fid))
        if fid in seen:
            raise ValueError("%s: duplicate id %r" % (where, fid))
        seen.add(fid)
        if not isinstance(f.get("name"), str) or not f["name"].strip() or len(f["name"]) > 40:
            raise ValueError("%s.name must be 1-40 characters" % where)
        url = f.get("url")
        u = urllib.parse.urlsplit(url) if isinstance(url, str) else None
        if u is None or u.scheme not in ("http", "https") or not u.hostname:
            raise ValueError("%s.url must be an http:// or https:// URL" % where)
        if u.username or u.password or SECRET_QUERY.search(u.query):
            raise ValueError("%s.url must not hold a user, password or key" % where)
        country, topic = f.get("country", "int"), f.get("topic", "general")
        if not isinstance(country, str) or not COUNTRY_RE.fullmatch(country):
            raise ValueError("%s.country must be two letters (at, de, gb) or int" % where)
        if not isinstance(topic, str) or not TOPIC_RE.fullmatch(topic):
            raise ValueError("%s.topic must be a short lower-case word (general, tech, ...)" % where)
    mx = cfg.get("max", DEFAULT_MAX)
    if isinstance(mx, bool) or not isinstance(mx, int) or not 1 <= mx <= 20:
        raise ValueError("max must be a whole number from 1 to 20")
    wh = cfg.get("window_h", DEFAULT_WINDOW_H)
    if isinstance(wh, bool) or not isinstance(wh, int) or not 1 <= wh <= 168:
        raise ValueError("window_h must be a whole number of hours from 1 to 168")
    mb = cfg.get("max_bytes", DEFAULT_BYTES)
    if isinstance(mb, bool) or not isinstance(mb, int) or not 1024 <= mb <= MAX_BYTES:
        raise ValueError("max_bytes must be a whole number from 1024 to %d" % MAX_BYTES)


def normal_feed(f):
    """A feed of the config with its defaults filled."""
    return {"id": f["id"], "name": f["name"].strip(), "url": f["url"], "country": f.get("country", "int"),
            "topic": f.get("topic", "general")}


# --------------------------------------------------------------------------------------------- prefs

def catalog(cfg):
    """What GET /api/v1/news/sources lists: {"countries": [...], "sources": [...]} from the config alone."""
    feeds = [normal_feed(f) for f in feeds_of(cfg)]
    countries, seen = [], set()
    for f in feeds:
        if f["country"] not in seen:
            seen.add(f["country"])
            countries.append({"id": f["country"], "name": COUNTRY_NAMES.get(f["country"], f["country"].upper())})
    return {"countries": countries,
            "sources": [{"id": f["id"], "name": f["name"], "country": f["country"], "topic": f["topic"]}
                        for f in feeds]}


def default_prefs(cfg):
    feeds = [normal_feed(f) for f in feeds_of(cfg)]
    window = cfg.get("window_h", DEFAULT_WINDOW_H)
    return {"enabled": True, "country": feeds[0]["country"] if feeds else "int", "sources": [f["id"] for f in feeds],
            "summary": False, "count": 5,
            "window_h": window if window in WINDOWS else DEFAULT_WINDOW_H}


def validate_prefs(cfg, body, current=None):
    """The prefs a PUT stores, from the body (a full prefs object; a missing key keeps `current`/the default).
    ValueError with a short text for a malformed body. Unknown source ids are dropped, `summary` is false (this
    server cannot summarise)."""
    if not isinstance(body, dict):
        raise ValueError("body must be a JSON object")
    base = dict(current or default_prefs(cfg))
    cat = catalog(cfg)

    def pick(key, kind, text):
        if key not in body:
            return base[key]
        if not isinstance(body[key], kind) or (kind is int and isinstance(body[key], bool)):
            raise ValueError("%s must be %s" % (key, text))
        return body[key]

    out = {"enabled": pick("enabled", bool, "true or false")}
    out["country"] = pick("country", str, "a country id")
    if out["country"] not in {c["id"] for c in cat["countries"]}:
        raise ValueError("country is not one of the countries of GET /api/v1/news/sources")
    sources = pick("sources", list, "a list of source ids")
    if not all(isinstance(s, str) for s in sources):
        raise ValueError("sources must be a list of source ids")
    out["sources"] = [s["id"] for s in cat["sources"] if s["id"] in set(sources)]   # unknown dropped, no repeats
    pick("summary", bool, "true or false")
    out["summary"] = False
    out["count"] = pick("count", int, "3, 5 or 8")
    if out["count"] not in COUNTS:
        raise ValueError("count must be 3, 5 or 8")
    out["window_h"] = pick("window_h", int, "12, 24 or 48")
    if out["window_h"] not in WINDOWS:
        raise ValueError("window_h must be 12, 24 or 48")
    return out


def load_prefs(cfg, path):
    """The stored prefs (re-validated), else the defaults. A missing or broken file is the defaults, never an error."""
    if path:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            return validate_prefs(cfg, data, default_prefs(cfg))
        except (OSError, ValueError):
            pass
    return default_prefs(cfg)


def save_prefs(path, prefs):
    """Write the prefs file atomically (0600, in the state dir)."""
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    with _LOCK:
        fd, tmp = tempfile.mkstemp(prefix=".news-prefs-", dir=folder)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(prefs, fh, indent=2)
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


# --------------------------------------------------------------------------------------------- urls

def resolve_url(base, url):
    """`url` made absolute against the feed's address."""
    try:
        return urllib.parse.urljoin(base, url) if base else url
    except ValueError:
        return ""


def url_key(url):
    """The same article under different tracking parameters, www or a trailing slash is the same key."""
    try:
        u = urllib.parse.urlsplit(url)
        query = sorted((k, v) for k, v in urllib.parse.parse_qsl(u.query, keep_blank_values=True)
                       if not _TRACKING.match(k))
        host = (u.hostname or "").lower()
        host = host[4:] if host.startswith("www.") else host
        return "%s%s?%s" % (host, u.path.rstrip("/"), urllib.parse.urlencode(query))
    except ValueError:
        return url
