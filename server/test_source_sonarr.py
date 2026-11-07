#!/usr/bin/env python3
"""Tests for the Sonarr source (server/sources/sonarr.py, shared code in sources/_arr.py) against
server/recordings/sonarr/. Run from the repo root:

    python3 -m unittest -v server/test_source_sonarr.py
"""

import datetime
import hashlib
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

KEY = "made-up-sonarr-key-0123456789abcdef"
ENV = {"SONARR_KEY": KEY}
TODAY = datetime.date(2026, 11, 7)


def recording(case):
    return os.path.join(HERE, "recordings", "sonarr", case + ".json")


def header(req, name):
    return {k.lower(): v for k, v in req["headers"].items()}.get(name.lower())


def local(utc):
    """What `due` should be for an upstream UTC time, in this machine's zone."""
    t = datetime.datetime.fromisoformat(utc.replace("Z", "+00:00"))
    return t.astimezone().strftime("%Y-%m-%dT%H:%M")


def run(up, **cfg):
    raw = dict({"name": "Sonarr", "type": "sonarr", "url": up.url, "key_env": "SONARR_KEY"}, **cfg)
    spec = sources.parse([raw], ENV)[0]
    runner = sources.Runner([spec])
    with mock.patch.object(_arr, "today", lambda: TODAY):
        runner.run_one(spec)
    return runner


class SonarrSource(unittest.TestCase):
    def test_normal(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(up)
        self.assertIsNone(runner.states["Sonarr"].error)
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"]) for p in out["problems"]], [
            ("Sonarr:health-DownloadClientCheck", "problem"), ("Sonarr:health-IndexerStatusCheck", "warning"),
            ("Sonarr:queue-102", "warning")])
        self.assertEqual(out["problems"][0]["text"],
                         "Sonarr: Unable to communicate with Torrents. Connection refused (192.0.2.20:8080)")
        self.assertEqual(out["problems"][2]["text"],
                         "Sonarr: Lantern Test S01E01: Import blocked: Not an upgrade for existing episode file(s)")
        queue, calendar = out["cards"]
        self.assertEqual((queue["id"], queue["style"], queue["place"], queue["subtitle"]),
                         ("Sonarr:queue", "list", "lab", "3 in the queue"))
        self.assertEqual(queue["items"], [
            {"title": "Placeholder Show S02E05", "subtitle": "Downloading", "progress": 0.75, "value": "12 min"},
            {"title": "Lantern Test S01E01", "subtitle": "Import blocked: Not an upgrade for existing episode file(s)",
             "progress": 1.0, "value": "100 %", "tint": "orange"},
            {"title": "Placeholder Show S02E06", "subtitle": "Queued", "progress": 0.0, "value": "0 %"}])
        self.assertEqual((calendar["id"], calendar["style"]), ("Sonarr:calendar", "countdown"))
        self.assertNotIn("place", calendar)
        self.assertEqual(calendar["items"], [
            {"title": "Placeholder Show", "subtitle": "S02E06 · The Third Test", "due": local("2026-11-08T02:00:00Z")},
            {"title": "Lantern Test", "subtitle": "S01E03 · Third Lamp", "due": local("2026-11-10T20:00:00Z")}])

    def test_requests_and_key(self):
        with FakeUpstream(recording("normal")) as up:
            out = run(up).merged()
            reqs = up.requests
        self.assertEqual([r["path"] for r in reqs], [
            "/api/v3/health", "/api/v3/queue?page=1&pageSize=10&includeSeries=true&includeEpisode=true",
            "/api/v3/calendar?start=2026-11-07&end=2026-11-14&includeSeries=true"])
        self.assertEqual({r["method"] for r in reqs}, {"GET"})
        for r in reqs:
            self.assertEqual(header(r, "X-Api-Key"), KEY)
            self.assertNotIn("apikey", r["path"].lower())
        self.assertNotIn(KEY, json.dumps(out))

    def test_queue_and_calendar_can_be_off(self):
        with FakeUpstream(recording("normal")) as up:
            out = run(up, queue=0, calendar_days=0).merged()
            self.assertEqual([r["path"] for r in up.requests], ["/api/v3/health"])
        self.assertEqual(out["cards"], [])
        with FakeUpstream(recording("normal")) as up:
            run(up, queue=3, calendar_days=1)
            self.assertIn("pageSize=3", up.requests[1]["path"])
            self.assertIn("end=2026-11-08", up.requests[2]["path"])

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("odd")) as up:
            runner = run(up)
        self.assertIsNone(runner.states["Sonarr"].error)
        out = runner.merged()
        self.assertEqual([p["id"] for p in out["problems"]], [
            "Sonarr:health-5", "Sonarr:health-IndexerStatusCheck",
            "Sonarr:health-IndexerStatusCheck-" + hashlib.sha256(b"second").hexdigest()[:8],
            "Sonarr:queue-9"])
        self.assertEqual([c["id"] for c in out["cards"]], ["Sonarr:queue"])
        self.assertEqual(out["cards"][0]["items"], [
            {"title": "Raw.Release.Name", "subtitle": "Queued"},
            {"title": "Zero.Size", "subtitle": "Downloading: disk full", "value": "1 d 2 h", "tint": "red"}])
        self.assertEqual(out["cards"][0]["subtitle"], "2 in the queue")

    def test_wrong_key_is_one_warning(self):
        with FakeUpstream(recording("auth-failed")) as up:
            out = run(up).merged()
            self.assertEqual(len(up.requests), 1)
        self.assertEqual([(p["id"], p["text"]) for p in out["problems"]], [("Sonarr:source", "Sonarr: 401")])
        self.assertEqual(out["cards"], [])

    def test_empty_queue(self):
        with FakeUpstream({"routes": {"GET /api/v3/health": {"json": []},
                                      "GET /api/v3/queue": {"json": {"totalRecords": 0, "records": []}},
                                      "GET /api/v3/calendar": {"json": []}}}) as up:
            out = run(up).merged()
        self.assertEqual(out["problems"], [])
        self.assertEqual([(c["id"], c["subtitle"], c["items"]) for c in out["cards"]],
                         [("Sonarr:queue", "Nothing in the queue", [])])

    def test_time_helpers(self):
        self.assertEqual([_arr.timeleft(t) for t in ("00:12:30", "00:00:20", "02:10:00", "03:00:00", "1.02:03:04",
                                                     "2.00:00:00", "garbage", None, "00:12")],
                         ["12 min", "1 min", "2 h 10 min", "3 h", "1 d 2 h", "2 d", "", "", ""])
        self.assertIsNone(_arr.local_time("soon"))
        self.assertEqual(_arr.local_time("2026-11-08T02:00:00"), local("2026-11-08T02:00:00Z"))
        self.assertEqual([_arr.day(d) for d in ("2026-11-10T00:00:00Z", "2026-11-10", "20261110", "2026-13-01", 5)],
                         ["2026-11-10", "2026-11-10", None, None, None])

    def test_config_checks(self):
        for raw, words in [({"key_env": None}, "key_env is required"), ({"queue": 99}, "queue"),
                           ({"calendar_days": -1}, "calendar_days"), ({"actions": {"pause": [5]}}, "has no actions")]:
            with self.subTest(raw=raw):
                cfg = dict({"name": "Sonarr", "type": "sonarr", "url": "http://192.0.2.30:8989",
                            "key_env": "SONARR_KEY"}, **raw)
                with self.assertRaisesRegex(ValueError, words):
                    sources.parse([{k: v for k, v in cfg.items() if v is not None}], ENV)


if __name__ == "__main__":
    unittest.main()
