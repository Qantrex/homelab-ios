#!/usr/bin/env python3
"""Tests for the Radarr source (server/sources/radarr.py, shared code in sources/_arr.py) against
server/recordings/radarr/. Run from the repo root:

    python3 -m unittest -v server/test_source_radarr.py
"""

import datetime
import json
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sources  # noqa: E402
from sources import _arr  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402

KEY = "made-up-radarr-key-0123456789abcdef"
ENV = {"RADARR_KEY": KEY}
TODAY = datetime.date(2026, 11, 7)


def recording(case):
    return os.path.join(HERE, "recordings", "radarr", case + ".json")


def header(req, name):
    return {k.lower(): v for k, v in req["headers"].items()}.get(name.lower())


def run(up, today=TODAY, **cfg):
    raw = dict({"name": "Radarr", "type": "radarr", "url": up.url, "key_env": "RADARR_KEY"}, **cfg)
    spec = sources.parse([raw], ENV)[0]
    runner = sources.Runner([spec])
    with mock.patch.object(_arr, "today", lambda: today):
        runner.run_one(spec)
    return runner


class RadarrSource(unittest.TestCase):
    def test_normal(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up)
            reqs = up.requests
        self.assertIsNone(runner.states["Radarr"].error)
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]], [
            ("Radarr:health-RootFolderCheck", "warning", "Radarr: Missing root folder: /media/movies"),
            ("Radarr:queue-202", "warning", "Radarr: Demo Picture (2026): Failed: Download failed: not enough seeders")])
        queue, calendar = out["cards"]
        self.assertEqual((queue["id"], queue["place"], queue["icon"], queue["subtitle"]),
                         ("Radarr:queue", "lab", "film", "2 in the queue"))
        self.assertEqual(queue["items"], [
            {"title": "Sample Film (2025)", "subtitle": "Downloading", "progress": 0.75, "value": "2 h 10 min"},
            {"title": "Demo Picture (2026)", "subtitle": "Failed: Download failed: not enough seeders",
             "progress": 0.0, "value": "0 %", "tint": "red"}])
        self.assertEqual((calendar["id"], calendar["style"]), ("Radarr:calendar", "countdown"))
        self.assertEqual(calendar["items"], [
            {"title": "Sample Film Two", "subtitle": "Digital release", "due": "2026-11-09"},
            {"title": "Same Day Twice", "subtitle": "Digital release", "due": "2026-11-11"},
            {"title": "Example Premiere", "subtitle": "In cinemas", "due": "2026-11-12"}])
        self.assertEqual([r["path"] for r in reqs], [
            "/api/v3/health", "/api/v3/queue?page=1&pageSize=10&includeMovie=true",
            "/api/v3/calendar?start=2026-11-07&end=2026-11-14"])
        for r in reqs:
            self.assertEqual(header(r, "X-Api-Key"), KEY)
        self.assertNotIn(KEY, json.dumps(out))

    def test_only_releases_inside_the_window(self):
        with FakeUpstream(recording("normal")) as up:
            items = run(up, today=datetime.date(2026, 11, 20), calendar_days=14).merged()["cards"][1]["items"]
        self.assertEqual(items, [{"title": "Sample Film Two", "subtitle": "Disc release", "due": "2026-12-01"}])
        with FakeUpstream(recording("normal")) as up:
            cards = run(up, today=datetime.date(2027, 1, 1)).merged()["cards"]
        self.assertEqual([c["id"] for c in cards], ["Radarr:queue"])

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("odd")) as up:
            runner = run(up)
        self.assertIsNone(runner.states["Radarr"].error)
        out = runner.merged()
        self.assertEqual(out["problems"], [])
        queue, calendar = out["cards"]
        self.assertEqual((queue["subtitle"], queue["items"]), ("Nothing in the queue", []))
        self.assertEqual(calendar["items"], [{"title": "Only Cinemas", "subtitle": "In cinemas", "due": "2026-11-13"}])

    def test_wrong_key_is_one_warning(self):
        with FakeUpstream({"routes": {"GET /api/v3/health": {"status": 401, "body": ""}}}) as up:
            out = run(up).merged()
        self.assertEqual([(p["id"], p["text"]) for p in out["problems"]], [("Radarr:source", "Radarr: 401")])
        self.assertEqual(out["cards"], [])


if __name__ == "__main__":
    unittest.main()
