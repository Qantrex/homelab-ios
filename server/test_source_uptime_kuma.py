#!/usr/bin/env python3
"""Tests for the Uptime Kuma source (server/sources/uptime_kuma.py) against its recordings. Run from the repo root:

    python3 -m unittest -v server/test_source_uptime_kuma.py

Also runs the sample config server/examples/sources-monitors.json (Kuma and Gatus) through scripts/check-live-api.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402
import sources  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None


def recording(kind, case):
    return os.path.join(HERE, "recordings", kind, case + ".json")


def run_kuma(case, **cfg):
    """Run the source once against a recording; returns (merged result, runner, the requests it made)."""
    with FakeUpstream(recording("uptime-kuma", case)) as up:
        spec = sources.parse([dict({"name": "Kuma", "type": "uptime-kuma", "url": up.url, "slug": "home"}, **cfg)],
                             {})[0]
        runner = sources.Runner([spec])
        runner.run_one(spec)
        return runner.merged(), runner, list(up.requests)


def problems(out):
    return [(p["id"], p["severity"], p["text"]) for p in out["problems"]]


class UptimeKumaSource(unittest.TestCase):
    """Down monitors are problems, pending, slow and expiring certificates warnings, one card, no key."""

    def test_normal(self):
        out, runner, reqs = run_kuma("normal", services=True)
        self.assertIsNone(runner.states["Kuma"].error)
        self.assertEqual([r["path"] for r in reqs], ["/api/status-page/home", "/api/status-page/heartbeat/home"])
        self.assertEqual(problems(out), [
            ("Kuma:monitor-1", "problem", "Jellyfin: down"),
            ("Kuma:monitor-3", "warning", "Gitea: pending"),
            ("Kuma:cert-6", "warning", "Nextcloud: certificate expires in 5 d"),
            ("Kuma:incident-2", "problem", "Kuma: Power cut in the rack")])
        self.assertEqual(out["hosts"], [])
        card = out["cards"][0]
        self.assertEqual((card["id"], card["title"], card["subtitle"], card["place"], card["style"]),
                         ("Kuma:monitors", "Home lab", "3 of 6 up", "lab", "list"))
        self.assertEqual([(i["title"], i["value"], i["tint"]) for i in card["items"]], [
            ("Jellyfin", "down", "red"), ("Vaultwarden", "up", "green"), ("Gitea", "pending", "orange"),
            ("Nextcloud", "up", "green"), ("pve1", "up", "green"), ("Backup NAS", "maintenance", "gray")])
        self.assertEqual(card["items"][1]["subtitle"], "Services · 100 % in 24 h · 88 ms")
        self.assertEqual(card["items"][3]["subtitle"], "Services · 99.81 % in 24 h · 2310 ms")
        self.assertEqual(card["items"][0]["subtitle"], "Services · 95.83 % in 24 h")
        self.assertEqual([(s["name"], s["url"], s["group"]) for s in out["services"]],
                         [("Jellyfin", "http://192.0.2.10:8096", "Kuma"),
                          ("Vaultwarden", "https://nas.tail1234.ts.net", "Kuma")])

    def test_no_key_and_no_cookie_is_sent(self):
        _, _, reqs = run_kuma("normal")
        for r in reqs:
            names = {k.lower() for k in r["headers"]}
            self.assertNotIn("authorization", names)
            self.assertNotIn("cookie", names)
            self.assertEqual(r["method"], "GET")

    def test_slow_ms(self):
        out, _, _ = run_kuma("normal", slow_ms=2000)
        self.assertIn(("Kuma:monitor-6", "warning", "Nextcloud: slow (2310 ms)"), problems(out))
        item = out["cards"][0]["items"][3]
        self.assertEqual((item["value"], item["tint"]), ("slow", "orange"))
        self.assertEqual(out["cards"][0]["subtitle"], "3 of 6 up")
        out, _, _ = run_kuma("normal", slow_ms=3000)
        self.assertNotIn("Kuma:monitor-6", [p["id"] for p in out["problems"]])

    def test_cert_days_and_services_options(self):
        out, _, _ = run_kuma("normal", cert_days=0)   # services: false by default
        self.assertNotIn("Kuma:cert-6", [p["id"] for p in out["problems"]])
        self.assertEqual(out["services"], [])
        out, _, _ = run_kuma("normal", cert_days=90)
        self.assertIn(("Kuma:cert-2", "warning", "Vaultwarden: certificate expires in 61 d"), problems(out))

    def test_version_1(self):
        out, runner, _ = run_kuma("v1", services=True)
        self.assertIsNone(runner.states["Kuma"].error)
        self.assertEqual(problems(out), [("Kuma:monitor-13", "problem", "Printer: down"),
                                         ("Kuma:incident-1", "warning", "Kuma: Slow uplink tonight")])
        self.assertEqual(out["cards"][0]["subtitle"], "2 of 3 up")
        self.assertEqual([s["name"] for s in out["services"]], ["Pi-hole"])

    def test_odd_never_crashes(self):
        out, runner, _ = run_kuma("odd", slow_ms=1)
        self.assertIsNone(runner.states["Kuma"].error)
        self.assertEqual(out["problems"], [])
        card = out["cards"][0]
        self.assertEqual((card["title"], card["subtitle"]), ("Kuma", "1 of 4 up"))
        self.assertEqual([(i["title"], i["value"]) for i in card["items"]],
                         [("Router", "up"), ("404", "no data"), ("No beats yet", "no data"), ("Junk beats", "no data")])
        self.assertEqual(out["services"], [])

    def test_slug_not_found_is_one_warning(self):
        out, runner, reqs = run_kuma("not-found")
        self.assertEqual(problems(out), [("Kuma:source", "warning", "Kuma: status page home not found")])
        self.assertEqual((out["cards"], out["services"]), ([], []))
        self.assertEqual(len(reqs), 1)

    def test_server_error_is_one_warning(self):
        with FakeUpstream({"routes": {"GET /api/status-page/home": {"status": 403, "json": {"status": "fail",
                                                                                              "msg": "x"}}}}) as up:
            spec = sources.parse([{"name": "Kuma", "type": "uptime-kuma", "url": up.url, "slug": "home"}], {})[0]
            runner = sources.Runner([spec])
            runner.run_one(spec)
        self.assertEqual(problems(runner.merged()), [("Kuma:source", "warning", "Kuma: 403")])

    def test_config_checks(self):
        bad = [({"url": "http://192.0.2.10:3001"}, "slug is required"),
               ({"url": "http://192.0.2.10:3001", "slug": "../admin"}, "slug is required"),
               ({"slug": "home"}, "url is required"),
               ({"url": "http://192.0.2.10:3001", "slug": "home", "slow_ms": "fast"}, "slow_ms"),
               ({"url": "http://192.0.2.10:3001", "slug": "home", "cert_days": -1}, "cert_days"),
               ({"url": "http://192.0.2.10:3001", "slug": "home", "services": "yes"}, "services")]
        for raw, words in bad:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, words):
                    sources.parse([dict({"name": "Kuma", "type": "uptime-kuma"}, **raw)], {})


class MonitorsSampleConfig(unittest.TestCase):
    """server/examples/sources-monitors.json (Kuma and Gatus) against both fake upstreams: merged /state and
    scripts/check-live-api."""

    def start(self):
        with open(os.path.join(HERE, "examples", "sources-monitors.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        kuma = FakeUpstream(recording("uptime-kuma", "normal")).start()
        gatus = FakeUpstream(recording("gatus", "normal")).start()
        self.addCleanup(kuma.stop)
        self.addCleanup(gatus.stop)
        raw["sources"][0]["url"] = kuma.url
        raw["sources"][1]["url"] = gatus.url
        raw["listen"] = "127.0.0.1:0"
        tmp = tempfile.mkdtemp(prefix="bridge-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "config.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(raw, fh)
        cfg = rs.Config.load(path, env={"HOMELAB_TOKENS": TOKEN})
        app = rs.RealApp(cfg)
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and all(st.runs >= 1 for st in app.sources.states.values()))
        return httpd.server_address[1]

    def test_merged_state(self):
        port = self.start()
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertEqual(state["status"], "problem")
        ids = [p["id"] for p in state["problems"]]
        self.assertIn("Kuma:monitor-1", ids)
        self.assertIn("Gatus:endpoint-core_jellyfin", ids)
        self.assertEqual([c["id"] for c in state["cards"]], ["Kuma:monitors", "Gatus:monitors"])

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_passes(self):
        port = self.start()
        script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
        res = subprocess.run(["bash", script, "--token", TOKEN, "http://127.0.0.1:%d" % port],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
