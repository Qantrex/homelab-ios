#!/usr/bin/env python3
"""Tests for the docker source (server/sources/docker.py) and the bridge's opt-in source actions
(sources.SourceActions, served as run-actions). Run from the repo root:

    python3 -m unittest -v server/test_source_docker.py

Stdlib only; the Docker API is server/fake_upstream.py replaying server/recordings/docker/.
"""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402
import sources  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None
RECORDINGS = os.path.join(HERE, "recordings", "docker")


def recording(case):
    return os.path.join(RECORDINGS, case + ".json")


def spec(url, name="Docker", **cfg):
    return sources.parse([dict({"name": name, "type": "docker", "url": url}, **cfg)], {})[0]


def run(s, logs=None):
    runner = sources.Runner([s], logf=(logs.append if logs is not None else lambda m: None))
    runner.run_one(s)
    return runner


def posts(up):
    return [r["path"] for r in up.requests if r["method"] != "GET"]


class DockerSource(unittest.TestCase):
    """Containers of one host: the list, its summary, and unhealthy, restarting, dead or crashed ones as problems."""

    def test_normal(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(spec(up.url, host="nas", host_name="NAS"))
            self.assertEqual([(r["method"], r["path"]) for r in up.requests], [("GET", "/containers/json?all=1")])
            self.assertNotIn("Authorization", up.requests[0]["headers"])
        self.assertIsNone(runner.states["Docker"].error)
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"], p["text"], p["host"]) for p in out["problems"]], [
            ("Docker:container-jellyfin", "problem", "NAS: jellyfin is unhealthy", "Docker:nas"),
            ("Docker:container-gluetun", "warning", "NAS: gluetun exited (137)", "Docker:nas"),
            ("Docker:container-watchtower", "problem", "NAS: watchtower is restarting", "Docker:nas")])
        [host] = out["hosts"]
        self.assertEqual((host["id"], host["name"], host["kind"], host["reachable"]), ("Docker:nas", "NAS", "server", True))
        self.assertEqual(host["containers"], {"up": 3, "total": 6})
        self.assertEqual(host["container_list"], [
            {"name": "backup-job", "state": "exited", "health": None},
            {"name": "gluetun", "state": "exited", "health": None},
            {"name": "jellyfin", "state": "running", "health": "unhealthy"},
            {"name": "radarr", "state": "running", "health": None},
            {"name": "sonarr", "state": "running", "health": "healthy"},
            {"name": "watchtower", "state": "restarting", "health": None}])
        self.assertEqual(out["cards"] + out["services"], [])

    def test_host_defaults_to_the_source_name(self):
        with FakeUpstream(recording("normal")) as up:
            out = run(spec(up.url, name="Media Box")).merged()
        self.assertEqual((out["hosts"][0]["id"], out["hosts"][0]["name"]), ("Media Box:media-box", "media-box"))

    def test_ignore(self):
        with FakeUpstream(recording("normal")) as up:
            out = run(spec(up.url, ignore=["gluetun", "watchtower"])).merged()
        self.assertEqual([p["id"] for p in out["problems"]], ["Docker:container-jellyfin"])
        self.assertEqual(len(out["hosts"][0]["container_list"]), 6)

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("odd")) as up:
            runner = run(spec(up.url))
        self.assertIsNone(runner.states["Docker"].error)
        out = runner.merged()
        cl = {c["name"]: c for c in out["hosts"][0]["container_list"]}
        self.assertEqual(sorted(cl), ["42", "crashed", "db", "gone", "paused-one", "strange", "web"])
        self.assertEqual(cl["db"], {"name": "db", "state": "running", "health": "starting"})   # old engine, Status text
        self.assertEqual(cl["web"]["health"], "unhealthy")       # "Running" read as running, the duplicate dropped
        self.assertEqual(cl["strange"], {"name": "strange", "health": None})   # unknown state and health left out
        self.assertEqual(cl["paused-one"]["state"], "paused")
        self.assertEqual([p["text"] for p in out["problems"]],
                         ["docker: web is unhealthy", "docker: crashed exited (-1)", "docker: gone is dead"])
        self.assertNotIn("not-a-real-one", json.dumps(out))

    def test_failures_are_one_warning(self):
        cases = [({"GET /containers/json": {"status": 403, "body": "Forbidden"}}, "Docker: 403"),
                 ({"GET /containers/json": {"json": {"message": "page not found"}}}, "Docker: answer is not a container list"),
                 ({"GET /containers/json": {"body": "<html>"}}, "Docker: answer is not JSON")]
        for routes, text in cases:
            with self.subTest(text=text), FakeUpstream({"routes": routes}) as up:
                out = run(spec(up.url)).merged()
            self.assertEqual([p["text"] for p in out["problems"]], [text])
            self.assertEqual(out["hosts"], [])

    def test_bad_configs(self):
        bad = [({"url": None}, "url is required"), ({"host": "a b"}, "host must be"), ({"host_name": 5}, "host_name"),
               ({"ignore": "web"}, "ignore"), ({"actions": ["sonarr"]}, "actions must be"),
               ({"actions": {"stop": ["sonarr"]}}, "actions must be"),
               ({"actions": {"restart": ["../create"]}}, "actions.restart"),
               ({"actions": {"restart": ["-x"]}}, "actions.restart"),
               ({"host": "h" * 30, "actions": {"restart": ["c" * 30]}}, "longer than 64")]
        for cfg, words in bad:
            with self.subTest(cfg=cfg):
                raw = dict({"name": "Docker", "type": "docker", "url": "http://192.0.2.5:2375"}, **cfg)
                if raw["url"] is None:
                    del raw["url"]
                with self.assertRaises(rs.ConfigError) as ctx:
                    rs.Config({"tokens": [TOKEN], "sources": [raw]}, env={})
                self.assertIn(words, str(ctx.exception))


