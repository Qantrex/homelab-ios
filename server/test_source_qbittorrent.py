#!/usr/bin/env python3
"""Tests for the qBittorrent source (server/sources/qbittorrent.py) against server/recordings/qbittorrent/. Run from
the repo root:

    python3 -m unittest -v server/test_source_qbittorrent.py
"""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sources  # noqa: E402
from sources import qbittorrent  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402

PASSWORD = "made-up pass&word=1+2%"
API_KEY = "qbt_madeUpKey0123456789abcdefABCD"
ENV = {"QBIT_PW": PASSWORD, "QBIT_KEY": API_KEY}
COOKIE = "QBT_SID_8080=madeUpSession0123456789abcdefABCD"


def recording(case):
    return os.path.join(HERE, "recordings", "qbittorrent", case + ".json")


def header(req, name):
    return {k.lower(): v for k, v in req["headers"].items()}.get(name.lower())


def run(up, env=None, **cfg):
    raw = dict({"name": "qBittorrent", "type": "qbittorrent", "url": up.url}, **cfg)
    if "key_env" not in cfg:
        raw.update({"username": "monitor", "password_env": "QBIT_PW"})
    spec = sources.parse([raw], ENV if env is None else env)[0]
    runner = sources.Runner([spec])
    runner.run_one(spec)
    return runner


