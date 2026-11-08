#!/usr/bin/env python3
"""Tests for the news source (server/sources/rss.py) and the News endpoints of the reference server (GET
/api/v1/news/sources, PUT /api/v1/news/prefs). Feeds are recorded RSS/Atom files (server/recordings/rss/*.json)
replayed by server/fake_upstream.py; the clock is pinned to 2026-11-08 12:00 UTC. Run from the repo root:

    python3 -m unittest -v server/test_source_rss.py
"""

import datetime
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402
import sources  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402
from sources import rss  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None

UTC = datetime.timezone.utc
NOW = datetime.datetime(2026, 11, 8, 12, 0, tzinfo=UTC)
rss.now = lambda: NOW


def xml(name):
    """The body of one recorded feed (normal.json: the three real-shaped feeds; odd.json: the hostile ones)."""
    for case in ("normal", "odd"):
        with open(os.path.join(HERE, "recordings", "rss", case + ".json"), encoding="utf-8") as fh:
            found = json.load(fh)["routes"].get("GET /%s.xml" % name)
        if found:
            return found["body"]
    raise KeyError(name)


def routes(**files):
    """A recording: /<name>.xml answers with the file `files[name]` (a recording name, or a route dict)."""
    out = {}
    for name, what in files.items():
        out["GET /%s.xml" % name] = what if isinstance(what, dict) else {"body": xml(what)}
    return {"routes": out}


def feeds(base):
    return [{"id": "orf", "name": "ORF", "url": base + "/orf.xml", "country": "at", "topic": "general"},
            {"id": "standard", "name": "Der Standard", "url": base + "/standard.xml", "country": "at",
             "topic": "general"},
            {"id": "heise", "name": "heise", "url": base + "/heise.xml", "country": "de", "topic": "tech"}]


def conf(base, **extra):
    return dict({"name": "News", "type": "rss", "feeds": feeds(base)}, **extra)


def run(base, prefs=None, tmp=None, only=None, **extra):
    """The runner after one run, with the prefs file set when `prefs` is given."""
    cfg = conf(base, **extra)
    if only:
        cfg["feeds"] = [f for f in cfg["feeds"] if f["id"] in only]
    spec = sources.parse([cfg], {})[0]
    if prefs is not None:
        path = os.path.join(tmp, "news-prefs.json")
        rss.save_prefs(path, prefs)
        spec["cfg"]["_prefs_file"] = path
    runner = sources.Runner([spec])
    runner.run_one(spec)
    return runner


def all_prefs(**kw):
    return dict({"enabled": True, "country": "at", "sources": ["orf", "standard", "heise"], "summary": False,
                 "count": 8, "window_h": 24}, **kw)


class TmpCase:
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def card(self, runner):
        cards = runner.merged()["cards"]
        return cards[0] if cards else None


