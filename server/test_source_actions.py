#!/usr/bin/env python3
"""Tests for opt-in source actions (the `actions` key of a source; server/sources/__init__.py Runner.act, the
reference server's /actions routes) and the DNS and media sample config. Run from the repo root:

    python3 -m unittest -v server/test_source_actions.py

Actions are off by default (MODULAR.md, owner decision 6): only a source whose config lists an action offers it, the
app confirms each press, and the bridge checks the name and the argument again.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402
import sources  # noqa: E402
from sources import _dns  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None

PASSWORD = "made-up-app-password-0123456789"
ENV = {"PIHOLE_PW": PASSWORD}


def recording(kind, case):
    return os.path.join(HERE, "recordings", kind, case + ".json")


def pihole(url, **extra):
    return dict({"name": "Pi-hole", "type": "pihole", "url": url, "key_env": "PIHOLE_PW"}, **extra)


# A test-only type with one action, to see what the bridge does around act().
_calls = []


def _act(cfg, fetch, name, arg):
    _calls.append((name, arg))
    if arg == "fail":
        raise sources.SourceError("refused for key %s" % fetch.secret())
    if arg == "crash":
        raise RuntimeError("boom " + fetch.secret())
    return "did %s %s" % (name, arg)


def _offers(cfg):
    return {"poke": {"label": "Poke", "arg": [{"parts": [{"kind": "choice", "options": [
        {"value": "ok"}, {"value": "fail"}, {"value": "crash"}]}]}]}}


sources.register("t-act", types.SimpleNamespace(collect=lambda cfg, fetch: {}, actions=_offers, act=_act))
sources.register("t-act-date", types.SimpleNamespace(
    collect=lambda cfg, fetch: {}, act=_act,
    actions=lambda cfg: {"later": {"arg": [{"parts": [{"kind": "date"}]}]}}))


class SourceActionRules(unittest.TestCase):
    def test_off_by_default(self):
        spec = sources.parse([pihole("http://192.0.2.53")], ENV)[0]
        self.assertEqual((spec["actions"], spec["cfg"]["actions"]), ({}, []))
        self.assertEqual(sources.Runner([spec]).offered, {})
        self.assertIsNone(rs.RealApp(rs.Config({"tokens": [TOKEN], "sources": [pihole("http://192.0.2.53")]},
                                               env=ENV)).routes.get("actions"))

    def test_only_listed_item_actions_survive(self):
        result = {"cards": [{"id": "dns", "action": {"name": "pause"},
                             "items": [{"title": "a", "action": {"name": "pause", "label": "Pause 5 min", "arg": "5",
                                                                 "payload": {"x": "y"}, "extra": 1}},
                                       {"title": "b", "action": {"name": "restart", "arg": "web"}},
                                       {"title": "c", "action": "pause"}]}]}
        card = sources.normalize("Pi-hole", result, actions={"pause": "pi-hole-pause"})["cards"][0]
        self.assertNotIn("action", card)
        self.assertEqual(card["items"], [
            {"title": "a", "action": {"name": "pi-hole-pause", "label": "Pause 5 min", "arg": "5"}},
            {"title": "b"}, {"title": "c"}])
        plain = sources.normalize("Pi-hole", result)["cards"][0]
        self.assertEqual(plain["items"], [{"title": "a"}, {"title": "b"}, {"title": "c"}])

    def test_names_and_collisions(self):
        self.assertEqual(sources.action_name("Pi-hole", "pause"), "pi-hole-pause")
        self.assertEqual(sources.action_name("My DNS.1", "pause"), "my-dns-1-pause")
        self.assertEqual(sources.action_name("__", "pause"), "source-pause")
        with self.assertRaisesRegex(ValueError, "taken by another source"):
            sources.parse([pihole("http://192.0.2.53", actions=["pause"]),
                           pihole("http://192.0.2.54", name="Pi hole", actions=["pause"])], ENV)

    def test_bad_configs(self):
        for raw, words in [(pihole("http://192.0.2.53", actions="pause"), "must be a list"),
                           (pihole("http://192.0.2.53", actions=[1]), "must be a list"),
                           (pihole("http://192.0.2.53", actions=["stop"]), "not an action of type pihole"),
                           ({"name": "Sonarr", "type": "sonarr", "url": "http://192.0.2.30", "key_env": "PIHOLE_PW",
                             "actions": ["pause"]}, r"offers: none"),
                           ({"name": "Lab", "type": "t-act-date", "actions": ["later"]}, "can't check")]:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(rs.ConfigError, words):
                    rs.Config({"tokens": [TOKEN], "sources": [raw]}, env=ENV)

    def test_action_args(self):
        self.assertEqual(sources.action_args(_dns.pause_spec({"name": "Pi-hole"})), {"5", "15", "30", "on"})
        self.assertEqual(sources.action_args({}), {""})
        self.assertEqual(sources.action_args({"arg": [{"parts": [
            {"kind": "choice", "options": [{"value": "a"}, {"value": "b"}, "junk"]}, {"kind": "literal", "text": ":"},
            {"kind": "choice", "options": [{"value": "1"}]}]}]}), {"a:1", "b:1"})
        self.assertIsNone(sources.action_args({"arg": [{"parts": [{"kind": "number"}]}]}))
        many = {"arg": [{"parts": [{"kind": "choice", "options": [{"value": str(i)} for i in range(60)]}]}]}
        self.assertIsNone(sources.action_args(many))

    def test_act(self):
        spec = sources.parse([{"name": "Lab", "type": "t-act", "key_env": "PIHOLE_PW", "actions": ["poke"]}], ENV)[0]
        runner = sources.Runner([spec])
        self.assertEqual(runner.action_specs(), [dict(_offers({})["poke"], name="lab-poke")])
        del _calls[:]
        runner.states["Lab"].next_due = 99.0
        self.assertEqual(runner.act("lab-poke", "ok"), (200, {"ok": True, "text": "did poke ok"}))
        self.assertEqual(runner.states["Lab"].next_due, 0.0)
        self.assertEqual(runner.act("lab-poke", "other")[0], 400)
        self.assertEqual(runner.act("lab-poke", None)[0], 400)
        self.assertEqual(runner.act("lab-nope", "ok")[0], 404)
        self.assertEqual(_calls, [("poke", "ok")])
        for arg in ("fail", "crash"):
            code, body = runner.act("lab-poke", arg)
            self.assertEqual(code, 502)
            self.assertNotIn(PASSWORD, json.dumps(body))
            self.assertIn("***", body["error"])
            self.assertTrue(body["error"].startswith("Lab: ") and body["error"].endswith("(it may not have run)"))


class BridgeActionsEndToEnd(unittest.TestCase):
    """The reference server with a Pi-hole that opted in to `pause`."""

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
        port = self.start([pihole(up.url, actions=["pause"])])
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertIn("run-actions", info["features"])
        _, _, actions = call(port, "GET", "/api/v1/actions", headers=AUTH)
        self.assertEqual([a["name"] for a in actions["actions"]], ["pi-hole-pause"])
        self.assertEqual(actions["actions"][0]["label"], "Pause Pi-hole")
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        blocking = state["cards"][0]["items"][2]
        self.assertEqual(blocking["action"], {"name": "pi-hole-pause", "label": "Pause 5 min", "arg": "5"})
        before = len(up.requests)
        code, _, obj = call(port, "POST", "/api/v1/actions/pi-hole-pause", body={"arg": "5", "payload": {}},
                            headers=AUTH)
        self.assertEqual((code, obj), (200, {"ok": True, "text": "Pi-hole: blocking paused for 5 min"}))
        sent = [r for r in up.requests[before:] if r["method"] == "POST" and r["path"] == "/api/dns/blocking"]
        self.assertEqual([json.loads(r["body"]) for r in sent], [{"blocking": False, "timer": 300}])

    def test_the_server_checks_again(self):
        up = self.upstream(recording("pihole", "normal"))
        port = self.start([pihole(up.url, actions=["pause"])])
        before = len(up.requests)
        for body, want in [({"arg": "60"}, 400), ({"arg": "5", "payload": {"x": "1"}}, 400), ({"arg": 5}, 400),
                           ({}, 400)]:
            with self.subTest(body=body):
                self.assertEqual(call(port, "POST", "/api/v1/actions/pi-hole-pause", body=body, headers=AUTH)[0], want)
        self.assertEqual(call(port, "POST", "/api/v1/actions/pi-hole-stop", body={"arg": "5"}, headers=AUTH)[0], 404)
        self.assertEqual(call(port, "GET", "/api/v1/actions/pi-hole-pause", headers=AUTH)[0], 405)
        self.assertEqual(call(port, "POST", "/api/v1/actions/pi-hole-pause", body={"arg": "5"})[0], 401)
        self.assertFalse([r for r in up.requests[before:] if r["path"] == "/api/dns/blocking" and r["method"] == "POST"])

    def test_not_offered_without_the_key(self):
        up = self.upstream(recording("pihole", "normal"))
        port = self.start([pihole(up.url)])
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertNotIn("run-actions", info["features"])
        self.assertEqual(call(port, "GET", "/api/v1/actions", headers=AUTH)[0], 404)
        self.assertEqual(call(port, "POST", "/api/v1/actions/pi-hole-pause", body={"arg": "5"}, headers=AUTH)[0], 404)
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertNotIn("action", state["cards"][0]["items"][2])

    def test_a_failed_pause_says_so_without_the_key(self):
        up = self.upstream({"routes": {"POST /api/auth": {"status": 401, "body": "no " + PASSWORD}}})
        port = self.start([pihole(up.url, actions=["pause"])])
        code, resp, obj = call(port, "POST", "/api/v1/actions/pi-hole-pause", body={"arg": "on"}, headers=AUTH)
        self.assertEqual((code, obj), (502, {"error": "Pi-hole: 401 (check the app password) (it may not have run)"}))
        self.assertNotIn(PASSWORD, json.dumps(dict(resp.getheaders())))

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_accepts_the_actions(self):
        up = self.upstream(recording("pihole", "normal"))
        port = self.start([pihole(up.url, actions=["pause"])])
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
        text = json.dumps(state) + res.stdout + res.stderr
        for value in self.KEYS.values():
            self.assertNotIn(value, text)


if __name__ == "__main__":
    unittest.main()
