#!/usr/bin/env python3
"""Tests for the source status in /info (docs/plans/MODULAR.md M1.2, docs/API.md#source-status-sources-in-info).
Run from the repo root:

    python3 -m unittest -v server/test_source_status.py

Stdlib only; the upstream is server/fake_upstream.py replaying a made-up recording on 127.0.0.1.
"""

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402
import sources  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None

SECRET = "st4tus-key-0123456789abcdef"
ENV = {"LAB_KEY": SECRET}
NORMAL = os.path.join(HERE, "recordings", "example", "normal.json")
ROW_KEYS = {"name", "type", "state", "error", "checked", "last_ok", "insecure"}
T1, T2, T3 = "2026-11-07T08:00:00+01:00", "2026-11-07T09:00:00+01:00", "2026-11-07T10:00:00+01:00"

# Test-only source types: one that fails while _FAIL holds an error text, one that hangs until released.
_FAIL = {}
_release = threading.Event()


def _flip(cfg, fetch):
    if cfg["name"] in _FAIL:
        raise sources.SourceError(_FAIL[cfg["name"]] % {"key": fetch.secret()})
    return {"problems": [], "hosts": [{"id": "h"}]}


def _hang(cfg, fetch):
    _release.wait(5)
    return {}


sources.register("st-flip", types.SimpleNamespace(collect=_flip))
sources.register("st-hang", types.SimpleNamespace(collect=_hang))


def spec(name, kind="st-flip", **cfg):
    raw = dict({"name": name, "type": kind, "key_env": "LAB_KEY"}, **cfg)
    return sources.parse([raw], ENV)[0]


def run_at(runner, s, stamp):
    with mock.patch.object(sources, "now_iso", return_value=stamp):
        runner.run_one(s)


class StatusRows(unittest.TestCase):
    """Runner.status(): what /info lists under `sources`."""

    def setUp(self):
        _FAIL.clear()
        self.addCleanup(_FAIL.clear)

    def test_never_ok_failing_ok(self):
        s = spec("Kuma")
        runner = sources.Runner([s])
        self.assertEqual(runner.status(), [{"name": "Kuma", "type": "st-flip", "state": "never"}])
        run_at(runner, s, T1)
        self.assertEqual(runner.status(), [{"name": "Kuma", "type": "st-flip", "state": "ok",
                                            "checked": T1, "last_ok": T1}])
        _FAIL["Kuma"] = "401"
        run_at(runner, s, T2)
        self.assertEqual(runner.status(), [{"name": "Kuma", "type": "st-flip", "state": "failing", "error": "401",
                                            "checked": T2, "last_ok": T1}])   # the last good run is kept
        del _FAIL["Kuma"]
        run_at(runner, s, T3)
        self.assertEqual(runner.status(), [{"name": "Kuma", "type": "st-flip", "state": "ok",
                                            "checked": T3, "last_ok": T3}])

    def test_failing_from_the_start_has_no_last_ok(self):
        s = spec("Kuma")
        _FAIL["Kuma"] = "connection refused"
        runner = sources.Runner([s])
        run_at(runner, s, T1)
        self.assertEqual(runner.status(), [{"name": "Kuma", "type": "st-flip", "state": "failing",
                                            "error": "connection refused", "checked": T1}])

    def test_the_error_matches_the_warning_and_holds_no_key_or_url(self):
        s = spec("Kuma")
        _FAIL["Kuma"] = "401 from http://192.0.2.10:3001/api?k=%(key)s with %(key)s\nand a second line " + "x" * 200
        runner = sources.Runner([s])
        runner.run_one(s)
        error = runner.status()[0]["error"]
        self.assertNotIn(SECRET, error)
        self.assertNotIn("http", error)
        self.assertNotIn("\n", error)
        self.assertTrue(error.startswith("401 from <url> with *** and a second line"), error)
        self.assertLessEqual(len(error), sources.MAX_ERROR)
        self.assertEqual(runner.merged()["problems"][0]["text"], "Kuma: " + error)

    def test_a_crash_is_failing_too(self):
        s = spec("Lab", "st-flip")
        runner = sources.Runner([s])
        with mock.patch.object(sources.Fetch, "secret", side_effect=RuntimeError("boom " + SECRET)):
            _FAIL["Lab"] = "%(key)s"
            runner.run_one(s)
        row = runner.status()[0]
        self.assertEqual((row["state"], row["error"]), ("failing", "RuntimeError: boom ***"))

    def test_insecure_only_when_true(self):
        runner = sources.Runner([spec("pve1", url="https://192.0.2.20:8006", insecure=True),
                                 spec("Kuma", url="https://192.0.2.10"), spec("Lab", insecure=False)])
        rows = runner.status()
        self.assertEqual([r["name"] for r in rows], ["pve1", "Kuma", "Lab"])   # config order
        self.assertIs(rows[0]["insecure"], True)
        self.assertNotIn("insecure", rows[1])
        self.assertNotIn("insecure", rows[2])

    def test_a_hung_first_run_is_failing_with_timeout(self):
        _release.clear()
        self.addCleanup(_release.set)
        s = spec("Slow", "st-hang", every=1, timeout=0.1)
        runner = sources.Runner([s])
        runner.tick()   # starts the run in its own thread
        self.assertEqual(runner.status()[0]["state"], "never")   # running, still within its time
        row = wait_for(lambda: runner.status()[0]["state"] == "failing" and runner.status()[0], timeout=5)
        self.assertEqual(row, {"name": "Slow", "type": "st-hang", "state": "failing", "error": "timeout"})

    def test_only_documented_keys(self):
        s = spec("Kuma", insecure=True)
        runner = sources.Runner([s])
        runner.run_one(s)
        _FAIL["Kuma"] = "500"
        runner.run_one(s)
        self.assertEqual(set(runner.status()[0]), ROW_KEYS)   # failing after a good run, insecure: every key


