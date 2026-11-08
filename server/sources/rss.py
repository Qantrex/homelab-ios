"""News from RSS and Atom feeds: headlines only (no summary, no LLM, never an article body or an image).

Upstream: public feeds, plain GET, no key. RSS 2.0, RSS 1.0 (RDF, ORF) and Atom are read; the rest is skipped.

Config (at most one rss source; it is the News module of the app, docs/BRIDGE.md#news):
    {"name": "News", "type": "rss", "max": 8, "window_h": 24, "feeds": [
      {"id": "orf", "name": "ORF", "url": "https://rss.orf.at/news.xml", "country": "at", "topic": "general"},
      {"id": "heise", "name": "heise", "url": "https://www.heise.de/rss/heise-atom.xml", "country": "de",
       "topic": "tech"}]}

    feeds[].id        short id (a-z, 0-9, -, _), unique; the app's source toggles and the `source:` tag
    feeds[].name      shown name ("ORF · 2 h")
    feeds[].url       http(s) address of the feed itself (redirects are not followed: give the final address)
    feeds[].country   two letters ("at", "de", "gb") or "int" for international; default "int"
    feeds[].topic     "general", "tech", ... (a word); default "general"
    max               most items on the card, default 8 (the app's count 3, 5 or 8 can only lower it)
    window_h          default window in hours, default 24 (the app's choice 12, 24 or 48 overrides it)
    max_bytes         largest feed answer read, default 2 MB (never above 8 MB)

What it gives: one list card `news` on Today (its id is not prefixed with the source name, the app looks for
exactly this id), items "<headline>" / "<Source> · <age>" with the article link, `published` (the feed's date as UTC
ISO 8601, "2026-11-08T11:20:00Z"; the app sorts by it; no summary, no title_de) and the tags source:, country:,
topic:. Only the feeds the user picked in the app (GET/PUT /api/v1/news/..., prefs in the state dir) are read. Items
older than the window, without a date, or without an http(s) link are skipped; the same article (same address after
removing tracking parameters, or a near-identical headline) is shown once; one feed does not fill the whole card.
One feed that fails (timeout, 5xx, junk, too large) is skipped and is a warning; when every picked feed fails the
source fails (one warning, no card, never a stale card).

Hostile feeds: a DOCTYPE or ENTITY declaration is refused (no entity expansion, no external entities), the answer is
capped in size, at most MAX_ITEMS items per feed are read, titles are cut to plain text (tags and control characters
removed, URLs masked) and links with a user, password or key in them are dropped.
"""

import concurrent.futures
import datetime
import difflib
import email.utils
import html
import math
import re
import xml.etree.ElementTree as ET

from . import SourceError, as_list, link_ok, plain_text, short_error
from ._news import (COUNTS, DEFAULT_BYTES, DEFAULT_MAX, MAX_BYTES, catalog, check_config, default_prefs,  # noqa: F401
                    feeds_of, load_prefs, normal_feed, resolve_url, save_prefs, url_key, validate_prefs)

MAX_ITEMS = 100            # items read per feed
FEED_TIMEOUT = 8.0         # seconds for one feed; the source's own `timeout` can only make it shorter
HEADLINE_LEN = 160
SIMILAR = 0.9              # headlines at least this alike are the same story
ACCEPT = "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.5"

_TAG_RE = re.compile(r"<[^>]*>")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]")
_DECL_RE = re.compile(rb"<!\s*(doctype|entity)", re.I)
_ISO_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d))?(?:[.,]\d+)?)?\s*(Z|z|[+-]\d\d:?\d\d)?$")


def now():
    """The current time (UTC, aware). Tests replace this function to pin the clock."""
    return datetime.datetime.now(datetime.timezone.utc)


# --------------------------------------------------------------------------------------------- config

def check(cfg):
    check_config(cfg)


# --------------------------------------------------------------------------------------------- reading a feed

def _local(tag):
    return tag.rsplit("}", 1)[-1].lower() if isinstance(tag, str) else ""


def _child_text(el, *names):
    for child in el:
        if _local(child.tag) in names:
            return (child.text or "").strip()
    return ""


