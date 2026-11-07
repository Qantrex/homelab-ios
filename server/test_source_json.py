"""Tests for the `json` feed source (server/sources/json.py, MODULAR.md M1.3). Stdlib only, no network beyond
127.0.0.1: the feed is server/fake_upstream.py replaying server/recordings/json/, or the reference server in fixture
mode serving the app's own state fixtures.

    python3 -m unittest -v server/test_source_json.py
"""

import glob
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
from test_reference_server import AUTH, FIXTURES, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None

FEED_KEY = "feed-key-0123456789abcdef"
ENV = {"FEED_KEY": FEED_KEY}
feed = sources.load_type("json")


def recording(case):
    return os.path.join(HERE, "recordings", "json", case + ".json")


def spec(url, **cfg):
    return sources.parse([dict({"name": "Feed", "type": "json", "url": url}, **cfg)], ENV)[0]


def run(spec_):
    runner = sources.Runner([spec_])
    runner.run_one(spec_)
    return runner


def replay(case, path="/homelab.json", **cfg):
    """(runner, requests) after one run against a recording."""
    with FakeUpstream(recording(case)) as up:
        runner = run(spec(up.url + path, **cfg))
        return runner, list(up.requests)


class JsonFeedSource(unittest.TestCase):
    """The normal feed, keys, and the failures that become one warning."""

    def test_normal(self):
        runner, requests = replay("normal")
        self.assertIsNone(runner.states["Feed"].error)
        self.assertNotIn("Authorization", requests[0]["headers"])
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"], p.get("host")) for p in out["problems"]],
                         [("Feed:backup-nas", "problem", "Feed:nas"), (out["problems"][1]["id"], "problem", None)])
        self.assertEqual(out["problems"][1]["text"], "Certificate for nas.tail1234.ts.net expires in 9 days")
        nas = out["hosts"][0]
        self.assertEqual([h["id"] for h in out["hosts"]], ["Feed:nas", "Feed:pi1"])
        self.assertEqual((nas["name"], nas["kind"], nas["reachable"], nas["load"], nas["cpu_count"], nas["mem_pct"]),
                         ("NAS", "nas", True, 0.8, 4, 41))
        self.assertEqual(nas["disks"], {"/": 63, "/srv/tank": 97})
        self.assertEqual(nas["containers"], {"up": 2, "total": 3})
        self.assertEqual(nas["updates"], {"upgradable": 5, "reboot_required": False})
        self.assertEqual(nas["backup"], {"last": "2026-11-07T03:10:00+01:00", "result": "failed"})
        self.assertEqual(nas["history"], {"step": 300, "end": "2026-11-07T07:55:00+01:00", "load": [0.5, 0.7, None, 0.8]})
        self.assertEqual(nas["container_list"], [
            {"name": "restic", "state": "exited", "health": None, "restarts": 0},
            {"name": "web", "state": "running", "health": "healthy", "restarts": 1}])
        self.assertEqual(out["hosts"][1], {"id": "Feed:pi1", "name": "Pi", "kind": "raspberry-pi", "reachable": False,
                                           "flags": ["asleep"]})
        backups, renewals = out["cards"]
        self.assertEqual((backups["id"], backups["place"], backups["updated"], len(backups["items"])),
                         ("Feed:backups", "lab", "2026-11-07T08:00:00+01:00", 2))
        self.assertEqual(backups["items"][1], {"title": "pi1", "subtitle": "restic", "value": "ok", "tint": "green",
                                               "progress": 1})
        self.assertEqual((renewals["id"], renewals["style"], renewals["items"]),
                         ("Feed:renewals", "countdown", [{"title": "TLS certificate", "due": "2026-11-16"}]))
        self.assertIn("updated", renewals)   # the time of the run, as for every source card without one
        self.assertEqual([(s["name"], s["group"]) for s in out["services"]], [("NAS", "Storage"), ("Backup report", "Feed")])

    def test_status_pending_and_busy_are_not_taken(self):
        runner, _ = replay("normal")
        text = json.dumps(runner.merged())
        for word in ("ab12", "signed", "pending", "busy", "chat"):
            self.assertNotIn(word, text)

    def test_key_as_bearer_token(self):
        runner, requests = replay("normal", key_env="FEED_KEY")
        self.assertIsNone(runner.states["Feed"].error)
        self.assertEqual(requests[0]["headers"].get("Authorization"), "Bearer " + FEED_KEY)

    def test_key_in_its_own_header(self):
        runner, requests = replay("normal", key_env="FEED_KEY", key_header="X-Api-Key")
        self.assertIsNone(runner.states["Feed"].error)
        self.assertEqual(requests[0]["headers"].get("X-Api-Key"), FEED_KEY)
        self.assertNotIn("Authorization", requests[0]["headers"])

    def test_missing_key_is_one_warning(self):
        s = sources.parse([{"name": "Feed", "type": "json", "url": "http://127.0.0.1:9/x", "key_env": "FEED_KEY"}],
                          {})[0]
        out = run(s).merged()
        self.assertEqual([(p["id"], p["text"]) for p in out["problems"]], [("Feed:source", "Feed: FEED_KEY is not set")])

    def test_auth_failed_is_one_warning(self):
        runner, _ = replay("auth-failed", key_env="FEED_KEY")
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]],
                         [("Feed:source", "warning", "Feed: 401")])
        self.assertEqual((out["hosts"], out["cards"], out["services"]), ([], [], []))

    def test_body_over_8_mb_is_one_warning(self):
        runner, _ = replay("big")
        self.assertEqual([p["text"] for p in runner.merged()["problems"]], ["Feed: answer larger than 8 MB"])

    def test_not_an_object_or_not_json_is_one_warning(self):
        runner, _ = replay("not-object")
        self.assertEqual([p["text"] for p in runner.merged()["problems"]], ["Feed: feed is not a JSON object"])
        runner, _ = replay("not-object", path="/page")
        self.assertEqual([p["text"] for p in runner.merged()["problems"]], ["Feed: answer is not JSON"])

    def test_config_checks(self):
        for raw, why in (({"name": "F", "type": "json"}, "url is required"),
                         ({"name": "F", "type": "json", "url": "http://192.0.2.20/x", "key_header": "X-Api-Key"},
                          "key_header needs key_env"),
                         ({"name": "F", "type": "json", "url": "http://192.0.2.20/x", "key_env": "FEED_KEY",
                           "key_header": "Bad Header:"}, "key_header must be a header name")):
            with self.subTest(why=why):
                with self.assertRaises(ValueError) as ctx:
                    sources.parse([raw], ENV)
                self.assertIn(why, str(ctx.exception))

    def test_the_type_named_json_does_not_replace_the_json_module(self):
        # sources/json.py is `sources.json` in sys.modules, but the package's own `json` stays the stdlib one.
        self.assertIs(sources.json, json)
        self.assertIs(sys.modules["sources.json"], feed)
        self.assertIs(sources.load_type("json"), feed)