class Headlines(TmpCase, unittest.TestCase):
    def test_normal_card(self):
        with FakeUpstream(routes(orf="orf", standard="standard", heise="heise")) as up:
            runner = run(up.url, all_prefs(), self.tmp)
        out = runner.merged()
        self.assertEqual(out["problems"], [])
        card = out["cards"][0]
        self.assertEqual(set(card), {"id", "title", "style", "icon", "subtitle", "updated", "items"})
        self.assertEqual((card["id"], card["title"], card["style"], card["icon"], card["subtitle"]),
                         ("news", "News", "list", "newspaper", ""))
        self.assertRegex(card["updated"], r"^\d\d:\d\d$")
        self.assertEqual([(i["title"], i["subtitle"]) for i in card["items"]], [
            ("Kultur: Neue Oper in Wien", "Der Standard · 5 min"),
            ("Linux 7.3 erschienen & verbessert Dateisysteme", "heise · 40 min"),
            ("Regierung beschliesst Budget fuer 2027", "Der Standard · 2 h"),   # the newer copy of a shared story
            ("Schneefall im Westen erwartet", "ORF · 2 h"),
            ("Wirtschaft: Inflation sinkt im Oktober", "Der Standard · 3 h"),
            ("Fussball: Derby endet unentschieden", "ORF · 4 h"),
            ("Neue Sicherheitsluecke in Router-Firmware", "heise · 6 h")])
        first = card["items"][1]
        self.assertEqual(first["url"], "https://www.heise.de/news/linux-7-3-1.html")
        self.assertEqual(first["tags"], ["source:heise", "country:de", "topic:tech"])
        self.assertEqual({k for i in card["items"] for k in i}, {"title", "subtitle", "url", "tags", "published"})
        self.assertEqual(first["published"], "2026-11-08T11:20:00Z")   # the feed's own time, UTC with zone
        self.assertEqual([i["published"] for i in card["items"]], sorted((i["published"] for i in card["items"]), reverse=True))
        self.assertNotIn("body", json.dumps(card))   # never article bodies or images
        self.assertNotIn("img.example", json.dumps(card))

    def test_same_article_and_near_identical_title_once(self):
        with FakeUpstream(routes(orf="orf", standard="standard")) as up:
            card = self.card(run(up.url, all_prefs(sources=["orf", "standard"]), self.tmp, only=["orf", "standard"]))
        titles = [i["title"] for i in card["items"]]
        self.assertEqual(sum("Budget" in t for t in titles), 1)
        self.assertEqual(len(titles), 5)

    def test_window(self):
        with FakeUpstream(routes(orf="orf")) as up:
            c24 = self.card(run(up.url, all_prefs(sources=["orf"]), self.tmp, only=["orf"]))
            c12 = self.card(run(up.url, all_prefs(sources=["orf"], window_h=12), self.tmp, only=["orf"]))
            c48 = self.card(run(up.url, all_prefs(sources=["orf"], window_h=48), self.tmp, only=["orf"]))
        self.assertEqual([len(c["items"]) for c in (c24, c12, c48)], [3, 3, 4])
        self.assertTrue(c48["items"][-1]["title"].startswith("Aelterer"))
        self.assertEqual(c48["items"][-1]["subtitle"], "ORF · 28 h")

    def test_count_and_fair_share(self):
        with FakeUpstream(routes(orf="orf", standard="standard", heise="heise")) as up:
            card = self.card(run(up.url, all_prefs(count=3), self.tmp))
            capped = self.card(run(up.url, all_prefs(count=8), self.tmp, max=4))
        self.assertEqual([i["tags"][0] for i in card["items"]], ["source:standard", "source:heise", "source:orf"])
        self.assertEqual(len(capped["items"]), 4)   # the config's max lowers the app's count

    def test_default_prefs_without_a_file(self):
        with FakeUpstream(routes(orf="orf", standard="standard", heise="heise")) as up:
            card = self.card(run(up.url))
        self.assertEqual(len(card["items"]), 5)

    def test_odd_feed_keeps_only_safe_items(self):
        with FakeUpstream(routes(odd="odd")) as up:
            cfg = {"name": "News", "type": "rss", "feeds": [
                {"id": "odd", "name": "Odd", "url": up.url + "/odd.xml", "country": "at"}]}
            spec = sources.parse([cfg], {})[0]
            runner = sources.Runner([spec])
            runner.run_one(spec)
            base = up.url
        card = self.card(runner)
        titles = [i["title"] for i in card["items"]]
        self.assertEqual(len(titles), 3, titles)
        markup = [i for i in card["items"] if "markup" in i["url"]][0]
        self.assertEqual(markup["title"], "Bold *markup* [x](<url> and spaces <url>")
        for bad in ("<b>", "http", "token=abc"):
            self.assertNotIn(bad, markup["title"])
        self.assertEqual({i["url"] for i in card["items"]},
                         {"https://odd.example/markup", "https://odd.example/guid", base + "/relative/path"})

    def test_parse_skips_unusable_items(self):
        got = rss.parse_feed(xml("odd").encode(), "https://odd.example/feed")
        self.assertEqual(sorted(i["url"] for i in got),
                         ["https://odd.example/future", "https://odd.example/guid", "https://odd.example/markup",
                          "https://odd.example/relative/path"])   # no date, bad link, no title: gone

    def test_future_items_are_not_shown(self):
        with FakeUpstream(routes(odd="odd")) as up:
            cfg = {"name": "News", "type": "rss", "feeds": [
                {"id": "odd", "name": "Odd", "url": up.url + "/odd.xml", "country": "at"}]}
            spec = sources.parse([cfg], {})[0]
            runner = sources.Runner([spec])
            runner.run_one(spec)
        self.assertNotIn("future", json.dumps(runner.merged()))

    def test_dates(self):
        d = rss.parse_date
        self.assertEqual(d("Sun, 08 Nov 2026 10:40:00 +0100"), datetime.datetime(2026, 11, 8, 9, 40, tzinfo=UTC))
        self.assertEqual(d("2026-11-08T10:30:00+01:00"), datetime.datetime(2026, 11, 8, 9, 30, tzinfo=UTC))
        self.assertEqual(d("2026-11-08T10:30:00.123Z"), datetime.datetime(2026, 11, 8, 10, 30, tzinfo=UTC))
        self.assertEqual(d("2026-11-08"), datetime.datetime(2026, 11, 8, tzinfo=UTC))
        for junk in ("", "last tuesday", "2026-13-45T99:00:00Z", None, 5, "x" * 500):
            self.assertIsNone(d(junk))