class DockerActions(unittest.TestCase):
    """Restart is off by default, only for listed containers, through the app's restart-container; the server takes
    exactly the listed arguments and nothing else."""

    def setUp(self):
        self.up = FakeUpstream(recording("normal")).start()
        self.addCleanup(self.up.stop)

    def runner(self, **cfg):
        cfg.setdefault("host", "nas")
        return run(spec(self.up.url, **cfg))

    def test_off_by_default(self):
        runner = self.runner()
        self.assertFalse(runner.actions)
        self.assertEqual(runner.actions.listing(), {"actions": []})
        self.assertNotIn("restartable", json.dumps(runner.merged()))
        self.assertEqual(runner.actions.run("restart-container", {"arg": "Docker:nas:sonarr"})[0], 404)
        self.assertEqual(posts(self.up), [])

    def test_only_listed_containers_are_restartable(self):
        runner = self.runner(actions={"restart": ["sonarr", "gluetun", "not-there"]})
        cl = {c["name"]: c for c in runner.merged()["hosts"][0]["container_list"]}
        self.assertEqual(sorted(n for n, c in cl.items() if c.get("restartable")), ["gluetun", "sonarr"])

    def test_listing_builds_exactly_the_apps_argument(self):
        runner = self.runner(host_name="NAS", actions={"restart": ["sonarr", "gluetun"]})
        [a] = runner.actions.listing()["actions"]
        self.assertEqual((a["name"], a["destructive"], a["fields"]), ("restart-container", True, []))
        [variant] = a["arg"]
        self.assertEqual(variant["label"], "Docker · NAS")
        host, colon, item = variant["parts"]
        self.assertEqual(host["options"], [{"value": "Docker:nas", "label": "NAS"}])
        self.assertEqual(colon, {"kind": "literal", "text": ":"})
        self.assertEqual([o["value"] for o in item["options"]], ["sonarr", "gluetun"])
        # The app builds "<host id>:<container>"; host ids are prefixed, so the argument has two colons. ARG_RE (argv
        # commands from pending files) refuses that, but a source action's argument is looked up, never parsed.
        self.assertIsNone(rs.ARG_RE.fullmatch("Docker:nas:sonarr"))
        self.assertEqual(runner.actions.run("restart-container", {"arg": "Docker:nas:sonarr", "payload": {}}),
                         (200, {"ok": True, "text": "Restarted sonarr on NAS."}))
        self.assertEqual(posts(self.up), ["/containers/sonarr/restart?t=10"])

    def test_refuses_everything_else(self):
        runner = self.runner(actions={"restart": ["sonarr"]})
        refused = [
            ("restart-container", {"arg": "Docker:nas:gluetun"}, 400),           # not on the list
            ("restart-container", {"arg": "nas:sonarr"}, 400),                   # unprefixed
            ("restart-container", {"arg": "docker:nas:sonarr"}, 400),            # case matters
            ("restart-container", {"arg": "Docker:nas:sonarr "}, 400),
            ("restart-container", {"arg": "Docker:nas:sonarr/../../containers/create"}, 400),
            ("restart-container", {"arg": "Docker:nas:sonarr?t=0&signal=KILL"}, 400),
            ("restart-container", {"arg": ""}, 400),
            ("restart-container", {"arg": ["Docker:nas:sonarr"]}, 400),
            ("restart-container", {"arg": "Docker:nas:sonarr", "payload": {"force": "1"}}, 400),
            ("restart-container", {"arg": "Docker:nas:sonarr", "payload": "x"}, 400),
            ("stop-container", {"arg": "Docker:nas:sonarr"}, 404),
            ("guest-start", {"arg": "Docker:sonarr"}, 404),
        ]
        for name, body, code in refused:
            with self.subTest(name=name, body=body):
                got, answer = runner.actions.run(name, body)
                self.assertEqual(got, code)
                self.assertIn("error", answer)
        self.assertEqual(posts(self.up), [])

    def test_rate_limit_and_one_at_a_time(self):
        s = spec(self.up.url, host="nas", actions={"restart": ["sonarr", "gluetun"]})
        acts = sources.SourceActions([s], per_hour=2)
        self.assertEqual(acts.run("restart-container", {"arg": "Docker:nas:sonarr"})[0], 200)
        self.assertEqual(acts.run("restart-container", {"arg": "Docker:nas:gluetun"})[0], 200)
        code, answer = acts.run("restart-container", {"arg": "Docker:nas:sonarr"})
        self.assertEqual((code, answer["error"]), (429, "more than 2 actions in the last hour"))
        acts = sources.SourceActions([s])
        acts.running.add(("restart-container", "Docker:nas:sonarr"))
        self.assertEqual(acts.run("restart-container", {"arg": "Docker:nas:sonarr"})[0], 429)
        self.assertEqual(acts.run("restart-container", {"arg": "Docker:nas:gluetun"})[0], 200)

    def test_a_failed_restart_says_so_without_a_url(self):
        logs = []
        with FakeUpstream({"routes": {"POST /containers/sonarr/restart": {"status": 404, "json": {
                "message": "No such container: sonarr at http://192.0.2.5:2375/x"}}}}) as up:
            s = spec(up.url, host="nas", actions={"restart": ["sonarr"]})
            acts = sources.SourceActions([s], logf=logs.append)
            code, answer = acts.run("restart-container", {"arg": "Docker:nas:sonarr"})
        self.assertEqual((code, answer), (200, {"ok": False, "text": "Docker: sonarr failed (404)"}))
        self.assertTrue(any("restart-container Docker:nas:sonarr" in line for line in logs))
        acts = sources.SourceActions([spec("http://127.0.0.1:9", host="nas", actions={"restart": ["sonarr"]})])
        self.assertEqual(acts.run("restart-container", {"arg": "Docker:nas:sonarr"})[1],
                         {"ok": False, "text": "Docker: sonarr failed (connection refused)"})

    def test_two_sources_share_one_action(self):
        a = spec(self.up.url, host="nas", actions={"restart": ["sonarr"]})
        b = spec(self.up.url, name="Pi box", host="pi", actions={"restart": ["sonarr"]})
        acts = sources.SourceActions([a, b])
        [action] = acts.listing()["actions"]
        self.assertEqual([v["parts"][0]["options"][0]["value"] for v in action["arg"]], ["Docker:nas", "Pi box:pi"])
        self.assertEqual(acts.run("restart-container", {"arg": "Pi box:pi:sonarr"})[1]["ok"], True)