def parse_date(text):
    """An aware UTC datetime from an RFC 822 date (RSS) or an ISO 8601 date (Atom, dc:date); None when unreadable."""
    if not isinstance(text, str) or not text.strip() or len(text) > 64:
        return None
    text = text.strip()
    m = _ISO_RE.match(text)
    try:
        if m:
            y, mo, d, h, mi, s, tz = m.groups()
            dt = datetime.datetime(int(y), int(mo), int(d), int(h or 0), int(mi or 0), int(s or 0))
            if tz and tz not in ("Z", "z"):
                sign = 1 if tz[0] == "+" else -1
                digits = tz[1:].replace(":", "")
                dt -= sign * datetime.timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
            return dt.replace(tzinfo=datetime.timezone.utc)
        dt = email.utils.parsedate_to_datetime(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.astimezone(datetime.timezone.utc)
    except (ValueError, TypeError, OverflowError, IndexError):
        return None


def headline(text):
    """A title as one line of plain text: tags, entities, control characters, URLs and extra spaces gone."""
    text = html.unescape(_TAG_RE.sub(" ", text or ""))
    text = _CONTROL_RE.sub(" ", text)
    text = " ".join(text.split())
    return plain_text(text, HEADLINE_LEN)


def _entry_link(el):
    """The article address of an RSS item or Atom entry (an Atom entry may have several links)."""
    best = ""
    for child in el:
        if _local(child.tag) != "link":
            continue
        href = (child.get("href") or "").strip()
        if href:   # Atom
            rel = child.get("rel") or "alternate"
            if rel == "alternate":
                return href
            continue
        if (child.text or "").strip():   # RSS
            best = best or child.text.strip()
    if best:
        return best
    guid = _child_text(el, "guid")
    return guid if guid.lower().startswith(("http://", "https://")) else ""


def parse_feed(raw, base_url=""):
    """[{"title", "url", "time" (aware UTC)}] from a feed's bytes. ValueError for what is not a usable feed. Items
    without a readable title, date or http(s) link are left out."""
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff") or b"\x00" in raw[:8]:
        raise ValueError("unsupported encoding")   # UTF-16/32 could hide a DOCTYPE from the check below
    if _DECL_RE.search(raw):
        raise ValueError("DOCTYPE or ENTITY not allowed")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        raise ValueError("not XML")
    except Exception:   # noqa: BLE001 - expat limits, odd encodings
        raise ValueError("not readable")
    if _local(root.tag) not in ("rss", "rdf", "feed"):
        raise ValueError("not a feed")
    out = []
    for el in root.iter():
        if _local(el.tag) not in ("item", "entry"):
            continue
        if len(out) >= MAX_ITEMS:
            break
        title = headline(_child_text(el, "title"))
        when = parse_date(_child_text(el, "pubdate", "published", "date", "updated", "issued"))
        url = _entry_link(el)
        if url and base_url:
            url = resolve_url(base_url, url)
        if not title or when is None or not url.lower().startswith(("http://", "https://")) or not link_ok(url) \
                or len(url) > 2000 or _CONTROL_RE.search(url) or " " in url:
            continue
        out.append({"title": title, "url": url, "time": when})
    return out


def title_key(title):
    return " ".join(re.sub(r"[\W_]+", " ", title.lower()).split())


def age(delta_s):
    mins = int(delta_s // 60)
    if mins < 1:
        return "now"
    if mins < 60:
        return "%d min" % mins
    hours = mins // 60
    if hours < 48:
        return "%d h" % hours
    return "%d d" % (hours // 24)


# --------------------------------------------------------------------------------------------- collect

def _prefs_of(cfg):
    return load_prefs(cfg, cfg.get("_prefs_file"))


def _read(fetch, feed, timeout):
    """(items, None) or (None, short error) for one feed. Never raises."""
    try:
        reply = fetch(feed["url"], headers={"Accept": ACCEPT}, timeout=timeout)
        return parse_feed(reply.body, feed["url"]), None
    except SourceError as exc:
        return None, "too large" if "larger than" in str(exc) else str(exc)
    except ValueError as exc:
        return None, str(exc)
    except Exception as exc:   # noqa: BLE001 - one feed never takes the others down
        return None, short_error(exc)


def collect(cfg, fetch):
    prefs = _prefs_of(cfg)
    if not prefs["enabled"]:
        return {}
    feeds = [normal_feed(f) for f in feeds_of(cfg)]
    picked = [f for f in feeds if f["id"] in prefs["sources"] and (f["country"] == prefs["country"]
                                                                   or f["topic"] != "general")]
    if not picked:
        return {}
    limit = min(int(cfg.get("max_bytes") or DEFAULT_BYTES), MAX_BYTES)
    fetch.limit = limit
    timeout = min(float(cfg.get("timeout") or FEED_TIMEOUT), FEED_TIMEOUT)

    # All picked feeds at once; one that is still silent after its timeout (a slow drip) is abandoned.
    results = {}
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(picked)), thread_name_prefix="rss")
    futures = {pool.submit(_read, fetch, f, timeout): f for f in picked}
    done, pending = concurrent.futures.wait(futures, timeout=timeout + 2)
    for fut in done:
        results[futures[fut]["id"]] = fut.result()
    for fut in pending:
        results[futures[fut]["id"]] = (None, "timeout")
    pool.shutdown(wait=False, cancel_futures=True)

    failed = [(f, results[f["id"]][1]) for f in picked if results[f["id"]][0] is None]
    if len(failed) == len(picked):
        raise SourceError("all %d feeds failed (%s)" % (len(picked), failed[0][1]))

    t_now = now()
    window = datetime.timedelta(hours=prefs["window_h"])
    candidates = []
    for f in picked:
        items = results[f["id"]][0]
        for it in items or []:
            delta = t_now - it["time"]
            if delta > window or delta < -datetime.timedelta(hours=1):
                continue
            candidates.append(dict(it, feed=f, age=max(delta.total_seconds(), 0.0)))
    candidates.sort(key=lambda c: c["age"])
    candidates = candidates[:300]

    seen_urls, kept, titles = set(), [], []
    for c in candidates:
        key = url_key(c["url"])
        tkey = title_key(c["title"])
        if key in seen_urls:
            continue
        if any(tkey == t or difflib.SequenceMatcher(None, tkey, t).ratio() >= SIMILAR for t in titles):
            continue
        seen_urls.add(key)
        titles.append(tkey)
        kept.append(c)

    count = min(prefs["count"], int(cfg.get("max", DEFAULT_MAX)))
    per_feed = max(1, math.ceil(count / len(picked)))
    chosen, used = [], {}
    for c in kept:   # first pass: a fair share per feed, newest first
        if len(chosen) < count and used.get(c["feed"]["id"], 0) < per_feed:
            chosen.append(c)
            used[c["feed"]["id"]] = used.get(c["feed"]["id"], 0) + 1
    for c in kept:   # second pass: fill what the quiet feeds left
        if len(chosen) < count and c not in chosen:
            chosen.append(c)
    chosen.sort(key=lambda c: c["age"])

    problems = []
    if failed:
        text = "News: " + ", ".join("%s: %s" % (f["name"], why) for f, why in failed)
        problems.append({"id": "feeds", "severity": "warning", "text": text})
    if not chosen:
        return {"problems": problems}
    card_items = []
    for c in chosen:
        f = c["feed"]
        card_items.append({"title": c["title"], "subtitle": plain_text("%s · %s" % (f["name"], age(c["age"])), 80),
                           "url": c["url"], "published": c["time"].strftime("%Y-%m-%dT%H:%M:%SZ"),
                           "tags": ["source:" + f["id"], "country:" + f["country"], "topic:" + f["topic"].replace(" ", "-")]})
    local = t_now.astimezone()
    card = {"id": "news", "title": plain_text(cfg.get("name") or "News", 40), "style": "list", "icon": "newspaper",
            "subtitle": "", "updated": local.strftime("%H:%M"), "items": card_items}
    return {"cards": [card], "problems": problems}