class JsonFeedOdd(unittest.TestCase):
    """The odd recording: never a crash, and what is kept is what the app would keep."""

    @classmethod
    def setUpClass(cls):
        runner, _ = replay("odd")
        cls.error = runner.states["Feed"].error
        cls.out = runner.merged()

    def test_no_error(self):
        self.assertIsNone(self.error)

    def test_problems(self):
        self.assertEqual([(p["id"], p["severity"], p["text"], p.get("host")) for p in self.out["problems"]], [
            ("Feed:p1", "warning", "Disk almost full", "Feed:nas"),          # trimmed, WARNING read as warning
            (self.out["problems"][1]["id"], "problem", "42", None),            # a number as text; unknown severity
            ("Feed:7", "problem", "id as a number", None)])                    # host not in this feed: dropped

    def test_hosts(self):
        self.assertEqual([h["id"] for h in self.out["hosts"]], ["Feed:nas", "Feed:12"])
        nas = self.out["hosts"][0]
        self.assertEqual(nas, {
            "id": "Feed:nas", "name": "nas", "reachable": True, "load": 0.5, "cpu_count": 4, "mem_pct": 100,
            "disks": {"/": 55, "/srv": 100}, "containers": {"total": 2}, "backup": {"last": "20261107"},
            "flags": ["throttled_now"], "history": {"step": 300, "load": [1, 2, None, None]},
            "container_list": [{"name": "db", "state": "running", "health": None, "restarts": 0}]})
        self.assertEqual(self.out["hosts"][1], {"id": "Feed:12", "name": "12"})   # "1e999" is no number

    def test_cards(self):
        self.assertEqual([c["id"] for c in self.out["cards"]], ["Feed:c1", "Feed:c2"])   # `today` refused
        c1, c2 = self.out["cards"]
        self.assertEqual((c1["title"], "action" in c1), ("5", False))
        self.assertEqual([{k: v for k, v in i.items()} for i in c1["items"]],
                         [{"title": "one", "progress": 1, "done": True}, {"value": "3", "cancelled": False}])
        self.assertEqual(c2["items"], [])

    def test_nothing_secret_or_unsafe_gets_through(self):
        text = json.dumps(self.out)
        for word in ("made-up-token-in-a-feed", "token", "restartable", "javascript:", "ftp://", "poster", "action",
                     "new_field", "nested"):
            self.assertNotIn(word, text)
        self.assertEqual(self.out["services"], [])   # an object where the list belongs