def openapi_source_status():
    """The property names and the `state` enum of SourceStatus in server/openapi.yaml (a plain text read)."""
    with open(os.path.join(HERE, "openapi.yaml"), encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    start = lines.index("    SourceStatus:")
    block = []
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= 4:
            break
        block.append(line)
    props = [m.group(1) for m in (re.match(r"^ {8}([a-z_]+):", x) for x in block) if m]
    required = re.search(r"required: \[([^\]]*)\]", "\n".join(block)).group(1)
    enum = re.search(r"enum: \[([^\]]*)\]", "\n".join(block)).group(1)
    return set(props), {x.strip() for x in required.split(",")}, {x.strip() for x in enum.split(",")}


class InfoSources(unittest.TestCase):
    """GET /info lists the sources only when the server has some."""

    def setUp(self):
        _FAIL.clear()
        self.addCleanup(_FAIL.clear)

    def start(self, raw_sources, wait=True):
        raw = {"name": "bridge", "tokens": [TOKEN], "interval": 60,
               "this_host": {"id": "box", "disks": ["/"], "docker": False},
               "thresholds": {"temp_warning": 1000, "disk_warning": 1000, "disk_problem": 1001}}
        if raw_sources is not None:
            raw["sources"] = raw_sources
        app = rs.RealApp(rs.Config(raw, env=ENV))
        if app.sources:
            app.sources.tick_seconds = 0.05
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        if wait:
            wait_for(lambda: app.collector.runs >= 1 and
                     all(st.runs >= 1 for st in (app.sources.states.values() if app.sources else [])))
        return httpd.server_address[1]

    def upstream(self):
        up = FakeUpstream(NORMAL).start()
        self.addCleanup(up.stop)
        return up.url

    def test_info_lists_each_source(self):
        _FAIL["Kuma"] = "401"
        port = self.start([{"name": "Lab", "type": "example", "url": self.upstream(), "key_env": "LAB_KEY"},
                           {"name": "Kuma", "type": "st-flip", "key_env": "LAB_KEY"},
                           {"name": "pve1", "type": "example", "url": self.upstream(), "key_env": "LAB_KEY",
                            "insecure": True}])
        code, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertEqual(code, 200)
        self.assertEqual(list(info), ["api", "name", "server", "version", "features", "auth", "sources"])
        rows = info["sources"]
        self.assertEqual([(r["name"], r["type"], r["state"]) for r in rows],
                         [("Lab", "example", "ok"), ("Kuma", "st-flip", "failing"), ("pve1", "example", "ok")])
        self.assertEqual(rows[0]["checked"], rows[0]["last_ok"])
        self.assertNotIn("error", rows[0])
        self.assertEqual(rows[1]["error"], "401")
        self.assertNotIn("last_ok", rows[1])
        self.assertIs(rows[2]["insecure"], True)
        self.assertNotIn("insecure", rows[0])
        for r in rows:
            self.assertLessEqual(set(r), ROW_KEYS)
            self.assertIsNotNone(datetime.datetime.fromisoformat(r["checked"]).tzinfo)   # a time with a zone
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertIn("Kuma: 401", [p["text"] for p in state["problems"]])   # the same text as the warning

    def test_a_source_that_has_not_run_yet_is_never(self):
        _release.clear()
        self.addCleanup(_release.set)
        port = self.start([{"name": "Slow", "type": "st-hang", "every": 60, "key_env": "LAB_KEY"}], wait=False)
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertEqual(info["sources"], [{"name": "Slow", "type": "st-hang", "state": "never"}])

    def test_the_key_is_not_in_info(self):
        _FAIL["Leak"] = "denied for %(key)s at http://192.0.2.10/?token=%(key)s"
        port = self.start([{"name": "Leak", "type": "st-flip", "key_env": "LAB_KEY"}])
        code, resp, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        text = json.dumps(info) + json.dumps(dict(resp.getheaders()))
        self.assertNotIn(SECRET, text)
        self.assertNotIn("LAB_KEY", text)
        self.assertNotIn("192.0.2.10", text)
        self.assertEqual(info["sources"][0]["error"], "denied for *** at <url>")

    def test_without_sources_info_has_no_field(self):
        for raw_sources in (None, []):
            with self.subTest(sources=raw_sources):
                port = self.start(raw_sources)
                _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
                self.assertEqual(list(info), ["api", "name", "server", "version", "features", "auth"])

    def test_rows_match_openapi(self):
        props, required, states = openapi_source_status()
        self.assertEqual(props, ROW_KEYS)
        self.assertEqual(required, {"name", "type", "state"})
        self.assertEqual(states, {"ok", "failing", "never"})
        with open(os.path.join(HERE, "openapi.yaml"), encoding="utf-8") as fh:
            self.assertIn('items: { $ref: "#/components/schemas/SourceStatus" }', fh.read())

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_accepts_it_and_warns(self):
        _FAIL["Kuma"] = "401"
        port = self.start([{"name": "Lab", "type": "example", "url": self.upstream(), "key_env": "LAB_KEY",
                            "insecure": True},
                           {"name": "Kuma", "type": "st-flip", "key_env": "LAB_KEY"}])
        script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
        res = subprocess.run(["bash", script, "-v", "--token", TOKEN, "http://127.0.0.1:%d" % port],
                             capture_output=True, text=True, timeout=60)
        out = res.stdout + res.stderr
        self.assertEqual(res.returncode, 0, out)
        self.assertIn("source Kuma is failing: 401", out)
        self.assertIn("source Lab skips the TLS certificate check", out)
        self.assertNotIn(SECRET, out)


if __name__ == "__main__":
    unittest.main()
