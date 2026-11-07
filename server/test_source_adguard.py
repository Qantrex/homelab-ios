#!/usr/bin/env python3
"""Tests for the AdGuard Home source (server/sources/adguard.py) against server/recordings/adguard/. Run from the repo
root:

    python3 -m unittest -v server/test_source_adguard.py
"""

import base64
import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sources  # noqa: E402
from fake_upstream import FakeUpstream, load  # noqa: E402

PASSWORD = "made-up-adguard-password-0123"
ENV = {"ADGUARD_PW": PASSWORD}


def recording(case):
    return os.path.join(HERE, "recordings", "adguard", case + ".json")


def routes(case="normal", **changes):
    r = copy.deepcopy(load(recording(case)))
    r.update(changes)
    return {"routes": r}


def header(req, name):
    return {k.lower(): v for k, v in req["headers"].items()}.get(name.lower())


def parse(url, env=None, **cfg):
    raw = dict({"name": "AdGuard", "type": "adguard", "url": url, "username": "monitor", "password_env": "ADGUARD_PW"},
               **cfg)
    return sources.parse([{k: v for k, v in raw.items() if v is not None}], ENV if env is None else env)[0]


def run(up, env=None, **cfg):
    spec = parse(up.url, env, **cfg)
    runner = sources.Runner([spec])
    runner.run_one(spec)
    return runner


class AdGuardSource(unittest.TestCase):
    def test_normal(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up)
            reqs = up.requests
        self.assertIsNone(runner.states["AdGuard"].error)
        out = runner.merged()
        self.assertEqual(out["problems"], [])
        dns, top = out["cards"]
        self.assertEqual((dns["id"], dns["style"], dns["place"]), ("AdGuard:dns", "metrics", "lab"))
        self.assertEqual(dns["items"], [{"title": "Queries", "value": "23.4k", "subtitle": "24 h"},
                                        {"title": "Blocked", "value": "18.4 %"},
                                        {"title": "Blocking", "value": "on"}])
        self.assertEqual([(i["title"], i["value"]) for i in top["items"]],
                         [("ads.example.net", "812"), ("tracker.example.org", "640"), ("telemetry.example.com", "377")])
        self.assertEqual([(r["method"], r["path"]) for r in reqs], [("GET", "/control/status"), ("GET", "/control/stats")])

    def test_basic_auth_goes_out_and_nowhere_else(self):
        with FakeUpstream(recording("normal")) as up:
            out = run(up).merged()
            auth = header(up.requests[0], "Authorization")
        self.assertEqual(base64.b64decode(auth.split(" ", 1)[1]).decode(), "monitor:" + PASSWORD)
        self.assertTrue(auth.startswith("Basic "))
        self.assertNotIn(PASSWORD, json.dumps(out))
        with FakeUpstream(recording("normal")) as up:
            run(up, username=None, password_env=None)
            self.assertIsNone(header(up.requests[0], "Authorization"))

    def test_paused_and_off(self):
        paused = routes(**{"GET /control/status": {"json": {"protection_enabled": False, "running": True,
                                                            "protection_disabled_duration": 600000}}})
        with FakeUpstream(paused) as up:
            out = run(up, actions=["pause"]).merged()
        self.assertEqual(out["problems"], [])
        self.assertEqual(out["cards"][0]["items"][2], {"title": "Blocking", "value": "off · 10 min", "tint": "orange",
                                                       "action": {"name": "adguard-pause", "label": "Resume",
                                                                  "arg": "on"}})
        off = routes(**{"GET /control/status": {"json": {"protection_enabled": False, "running": True,
                                                         "protection_disabled_duration": 0}}})
        with FakeUpstream(off) as up:
            out = run(up).merged()
        self.assertEqual([(p["id"], p["text"]) for p in out["problems"]],
                         [("AdGuard:blocking", "AdGuard: ad blocking is off")])
        self.assertNotIn("action", out["cards"][0]["items"][2])

    def test_days_window(self):
        week = routes(**{"GET /control/stats": {"json": {"time_units": "days", "num_dns_queries": 150000,
                                                         "num_blocked_filtering": 30000,
                                                         "dns_queries": [20000] * 7}}})
        with FakeUpstream(week) as up:
            items = run(up).merged()["cards"][0]["items"]
        self.assertEqual(items[:2], [{"title": "Queries", "value": "150k", "subtitle": "7 days"},
                                     {"title": "Blocked", "value": "20.0 %"}])

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("odd")) as up:
            runner = run(up)
        self.assertIsNone(runner.states["AdGuard"].error)
        out = runner.merged()
        self.assertEqual(out["cards"][0]["items"][:2], [{"title": "Queries", "value": "?"},
                                                        {"title": "Blocked", "value": "?"}])
        self.assertEqual([i["title"] for i in out["cards"][1]["items"]], ["tracker.example.org"])
        self.assertEqual(sorted(p["id"] for p in out["problems"]), ["AdGuard:blocking", "AdGuard:running"])

    def test_wrong_password_is_one_warning(self):
        with FakeUpstream(recording("auth-failed")) as up:
            out = run(up).merged()
        self.assertEqual([(p["id"], p["text"]) for p in out["problems"]], [("AdGuard:source", "AdGuard: 401")])
        self.assertEqual(out["cards"], [])

    def test_pause_and_resume(self):
        with FakeUpstream(recording("normal")) as up:
            spec = parse(up.url, actions=["pause"])
            runner = sources.Runner([spec])
            self.assertEqual(runner.act("adguard-pause", "5"),
                             (200, {"ok": True, "text": "AdGuard: protection paused for 5 min"}))
            self.assertEqual((up.requests[0]["method"], up.requests[0]["path"]), ("POST", "/control/protection"))
            self.assertEqual(json.loads(up.requests[0]["body"]), {"enabled": False, "duration": 300000})
            self.assertTrue(header(up.requests[0], "Authorization").startswith("Basic "))
            runner.act("adguard-pause", "on")
            self.assertEqual(json.loads(up.requests[1]["body"]), {"enabled": True})

    def test_config_checks(self):
        for raw, words in [({"password_env": None}, "username needs password_env"), ({"top": 99}, "top"),
                           ({"url": None}, "url is required"), ({"password": "x"}, "looks like a secret")]:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, words):
                    parse(raw.pop("url", "http://192.0.2.54:3000"), **raw)


if __name__ == "__main__":
    unittest.main()
