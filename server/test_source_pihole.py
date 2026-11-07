#!/usr/bin/env python3
"""Tests for the Pi-hole v6 source (server/sources/pihole.py) against server/recordings/pihole/. Run from the repo root:

    python3 -m unittest -v server/test_source_pihole.py
"""

import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sources  # noqa: E402
from fake_upstream import FakeUpstream, load  # noqa: E402

PASSWORD = "made-up-app-password-0123456789"
ENV = {"PIHOLE_PW": PASSWORD}
SID = "made-up-sid-0123456789ab="


def recording(case):
    return os.path.join(HERE, "recordings", "pihole", case + ".json")


def routes(case="normal", **changes):
    """A recording's routes with some answers replaced: routes(**{"GET /api/dns/blocking": {...}})."""
    r = copy.deepcopy(load(recording(case)))
    r.update(changes)
    return {"routes": r}


def header(req, name):
    """A request header from FakeUpstream.requests, by its name in any case (HTTP header names are)."""
    return {k.lower(): v for k, v in req["headers"].items()}.get(name.lower())


def run(up, env=None, **cfg):
    raw = dict({"name": "Pi-hole", "type": "pihole", "url": up.url, "key_env": "PIHOLE_PW"}, **cfg)
    raw = {k: v for k, v in raw.items() if v is not None}
    spec = sources.parse([raw], ENV if env is None else env)[0]
    runner = sources.Runner([spec])
    runner.run_one(spec)
    return runner