class DockerBridge(unittest.TestCase):
    """The reference server with a docker source: run-actions only with an `actions` list, through HTTP."""

    def start(self, **cfg):
        up = FakeUpstream(recording("normal")).start()
        self.addCleanup(up.stop)
        raw = dict({"name": "Docker", "type": "docker", "url": up.url, "host": "nas"}, **cfg)
        app = rs.RealApp(rs.Config({"name": "bridge", "tokens": [TOKEN], "this_host": {"id": "box", "disks": ["/"]},
                                    "sources": [raw]}, env={}))
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and app.sources.states["Docker"].runs >= 1)
        return httpd.server_address[1], up

    def test_read_only_without_actions(self):
        port, up = self.start()
        info = call(port, "GET", "/api/v1/info", headers=AUTH)[2]
        self.assertNotIn("run-actions", info["features"])
        self.assertEqual(call(port, "GET", "/api/v1/actions", headers=AUTH)[0], 404)
        self.assertEqual(call(port, "POST", "/api/v1/actions/restart-container", {"arg": "Docker:nas:sonarr"},
                              headers=AUTH)[0], 404)
        self.assertEqual(posts(up), [])

    def test_restart_through_the_api(self):
        port, up = self.start(actions={"restart": ["sonarr"]})
        info = call(port, "GET", "/api/v1/info", headers=AUTH)[2]
        self.assertIn("run-actions", info["features"])
        self.assertNotIn("actions", info["features"])     # no pending proposals: that is the server's own `actions`
        listed = call(port, "GET", "/api/v1/actions", headers=AUTH)[2]
        self.assertEqual([a["name"] for a in listed["actions"]], ["restart-container"])
        state = call(port, "GET", "/api/v1/state", headers=AUTH)[2]
        host = [h for h in state["hosts"] if h["id"] == "Docker:nas"][0]
        self.assertEqual([c["name"] for c in host["container_list"] if c.get("restartable")], ["sonarr"])
        self.assertEqual(call(port, "POST", "/api/v1/actions/restart-container", {"arg": "Docker:nas:sonarr"})[0], 401)
        code, _, answer = call(port, "POST", "/api/v1/actions/restart-container", {"arg": "Docker:nas:sonarr"},
                               headers=AUTH)
        self.assertEqual((code, answer["ok"]), (200, True))
        code, _, answer = call(port, "POST", "/api/v1/actions/restart-container", {"arg": "Docker:nas:radarr"},
                               headers=AUTH)
        self.assertEqual(code, 400)
        self.assertEqual(posts(up), ["/containers/sonarr/restart?t=10"])


if __name__ == "__main__":
    unittest.main()