class QbittorrentSource(unittest.TestCase):
    def test_normal(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up)
        self.assertIsNone(runner.states["qBittorrent"].error)
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]], [
            ("qBittorrent:torrent-aaaabbbbccccdddd", "warning", "qBittorrent: Demo.Picture.2026.720p: files missing")])
        card, = out["cards"]
        self.assertEqual((card["id"], card["style"], card["place"]), ("qBittorrent:downloads", "list", "lab"))
        self.assertEqual(card["subtitle"], "3 downloading · down 2.2 MB/s · up 310 kB/s")
        self.assertEqual(card["items"], [
            {"title": "Demo.Picture.2026.720p", "subtitle": "Files missing", "progress": 0.42, "tint": "red"},
            {"title": "Placeholder.Show.S02E05.1080p.WEB", "subtitle": "Downloading · 1.8 MB/s", "progress": 0.75,
             "value": "12 min"},
            {"title": "Sample.Film.2025.1080p.BluRay", "subtitle": "Downloading · 400 kB/s", "progress": 0.75,
             "value": "1 h 30 min"},
            {"title": "example-os-24.04-amd64.iso", "subtitle": "Stalled", "progress": 0.1}])

    def test_login_cookie_and_logout(self):
        with FakeUpstream(recording("normal")) as up:
            out = run(up).merged()
            reqs = up.requests
        self.assertEqual([(r["method"], r["path"]) for r in reqs], [
            ("POST", "/api/v2/auth/login"), ("GET", "/api/v2/transfer/info"),
            ("GET", "/api/v2/torrents/info?filter=downloading"), ("GET", "/api/v2/torrents/info?filter=errored"),
            ("POST", "/api/v2/auth/logout")])
        login = reqs[0]
        self.assertEqual(login["body"], "username=monitor&password=made-up%20pass%26word%3D1%2B2%25")
        self.assertEqual(header(login, "Content-Type"), "application/x-www-form-urlencoded")
        self.assertEqual(header(login, "Referer"), up.url + "/")
        self.assertIsNone(header(login, "Cookie"))
        for r in reqs[1:]:
            self.assertEqual(header(r, "Cookie"), COOKIE)
            self.assertNotIn(PASSWORD, r["body"])
        self.assertNotIn("madeUpSession", json.dumps(out))
        self.assertNotIn(PASSWORD, json.dumps(out))

    def test_api_key_needs_no_login(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up, key_env="QBIT_KEY")
            reqs = up.requests
        self.assertIsNone(runner.states["qBittorrent"].error)
        self.assertEqual([r["path"] for r in reqs], ["/api/v2/transfer/info", "/api/v2/torrents/info?filter=downloading",
                                                     "/api/v2/torrents/info?filter=errored"])
        for r in reqs:
            self.assertEqual(header(r, "Authorization"), "Bearer " + API_KEY)
            self.assertIsNone(header(r, "Cookie"))

    def test_limit(self):
        with FakeUpstream(recording("normal")) as up:
            items = run(up, limit=2).merged()["cards"][0]["items"]
        self.assertEqual([i["title"] for i in items], ["Demo.Picture.2026.720p", "Placeholder.Show.S02E05.1080p.WEB"])

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("odd")) as up:
            runner = run(up)
            self.assertEqual(header(up.requests[1], "Cookie"), "SID=oddSession0123456789")
        self.assertIsNone(runner.states["qBittorrent"].error)
        out = runner.merged()
        self.assertEqual([p["id"] for p in out["problems"]], ["qBittorrent:connection"])
        card = out["cards"][0]
        self.assertEqual(card["subtitle"], "2 downloading")
        self.assertEqual(card["items"], [{"title": "Odd one", "subtitle": "newState"},
                                         {"title": "Over full", "subtitle": "Stalled", "progress": 1.0}])

    def test_wrong_password_is_one_warning(self):
        with FakeUpstream(recording("auth-failed")) as up:
            out = run(up).merged()
            self.assertEqual([r["path"] for r in up.requests], ["/api/v2/auth/login"])
        self.assertEqual([(p["id"], p["text"]) for p in out["problems"]],
                         [("qBittorrent:source", "qBittorrent: login failed (check username and password)")])
        self.assertEqual(out["cards"], [])

    def test_banned_and_no_cookie(self):
        with FakeUpstream({"routes": {"POST /api/v2/auth/login": {"status": 403, "body": "Forbidden"}}}) as up:
            self.assertEqual(run(up).states["qBittorrent"].error, "403 (this address is banned after failed logins)")
        with FakeUpstream({"routes": {"POST /api/v2/auth/login": {"body": "Ok."}}}) as up:
            self.assertEqual(run(up).states["qBittorrent"].error, "login gave no session cookie")
        with FakeUpstream({"routes": {"GET /api/v2/transfer/info": {"status": 401, "body": ""}}}) as up:
            self.assertEqual(run(up, key_env="QBIT_KEY").states["qBittorrent"].error, "401")

    def test_logout_even_when_a_read_fails(self):
        with FakeUpstream({"routes": {"POST /api/v2/auth/login": {"body": "Ok.", "headers": {"Set-Cookie": "SID=x1"}},
                                      "GET /api/v2/transfer/info": {"status": 500, "body": ""},
                                      "POST /api/v2/auth/logout": {"body": ""}}}) as up:
            self.assertEqual(run(up).states["qBittorrent"].error, "500")
            self.assertEqual(up.requests[-1]["path"], "/api/v2/auth/logout")

    def test_helpers(self):
        self.assertEqual([qbittorrent.eta(s) for s in (30, 750, 5400, 90000, 8640000, -1, None, True)],
                         ["< 1 min", "12 min", "1 h 30 min", "1 d 1 h", "", "", "", ""])
        self.assertEqual([qbittorrent.speed(n) for n in (0, 512, 310000, 2200000, 1.5e9, "x")],
                         ["", "512 B/s", "310 kB/s", "2.2 MB/s", "1.5 GB/s", ""])
        self.assertEqual(qbittorrent.form([("a b", "ü/&")]), b"a%20b=%C3%BC%2F%26")

    def test_config_checks(self):
        for raw, words in [({}, "key_env .* or username and password_env"), ({"username": "x"}, "or username"),
                           ({"key_env": "QBIT_KEY", "limit": 0}, "limit"),
                           ({"key_env": "QBIT_KEY", "password": "x"}, "looks like a secret")]:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, words):
                    sources.parse([dict({"name": "qBittorrent", "type": "qbittorrent", "url": "http://192.0.2.20:8080"},
                                        **raw)], ENV)


if __name__ == "__main__":
    unittest.main()