class JsonFeedFromCompanion(unittest.TestCase):
    """The feed is another Companion server's /state: every state fixture of the app, through the reference server in
    fixture mode, reads without an error, keeps every host with an id and every problem with a text."""

    def test_every_state_fixture(self):
        app = rs.FixtureApp(FIXTURES, "state-ok.json", token=TOKEN)
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        url = "http://127.0.0.1:%d/api/v1/state" % httpd.server_address[1]
        s = sources.parse([{"name": "Pi", "type": "json", "url": url, "key_env": "PI_TOKEN"}], {"PI_TOKEN": TOKEN})[0]
        names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(FIXTURES, "state-*.json")))
        self.assertGreater(len(names), 5)
        for name in names:
            with self.subTest(fixture=name):
                app.set_state(name)
                runner = run(s)
                self.assertIsNone(runner.states["Pi"].error)
                out = runner.merged()
                with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
                    doc = json.load(fh)
                hosts = [h["id"] for h in doc.get("hosts", []) if isinstance(h, dict) and isinstance(h.get("id"), str)]
                self.assertEqual([h["id"] for h in out["hosts"]], ["Pi:" + h for h in dict.fromkeys(hosts)][:100])
                texts = [p if isinstance(p, str) else p.get("text") if isinstance(p, dict) else None
                         for p in doc.get("problems", [])]
                self.assertEqual({p["text"] for p in out["problems"]},
                                 {t.strip() for t in texts if isinstance(t, str) and t.strip()})


class JsonFeedEndToEnd(unittest.TestCase):
    """server/examples/sources-json.json against the fake upstream: /state has the feed, check-live-api passes and
    the key is in no reply."""

    def start(self):
        with open(os.path.join(HERE, "examples", "sources-json.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        up = FakeUpstream(recording("normal")).start()
        self.addCleanup(up.stop)
        raw["sources"][0]["url"] = up.url + "/homelab.json"
        raw["listen"] = "127.0.0.1:0"
        tmp = tempfile.mkdtemp(prefix="bridge-json-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "config.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(raw, fh)
        cfg = rs.Config.load(path, env={"HOMELAB_TOKENS": TOKEN, "FEED_KEY": FEED_KEY})
        app = rs.RealApp(cfg)
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and app.sources.states["Backups"].runs >= 1)
        return httpd.server_address[1], up

    def test_state_and_services(self):
        port, up = self.start()
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertEqual(state["status"], "problem")
        self.assertIn("Backups:backup-nas", [p["id"] for p in state["problems"]])
        self.assertEqual([h["id"] for h in state["hosts"]][-2:], ["Backups:nas", "Backups:pi1"])
        self.assertEqual([c["id"] for c in state["cards"]], ["Backups:backups", "Backups:renewals"])
        _, _, services = call(port, "GET", "/api/v1/services", headers=AUTH)
        self.assertEqual([s["name"] for s in services["services"]], ["NAS", "Backup report"])
        self.assertEqual(up.requests[0]["headers"].get("Authorization"), "Bearer " + FEED_KEY)
        for path in ("/api/v1/info", "/api/v1/state", "/api/v1/services"):
            code, resp, obj = call(port, "GET", path, headers=AUTH)
            self.assertNotIn(FEED_KEY, json.dumps(obj) + json.dumps(dict(resp.getheaders())))

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_passes(self):
        port, _ = self.start()
        script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
        res = subprocess.run(["bash", script, "--token", TOKEN, "http://127.0.0.1:%d" % port],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertNotIn(FEED_KEY, res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