class PiholeSource(unittest.TestCase):
    def test_normal(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up)
        self.assertIsNone(runner.states["Pi-hole"].error)
        out = runner.merged()
        self.assertEqual(out["problems"], [])
        dns, top = out["cards"]
        self.assertEqual((dns["id"], dns["style"], dns["place"], dns["title"]), ("Pi-hole:dns", "metrics", "lab", "Pi-hole"))
        self.assertEqual(dns["items"], [{"title": "Queries", "value": "23.4k", "subtitle": "24 h"},
                                        {"title": "Blocked", "value": "18.4 %"},
                                        {"title": "Blocking", "value": "on"}])
        self.assertEqual(top["id"], "Pi-hole:dns-top")
        self.assertEqual([(i["title"], i["value"]) for i in top["items"]],
                         [("ads.example.net", "812"), ("tracker.example.org", "640"), ("telemetry.example.com", "377")])

    def test_session_login_sid_and_logout(self):
        with FakeUpstream(recording("normal")) as up:
            run(up)
            reqs = up.requests
        self.assertEqual([(r["method"], r["path"]) for r in reqs], [
            ("POST", "/api/auth"), ("GET", "/api/stats/summary"), ("GET", "/api/dns/blocking"),
            ("GET", "/api/stats/top_domains?blocked=true&count=5"), ("DELETE", "/api/auth")])
        self.assertEqual(json.loads(reqs[0]["body"]), {"password": PASSWORD})
        for r in reqs[1:]:
            self.assertEqual(header(r, "X-FTL-SID"), SID)
            self.assertNotIn(PASSWORD, json.dumps(r))
            self.assertNotIn("Cookie", r["headers"])

    def test_no_pause_button_unless_listed(self):
        with FakeUpstream(recording("normal")) as up:
            plain = run(up).merged()["cards"][0]["items"][2]
            opted = run(up, actions={"pause": [30, 5, 15]}).merged()["cards"][0]["items"][2]
            longer = run(up, actions={"pause": [60]}).merged()["cards"][0]["items"][2]
            empty = run(up, actions={"pause": []}).merged()["cards"][0]["items"][2]
        self.assertNotIn("action", plain)
        self.assertNotIn("action", empty)
        self.assertEqual(opted["action"], {"name": "dns-pause", "label": "Pause 5 min", "arg": "Pi-hole:5"})
        self.assertEqual(longer["action"], {"name": "dns-pause", "label": "Pause 1 h", "arg": "Pi-hole:60"})

    def test_paused_and_off(self):
        paused = routes(**{"GET /api/dns/blocking": {"json": {"blocking": "disabled", "timer": 239.4}}})
        with FakeUpstream(paused) as up:
            out = run(up, actions={"pause": [5]}).merged()
        self.assertEqual(out["problems"], [])
        self.assertEqual(out["cards"][0]["items"][2], {"title": "Blocking", "value": "off · 4 min", "tint": "orange",
                                                       "action": {"name": "dns-pause", "label": "Resume",
                                                                  "arg": "Pi-hole:on"}})
        off = routes(**{"GET /api/dns/blocking": {"json": {"blocking": "disabled", "timer": None}}})
        with FakeUpstream(off) as up:
            out = run(up).merged()
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]],
                         [("Pi-hole:blocking", "warning", "Pi-hole: ad blocking is off")])
        failed = routes(**{"GET /api/dns/blocking": {"json": {"blocking": "failed", "timer": None}}})
        with FakeUpstream(failed) as up:
            out = run(up).merged()
        self.assertEqual(out["cards"][0]["items"][2]["tint"], "red")
        self.assertEqual(out["problems"][0]["text"], "Pi-hole: ad blocking failed")

    def test_top_zero_skips_the_request_and_card(self):
        with FakeUpstream(recording("normal")) as up:
            out = run(up, top=0).merged()
            paths = [r["path"] for r in up.requests]
        self.assertEqual([c["id"] for c in out["cards"]], ["Pi-hole:dns"])
        self.assertFalse(any("top_domains" in p for p in paths))

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("odd")) as up:
            runner = run(up)
        self.assertIsNone(runner.states["Pi-hole"].error)
        out = runner.merged()
        self.assertEqual(out["cards"][0]["items"][:2], [{"title": "Queries", "value": "?", "subtitle": "24 h"},
                                                        {"title": "Blocked", "value": "?"}])
        self.assertEqual([i["title"] for i in out["cards"][1]["items"]], ["tracker.example.org"])
        self.assertEqual([p["id"] for p in out["problems"]], ["Pi-hole:blocking"])

    def test_wrong_app_password_is_one_warning(self):
        with FakeUpstream(recording("auth-failed")) as up:
            runner = run(up)
            self.assertEqual([r["path"] for r in up.requests], ["/api/auth"])
        out = runner.merged()
        self.assertEqual(out["problems"], [{"id": "Pi-hole:source", "severity": "warning",
                                            "text": "Pi-hole: 401 (check the app password)",
                                            "since": out["problems"][0]["since"]}])
        self.assertEqual(out["cards"], [])
        self.assertNotIn(PASSWORD, json.dumps(out))

    def test_unset_password_variable(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up, env={})
            self.assertEqual(up.requests, [])
        self.assertEqual(runner.states["Pi-hole"].error, "PIHOLE_PW is not set")

    def test_too_many_sessions(self):
        busy = routes(**{"POST /api/auth": {"status": 429, "json": {"error": {"key": "api_seats_exceeded"}}}})
        with FakeUpstream(busy) as up:
            self.assertEqual(run(up).states["Pi-hole"].error, "429 (too many logins or sessions)")

    def test_logout_even_when_a_read_fails(self):
        broken = routes(**{"GET /api/dns/blocking": {"status": 500, "body": "oops"}})
        with FakeUpstream(broken) as up:
            runner = run(up)
            self.assertEqual(up.requests[-1]["method"], "DELETE")
            self.assertEqual(header(up.requests[-1], "X-FTL-SID"), SID)
        self.assertEqual(runner.states["Pi-hole"].error, "500")

    def test_without_a_password_no_login(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up, key_env=None)
            self.assertEqual([(r["method"], r["path"]) for r in up.requests][0], ("GET", "/api/stats/summary"))
            self.assertFalse(any(header(r, "X-FTL-SID") for r in up.requests))
            self.assertNotIn("DELETE", [r["method"] for r in up.requests])
        self.assertIsNone(runner.states["Pi-hole"].error)

    def test_a_session_without_sid_is_not_logged_out(self):
        open_ = routes(**{"POST /api/auth": {"json": {"session": {"valid": True, "totp": False, "sid": None,
                                                                    "validity": -1}}}})
        with FakeUpstream(open_) as up:
            self.assertIsNone(run(up).states["Pi-hole"].error)
            self.assertNotIn("DELETE", [r["method"] for r in up.requests])
        refused = routes(**{"POST /api/auth": {"json": {"session": {"valid": False, "message": "password incorrect"}}}})
        with FakeUpstream(refused) as up:
            self.assertEqual(run(up).states["Pi-hole"].error, "login refused: password incorrect")

    def test_pause_and_resume(self):
        with FakeUpstream(recording("normal")) as up:
            spec = sources.parse([{"name": "Pi-hole", "type": "pihole", "url": up.url, "key_env": "PIHOLE_PW",
                                   "actions": {"pause": [5, 15]}}], ENV)[0]
            runner = sources.Runner([spec])
            self.assertEqual(runner.actions.run("dns-pause", {"arg": "Pi-hole:15"}),
                             (200, {"ok": True, "text": "Pi-hole: blocking paused for 15 min"}))
            self.assertEqual([(r["method"], r["path"]) for r in up.requests],
                             [("POST", "/api/auth"), ("POST", "/api/dns/blocking"), ("DELETE", "/api/auth")])
            self.assertEqual(json.loads(up.requests[1]["body"]), {"blocking": False, "timer": 900})
            self.assertEqual(header(up.requests[1], "X-FTL-SID"), SID)
            code, body = runner.actions.run("dns-pause", {"arg": "Pi-hole:on"})
            self.assertEqual((code, body["text"]), (200, "Pi-hole: blocking is on again"))
            self.assertEqual(json.loads(up.requests[4]["body"]), {"blocking": True, "timer": None})
            self.assertEqual(runner.actions.run("dns-pause", {"arg": "Pi-hole:30"})[0], 400)   # not listed
            self.assertEqual(len(up.requests), 6)

    def test_config_checks(self):
        for raw, words in [({"top": -1}, "top"), ({"top": "5"}, "top"), ({"url": None}, "url is required"),
                           ({"actions": ["pause"]}, "actions must be"), ({"actions": {"stop": [1]}}, "actions must be"),
                           ({"actions": {"pause": [0]}}, "minutes"), ({"actions": {"pause": ["5"]}}, "minutes"),
                           ({"actions": {"pause": [241]}}, "minutes")]:
            with self.subTest(raw=raw):
                cfg = dict({"name": "Pi-hole", "type": "pihole", "url": "http://192.0.2.53"}, **raw)
                with self.assertRaisesRegex(ValueError, words):
                    sources.parse([{k: v for k, v in cfg.items() if v is not None}], ENV)


if __name__ == "__main__":
    unittest.main()