class Failures(TmpCase, unittest.TestCase):
    def test_one_bad_feed_is_a_warning_and_the_rest_shows(self):
        with FakeUpstream(routes(orf="orf", standard="malformed", heise="heise")) as up:
            runner = run(up.url, all_prefs(), self.tmp)
        out = runner.merged()
        self.assertEqual(len(out["cards"][0]["items"]), 5)
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]],
                         [("News:feeds", "warning", "News: Der Standard: not XML")])

    def test_each_failure_kind_is_skipped(self):
        cases = {"entity": "DOCTYPE or ENTITY not allowed", "notafeed": "not a feed", "malformed": "not XML",
                 "x404": "404"}
        for name, why in cases.items():
            standard = {"status": 404, "body": "no"} if name == "x404" else name
            with FakeUpstream(routes(orf="orf", standard=standard, heise="heise")) as up:
                runner = run(up.url, all_prefs(), self.tmp)
            out = runner.merged()
            self.assertEqual(len(out["cards"][0]["items"]), 5, name)
            self.assertEqual(out["problems"][0]["text"], "News: Der Standard: " + why, name)

    def test_all_failing_is_one_warning_and_no_card(self):
        rec = routes(orf="entity", standard="malformed", heise={"status": 500, "body": "boom"})
        with FakeUpstream(rec) as up:
            runner = run(up.url, all_prefs(), self.tmp)
        out = runner.merged()
        self.assertEqual(out["cards"], [])
        self.assertEqual(len(out["problems"]), 1)
        self.assertRegex(out["problems"][0]["text"], r"^News: all 3 feeds failed \(")
        self.assertEqual(runner.status()[0]["state"], "failing")

    def test_failure_after_success_leaves_no_stale_card(self):
        with FakeUpstream(routes(orf="orf")) as up:
            cfg = {"name": "News", "type": "rss", "feeds": [
                {"id": "orf", "name": "ORF", "url": up.url + "/orf.xml", "country": "at"}]}
            spec = sources.parse([cfg], {})[0]
            runner = sources.Runner([spec])
            runner.run_one(spec)
            self.assertEqual(len(runner.merged()["cards"]), 1)
            up.routes["GET /orf.xml"] = {"status": 502, "body": "bad gateway"}
            runner.run_one(spec)
        self.assertEqual(runner.merged()["cards"], [])

    def test_entity_attack_reads_nothing(self):
        with FakeUpstream(routes(orf="entity")) as up:
            runner = run(up.url, all_prefs(sources=["orf"]), self.tmp, only=["orf"])
        self.assertEqual(runner.merged()["cards"], [])
        for text in ("lol", "made-up-secret", "evil.example"):
            self.assertNotIn(text, json.dumps(runner.merged()))
        for raw in (b'<?xml version="1.0"?><!doctype x><rss/>', b"<!ENTITY a 'b'><rss/>",
                    "<?xml version='1.0' encoding='utf-16'?><!DOCTYPE a><rss/>".encode("utf-16")):
            with self.assertRaises(ValueError):
                rss.parse_feed(raw)

    def test_huge_answer_is_cut_off(self):
        rec = routes(orf={"body": xml("orf"), "pad": 6000}, standard="standard", heise="heise")
        with FakeUpstream(rec) as up:
            small = run(up.url, all_prefs(), self.tmp, max_bytes=4096)
            big = run(up.url, all_prefs(), self.tmp, max_bytes=65536)
        self.assertEqual(small.merged()["problems"][0]["text"], "News: ORF: too large")
        self.assertEqual(big.merged()["problems"], [])

    def test_slow_feed_times_out_and_does_not_block(self):
        rec = routes(orf={"body": xml("orf"), "delay": 4}, standard="standard", heise="heise")
        with FakeUpstream(rec) as up:
            t0 = time.monotonic()
            runner = run(up.url, all_prefs(), self.tmp, timeout=0.5)
            took = time.monotonic() - t0
        self.assertLess(took, 3.0)
        out = runner.merged()
        self.assertEqual(out["problems"][0]["text"], "News: ORF: timeout")
        self.assertEqual(len(out["cards"][0]["items"]), 5)

    def test_no_redirects_followed(self):
        rec = routes(orf={"status": 301, "headers": {"Location": "http://127.0.0.1:1/x"}, "body": ""},
                     standard="standard")
        with FakeUpstream(rec) as up:
            runner = run(up.url, all_prefs(sources=["orf", "standard"]), self.tmp, only=["orf", "standard"])
        self.assertEqual(runner.merged()["problems"][0]["text"], "News: ORF: 301")

    def test_item_count_is_bounded(self):
        items = "".join("<item><title>T%d</title><link>https://x.example/%d</link>"
                        "<pubDate>Sun, 08 Nov 2026 11:00:00 GMT</pubDate></item>" % (i, i) for i in range(500))
        got = rss.parse_feed(('<rss version="2.0"><channel>%s</channel></rss>' % items).encode())
        self.assertEqual(len(got), rss.MAX_ITEMS)
        deep = b"<rss>" + b"<a>" * 5000 + b"</a>" * 5000 + b"</rss>"
        try:
            rss.parse_feed(deep)   # a deep tree is read or refused, never a crash
        except ValueError:
            pass


