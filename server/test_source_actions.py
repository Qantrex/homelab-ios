#!/usr/bin/env python3
"""Tests for the ad blockers' opt-in `dns-pause` through the bridge's SourceActions (server/sources/__init__.py, the
same mechanism as Docker restart and Proxmox start/stop), item buttons that survive only when listed, and the DNS and
media sample config. Run from the repo root:

    python3 -m unittest -v server/test_source_actions.py

Actions are off by default (MODULAR.md, owner decision 6): only what a source's `actions` lists is offered, the app
confirms each press, and the bridge looks the argument up in that list.
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

PASSWORD = "made-up-app-password-0123456789"
AG_PASSWORD = "made-up-adguard-password-0123"
ENV = {"PIHOLE_PW": PASSWORD, "ADGUARD_PW": AG_PASSWORD}


def recording(kind, case):
    return os.path.join(HERE, "recordings", kind, case + ".json")


def pihole(url, **extra):
    return dict({"name": "Pi-hole", "type": "pihole", "url": url, "key_env": "PIHOLE_PW"}, **extra)


def adguard(url, **extra):
    return dict({"name": "AdGuard", "type": "adguard", "url": url, "username": "monitor",
                 "password_env": "ADGUARD_PW"}, **extra)


def blocking_posts(up):
    return [json.loads(r["body"]) for r in up.requests if r["method"] == "POST" and r["path"] == "/api/dns/blocking"]


class DnsPauseRules(unittest.TestCase):
    def test_off_by_default(self):
        spec = sources.parse([pihole("http://192.0.2.53")], ENV)[0]
        self.assertEqual(spec["actions"], [])
        runner = sources.Runner([spec])
        self.assertFalse(runner.actions)
        self.assertEqual(runner.actions.run("dns-pause", {"arg": "Pi-hole:5"})[0], 404)
        self.assertIsNone(rs.RealApp(rs.Config({"tokens": [TOKEN], "sources": [pihole("http://192.0.2.53")]},
                                               env=ENV)).routes.get("actions"))

    def test_the_list_is_built_from_the_config(self):
        spec = sources.parse([pihole("http://192.0.2.53", actions={"pause": [30, 5, 5]})], ENV)[0]
        self.assertEqual([(a["action"], a["arg"], a["label"]) for a in spec["actions"]], [
            ("dns-pause", "Pi-hole:5", "5 min"), ("dns-pause", "Pi-hole:30", "30 min"),
            ("dns-pause", "Pi-hole:on", "Resume")])

    def test_only_listed_item_buttons_survive(self):
        result = {"cards": [{"id": "dns", "action": {"name": "dns-pause", "arg": "Pi-hole:5"},
                             "items": [{"title": "a", "action": {"name": "dns-pause", "label": "Pause 5 min",
                                                                 "arg": "Pi-hole:5", "payload": {"x": "y"}}},
                                       {"title": "b", "action": {"name": "dns-pause", "arg": "Pi-hole:60"}},
                                       {"title": "c", "action": {"name": "restart-container", "arg": "Pi-hole:5"}},
                                       {"title": "d", "action": "dns-pause"}]}]}
        listed = {("dns-pause", "Pi-hole:5")}
        card = sources.normalize("Pi-hole", result, item_actions=listed)["cards"][0]
        self.assertNotIn("action", card)
        self.assertEqual(card["items"], [
            {"title": "a", "action": {"name": "dns-pause", "label": "Pause 5 min", "arg": "Pi-hole:5"}},
            {"title": "b"}, {"title": "c"}, {"title": "d"}])
        plain = sources.normalize("Pi-hole", result)["cards"][0]
        self.assertEqual(plain["items"], [{"title": "a"}, {"title": "b"}, {"title": "c"}, {"title": "d"}])

    def test_two_ad_blockers_share_one_action(self):
        specs = sources.parse([pihole("http://192.0.2.53", actions={"pause": [5]}),
                               adguard("http://192.0.2.54:3000", actions={"pause": [5, 15]})], ENV)
        [action] = sources.SourceActions(specs).listing()["actions"]
        self.assertEqual((action["name"], action["label"], action["icon"]), ("dns-pause", "Pause ad blocking",
                                                                              "shield.slash"))
        self.assertNotIn("destructive", action)
        self.assertEqual([(v["label"], v["parts"][0]["text"], [o["value"] for o in v["parts"][1]["options"]])
                          for v in action["arg"]],
                         [("Pi-hole", "Pi-hole:", ["5", "on"]), ("AdGuard", "AdGuard:", ["5", "15", "on"])])

    def test_types_without_actions_refuse_the_key(self):
        with self.assertRaisesRegex(rs.ConfigError, "has no actions"):
            rs.Config({"tokens": [TOKEN], "sources": [{"name": "Sonarr", "type": "sonarr", "url": "http://192.0.2.30",
                                                       "key_env": "PIHOLE_PW", "actions": {"pause": [5]}}]}, env=ENV)

    def test_a_press_reads_the_source_again(self):
        with FakeUpstream(recording("pihole", "normal")) as up:
            spec = sources.parse([pihole(up.url, actions={"pause": [5]})], ENV)[0]
            runner = sources.Runner([spec])
            runner.states["Pi-hole"].next_due = 1e12
            self.assertEqual(runner.actions.run("dns-pause", {"arg": "Pi-hole:5"})[1]["ok"], True)
            self.assertEqual(runner.states["Pi-hole"].next_due, 0.0)
            runner.states["Pi-hole"].next_due = 1e12
        with FakeUpstream({"routes": {}}) as up:
            spec = sources.parse([pihole(up.url, actions={"pause": [5]})], ENV)[0]
            runner = sources.Runner([spec])
            runner.states["Pi-hole"].next_due = 1e12
            self.assertEqual(runner.actions.run("dns-pause", {"arg": "Pi-hole:5"})[1]["ok"], False)
            self.assertEqual(runner.states["Pi-hole"].next_due, 1e12)


class DnsPauseEndToEnd(unittest.TestCase):
    """The reference server with a Pi-hole that opted in to pausing."""

    def start(self, raw_sources, env=ENV):
        cfg = rs.Config({"name": "bridge", "tokens": [TOKEN], "interval": 60,
                         "this_host": {"id": "box", "disks": ["/"]},
                         "thresholds": {"temp_warning": 1000, "disk_warning": 1000, "disk_problem": 1001},
                         "sources": raw_sources}, env=env)
        app = rs.RealApp(cfg)
        app.sources.tick_seconds = 0.05
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and all(st.runs >= 1 for st in app.sources.states.values()))
        return httpd.server_address[1]

    def upstream(self, rec):
        up = FakeUpstream(rec).start()
        self.addCleanup(up.stop)
        return up

    def test_opted_in(self):
        up = self.upstream(recording("pihole", "normal"))
        port = self.start([pihole(up.url, actions={"pause": [5, 15, 30]})])
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertIn("run-actions", info["features"])
        _, _, actions = call(port, "GET", "/api/v1/actions", headers=AUTH)
        self.assertEqual([a["name"] for a in actions["actions"]], ["dns-pause"])
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        blocking = state["cards"][0]["items"][2]
        self.assertEqual(blocking["action"], {"name": "dns-pause", "label": "Pause 5 min", "arg": "Pi-hole:5"})
        code, _, obj = call(port, "POST", "/api/v1/actions/dns-pause", body={"arg": "Pi-hole:5", "payload": {}},
                            headers=AUTH)
        self.assertEqual((code, obj), (200, {"ok": True, "text": "Pi-hole: blocking paused for 5 min"}))
        self.assertEqual(blocking_posts(up), [{"blocking": False, "timer": 300}])

    def test_the_server_checks_again(self):
        up = self.upstream(recording("pihole", "normal"))
        port = self.start([pihole(up.url, actions={"pause": [5]})])
        for body, want in [({"arg": "Pi-hole:60"}, 400), ({"arg": "5"}, 400), ({"arg": "Pi-hole:5 "}, 400),
                           ({"arg": "Pi-hole:5", "payload": {"x": "1"}}, 400), ({"arg": 5}, 400), ({}, 400)]:
            with self.subTest(body=body):
                self.assertEqual(call(port, "POST", "/api/v1/actions/dns-pause", body=body, headers=AUTH)[0], want)
        self.assertEqual(call(port, "POST", "/api/v1/actions/pi-hole-pause", body={"arg": "5"}, headers=AUTH)[0], 404)
        self.assertEqual(call(port, "GET", "/api/v1/actions/dns-pause", headers=AUTH)[0], 405)
        self.assertEqual(call(port, "POST", "/api/v1/actions/dns-pause", body={"arg": "Pi-hole:5"})[0], 401)
        self.assertEqual(blocking_posts(up), [])

    def test_not_offered_without_the_key(self):
        up = self.upstream(recording("pihole", "normal"))
        port = self.start([pihole(up.url)])
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertNotIn("run-actions", info["features"])
        self.assertEqual(call(port, "GET", "/api/v1/actions", headers=AUTH)[0], 404)
        self.assertEqual(call(port, "POST", "/api/v1/actions/dns-pause", body={"arg": "Pi-hole:5"}, headers=AUTH)[0],
                         404)
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertNotIn("action", state["cards"][0]["items"][2])

    def test_a_failed_pause_says_so_without_the_key(self):
        up = self.upstream({"routes": {"POST /api/auth": {"status": 401, "body": "no " + PASSWORD}}})
        port = self.start([pihole(up.url, actions={"pause": [5]})])
        code, resp, obj = call(port, "POST", "/api/v1/actions/dns-pause", body={"arg": "Pi-hole:on"}, headers=AUTH)
        self.assertEqual((code, obj), (200, {"ok": False, "text": "Pi-hole: Resume failed (401 (check the app password))"}))
        self.assertNotIn(PASSWORD, json.dumps(obj) + json.dumps(dict(resp.getheaders())))

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_accepts_the_actions(self):
        up = self.upstream(recording("pihole", "normal"))
        ag = self.upstream(recording("adguard", "normal"))
        port = self.start([pihole(up.url, actions={"pause": [5, 15, 30]}), adguard(ag.url, actions={"pause": [5]})])
        res = check_live_api(port)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


def check_live_api(port):
    script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
    return subprocess.run(["bash", script, "--token", TOKEN, "http://127.0.0.1:%d" % port],
                          capture_output=True, text=True, timeout=60)


class DnsMediaSample(unittest.TestCase):
    """server/examples/sources-dns-media.json, every source against its normal recording."""

    KEYS = {"PIHOLE_APP_PASSWORD": "made-up-pihole-0123456789", "ADGUARD_PASSWORD": "made-up-adguard-0123456789",
            "SONARR_KEY": "made-up-sonarr-0123456789", "RADARR_KEY": "made-up-radarr-0123456789",
            "QBIT_API_KEY": "qbt_made-up-0123456789"}

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_sample_config_runs_and_passes_check_live_api(self):
        with open(os.path.join(HERE, "examples", "sources-dns-media.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        for src in raw["sources"]:
            up = FakeUpstream(recording(src["type"], "normal")).start()
            self.addCleanup(up.stop)
            src["url"] = up.url
        raw["listen"] = "127.0.0.1:0"
        tmp = tempfile.mkdtemp(prefix="bridge-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "config.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(raw, fh)
        cfg = rs.Config.load(path, env=dict(self.KEYS, HOMELAB_TOKENS=TOKEN))
        app = rs.RealApp(cfg)
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and all(st.runs >= 1 for st in app.sources.states.values()))
        self.assertEqual({n: st.error for n, st in app.sources.states.items()},
                         {s["name"]: None for s in raw["sources"]})
        port = httpd.server_address[1]
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertNotIn("run-actions", info["features"])
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        ids = [c["id"] for c in state["cards"]]
        for want in ("Pi-hole:dns", "AdGuard:dns", "Sonarr:queue", "Radarr:queue", "qBittorrent:downloads"):
            self.assertIn(want, ids)
        res = check_live_api(port)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        text = json.dumps(state) + json.dumps(info) + res.stdout + res.stderr
        for value in self.KEYS.values():
            self.assertNotIn(value, text)


if __name__ == "__main__":
    unittest.main()