class Prefs(TmpCase, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.cfg = sources.parse([conf("http://127.0.0.1:9")], {})[0]["cfg"]

    def test_catalog(self):
        cat = rss.catalog(self.cfg)
        self.assertEqual(cat["countries"], [{"id": "at", "name": "Austria"}, {"id": "de", "name": "Germany"}])
        self.assertEqual(cat["sources"][2], {"id": "heise", "name": "heise", "country": "de", "topic": "tech"})

    def test_defaults(self):
        self.assertEqual(rss.default_prefs(self.cfg), {"enabled": True, "country": "at",
                                                       "sources": ["orf", "standard", "heise"], "summary": False,
                                                       "count": 5, "window_h": 24})

    def test_validation(self):
        ok = rss.validate_prefs(self.cfg, all_prefs(sources=["heise", "nope", "orf", "orf", "heise"], summary=True,
                                                    count=3, window_h=48))
        self.assertEqual(ok, {"enabled": True, "country": "at", "sources": ["orf", "heise"], "summary": False,
                              "count": 3, "window_h": 48})
        for bad in ([], "x", None, {"enabled": "yes"}, {"count": 4}, {"count": True}, {"count": "5"},
                    {"window_h": 36}, {"country": "xx"}, {"country": 5}, {"sources": "orf"}, {"sources": [1]},
                    {"summary": 1}):
            with self.assertRaises(ValueError, msg=repr(bad)):
                rss.validate_prefs(self.cfg, bad)

    def test_file_roundtrip_and_broken_file(self):
        path = os.path.join(self.tmp, "state", "news-prefs.json")
        rss.save_prefs(path, all_prefs(count=3))
        self.assertEqual(os.stat(path).st_mode & 0o077, 0)
        self.assertEqual(rss.load_prefs(self.cfg, path)["count"], 3)
        with open(path, "w") as fh:
            fh.write("{broken")
        self.assertEqual(rss.load_prefs(self.cfg, path), rss.default_prefs(self.cfg))
        self.assertEqual(rss.load_prefs(self.cfg, None), rss.default_prefs(self.cfg))

    def test_collect_applies_prefs(self):
        with FakeUpstream(routes(orf="orf", standard="standard", heise="heise")) as up:
            off = run(up.url, all_prefs(enabled=False), self.tmp)
            only = run(up.url, all_prefs(sources=["heise"]), self.tmp)
            de = run(up.url, all_prefs(country="de"), self.tmp)
            none = run(up.url, all_prefs(sources=[]), self.tmp)
        self.assertEqual(off.merged(), {"problems": [], "hosts": [], "cards": [], "services": []})
        self.assertEqual({i["tags"][0] for i in self.card(only)["items"]}, {"source:heise"})
        # country de: the Austrian general feeds are hidden, the tech feed stays
        self.assertEqual({i["tags"][0] for i in self.card(de)["items"]}, {"source:heise"})
        self.assertEqual(none.merged()["cards"], [])

    def test_disabled_reads_no_feed(self):
        with FakeUpstream(routes(orf="orf")) as up:
            run(up.url, all_prefs(enabled=False), self.tmp)
            self.assertEqual(up.requests, [])


class ConfigChecks(unittest.TestCase):
    def bad(self, **change):
        cfg = conf("https://feed.example")
        feed = change.pop("feed", None)
        cfg.update(change)
        if feed is not None:
            cfg["feeds"] = [dict(cfg["feeds"][0], **feed)]
        with self.assertRaises(ValueError, msg=repr((change, feed))):
            sources.parse([cfg], {})

    def test_bad_configs(self):
        self.bad(feeds=[])
        self.bad(feeds="orf")
        self.bad(feed={"id": "Bad Id"})
        self.bad(feed={"url": "ftp://x.example/feed"})
        self.bad(feed={"url": "https://u:p@x.example/feed"})
        self.bad(feed={"url": "https://x.example/feed?apikey=1"})
        self.bad(feed={"country": "Austria"})
        self.bad(feed={"topic": "A B!"})
        self.bad(feed={"extra": 1})
        self.bad(max=0)
        self.bad(window_h="24")
        self.bad(max_bytes=10 ** 9)
        dup = conf("https://feed.example")
        dup["feeds"].append(dict(dup["feeds"][0]))
        with self.assertRaises(ValueError):
            sources.parse([dup], {})

    def test_only_one_rss_source(self):
        with self.assertRaises(ValueError):
            sources.parse([conf("https://feed.example"), dict(conf("https://feed.example"), name="News2")], {})

    def test_public_feed_list_is_valid(self):
        sources.parse([{"name": "News", "type": "rss", "max": 8, "feeds": [
            {"id": "orf", "name": "ORF", "url": "https://rss.orf.at/news.xml", "country": "at", "topic": "general"},
            {"id": "derstandard", "name": "Der Standard", "url": "https://www.derstandard.at/rss", "country": "at",
             "topic": "general"},
            {"id": "heise", "name": "heise", "url": "https://www.heise.de/rss/heise-atom.xml", "country": "de",
             "topic": "tech"},
            {"id": "hn", "name": "Hacker News", "url": "https://news.ycombinator.com/rss", "country": "int",
             "topic": "tech"},
            {"id": "bbc", "name": "BBC", "url": "https://feeds.bbci.co.uk/news/rss.xml", "country": "gb",
             "topic": "general"}]}], {})


class NewsEndpoints(TmpCase, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.up = FakeUpstream(routes(orf="orf", standard="standard", heise="heise")).start()
        self.addCleanup(self.up.stop)

    def start(self, with_rss=True):
        if with_rss:
            src = [conf(self.up.url, every=1)]
        else:
            src = [{"name": "Feed", "type": "json", "url": self.up.url + "/none.json"}]
        raw = {"tokens": [TOKEN], "state_dir": os.path.join(self.tmp, "state"), "name": "Test", "sources": src}
        app = rs.RealApp(rs.Config(raw, env={}))
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: all(st.runs >= 1 for st in app.sources.states.values()))
        return app, httpd.server_address[1]

    def news_card(self, port):
        code, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertEqual(code, 200)
        return [c for c in state["cards"] if c["id"] == "news"]

    def tags(self, port):
        cards = self.news_card(port)
        return {i["tags"][0] for i in cards[0]["items"]} if cards else set()

    def test_sources_listing(self):
        app, port = self.start()
        code, _, obj = call(port, "GET", "/api/v1/news/sources", headers=AUTH)
        self.assertEqual(code, 200)
        self.assertEqual(set(obj), {"countries", "sources", "prefs", "can_summarize"})
        self.assertIs(obj["can_summarize"], False)
        self.assertEqual([s["id"] for s in obj["sources"]], ["orf", "standard", "heise"])
        self.assertEqual(obj["prefs"]["country"], "at")
        self.assertEqual(len(self.news_card(port)[0]["items"]), 5)
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertEqual(info["sources"][0]["type"], "rss")

    def test_auth(self):
        app, port = self.start()
        body = all_prefs()
        for headers, want in (({}, 401), ({"Authorization": "Bearer wrong"}, 403)):
            self.assertEqual(call(port, "GET", "/api/v1/news/sources", headers=headers)[0], want)
            self.assertEqual(call(port, "PUT", "/api/v1/news/prefs", body=body, headers=headers)[0], want)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "state", "news-prefs.json")))
        self.assertEqual(call(port, "GET", "/api/v1/news/prefs", headers=AUTH)[0], 405)

    def test_put_stores_and_applies(self):
        app, port = self.start()
        code, _, obj = call(port, "PUT", "/api/v1/news/prefs", headers=AUTH,
                            body=all_prefs(sources=["heise", "ghost"], count=3, summary=True))
        self.assertEqual(code, 200)
        self.assertEqual(obj, {"ok": True, "prefs": {"enabled": True, "country": "at", "sources": ["heise"],
                                                     "summary": False, "count": 3, "window_h": 24}})
        path = os.path.join(self.tmp, "state", "news-prefs.json")
        self.assertEqual(os.stat(path).st_mode & 0o077, 0)
        wait_for(lambda: self.tags(port) == {"source:heise"}, timeout=8)   # read again soon, only heise left
        self.assertEqual(call(port, "GET", "/api/v1/news/sources", headers=AUTH)[2]["prefs"]["count"], 3)
        app2, port2 = self.start()   # kept across a restart
        self.assertEqual(call(port2, "GET", "/api/v1/news/sources", headers=AUTH)[2]["prefs"]["sources"], ["heise"])
        call(port, "PUT", "/api/v1/news/prefs", body=all_prefs(enabled=False), headers=AUTH)
        wait_for(lambda: self.news_card(port) == [], timeout=8)   # off: no card at all

    def test_put_rejects_malformed_bodies(self):
        app, port = self.start()
        for body in ({"count": 4}, {"window_h": 1}, {"country": "zz"}, {"enabled": "no"}, {"sources": 3}):
            code, _, obj = call(port, "PUT", "/api/v1/news/prefs", body=body, headers=AUTH)
            self.assertEqual(code, 400, body)
            self.assertIn("error", obj)
        self.assertEqual(call(port, "PUT", "/api/v1/news/prefs", raw=b"{nope", headers=AUTH)[0], 400)
        self.assertEqual(call(port, "PUT", "/api/v1/news/prefs", raw=b"[1]", headers=AUTH)[0], 400)
        self.assertEqual(call(port, "PUT", "/api/v1/news/prefs", raw=b"{}", headers=AUTH, ctype="text/plain")[0], 415)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "state", "news-prefs.json")))

    def test_404_without_an_rss_source(self):
        app, port = self.start(with_rss=False)
        self.assertEqual(call(port, "GET", "/api/v1/news/sources", headers=AUTH)[0], 404)
        self.assertEqual(call(port, "PUT", "/api/v1/news/prefs", body=all_prefs(), headers=AUTH)[0], 404)

    def test_404_without_any_sources(self):
        app = rs.RealApp(rs.Config({"tokens": [TOKEN], "state_dir": os.path.join(self.tmp, "s2")}, env={}))
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        port = httpd.server_address[1]
        self.assertEqual(call(port, "GET", "/api/v1/news/sources", headers=AUTH)[0], 404)
        self.assertEqual(call(port, "PUT", "/api/v1/news/prefs", body=all_prefs(), headers=AUTH)[0], 404)


if __name__ == "__main__":
    unittest.main()
