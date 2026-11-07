#!/usr/bin/env python3
"""Tests for the proxmox source (server/sources/proxmox.py), its opt-in start and stop, and the sample config with
docker and proxmox (server/examples/sources-docker-proxmox.json) through scripts/check-live-api. Run from the repo
root:

    python3 -m unittest -v server/test_source_proxmox.py

Stdlib only; the Proxmox API is server/fake_upstream.py replaying server/recordings/proxmox/.
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
from sources import proxmox  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None
RECORDINGS = os.path.join(HERE, "recordings")
SECRET = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
ENV = {"PVE_TOKEN": SECRET}
TOKEN_ID = "monitor@pve!bridge"


def recording(case, kind="proxmox"):
    return os.path.join(RECORDINGS, kind, case + ".json")


def spec(url, env=None, **cfg):
    raw = dict({"name": "Proxmox", "type": "proxmox", "url": url, "token_id": TOKEN_ID, "key_env": "PVE_TOKEN"}, **cfg)
    return sources.parse([raw], ENV if env is None else env)[0]


def run(s, logs=None):
    runner = sources.Runner([s], logf=(logs.append if logs is not None else lambda m: None))
    runner.run_one(s)
    return runner


def load_recording(case):
    with open(recording(case), encoding="utf-8") as fh:
        return json.load(fh)


class ProxmoxSource(unittest.TestCase):
    """Nodes as hosts with their last 24 h, guests as the container list, an API token in the header."""

    def test_normal(self):
        with FakeUpstream(recording("normal")) as up:
            runner = run(spec(up.url, expect_running=[101, 201]))
            reqs = list(up.requests)
        self.assertIsNone(runner.states["Proxmox"].error)
        self.assertEqual([(r["method"], r["path"]) for r in reqs], [
            ("GET", "/api2/json/nodes"), ("GET", "/api2/json/nodes/pve1/status"),
            ("GET", "/api2/json/nodes/pve1/rrddata?timeframe=day&cf=AVERAGE"),
            ("GET", "/api2/json/nodes/pve1/qemu"), ("GET", "/api2/json/nodes/pve1/lxc")])
        for r in reqs:
            self.assertEqual(r["headers"].get("Authorization"), "PVEAPIToken=%s=%s" % (TOKEN_ID, SECRET))
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]], [
            ("Proxmox:disk-pve1", "warning", "pve1: root disk at 91%"),
            ("Proxmox:guest-201", "problem", "pve1: nginx (201) is stopped"),
            ("Proxmox:node-pve2", "problem", "pve2: offline")])
        pve1, pve2 = out["hosts"]
        self.assertEqual({k: pve1[k] for k in ("id", "name", "kind", "reachable", "load", "cpu_count", "mem_pct",
                                               "disks", "containers")},
                         {"id": "Proxmox:pve1", "name": "pve1", "kind": "server", "reachable": True, "load": 0.42,
                          "cpu_count": 8, "mem_pct": 41, "disks": {"/": 91}, "containers": {"up": 3, "total": 5}})
        self.assertEqual(pve1["container_list"], [
            {"name": "jellyfin", "health": None, "state": "running"},
            {"name": "homeassistant", "health": None, "state": "running"},
            {"name": "win11", "health": None, "state": "exited"},
            {"name": "pihole", "health": None, "state": "running"},
            {"name": "nginx", "health": None, "state": "exited"}])     # the template 9000 is left out
        h = pve1["history"]
        self.assertEqual(h["step"], 1800)                               # 30-minute rows stay as they are
        self.assertEqual({k: len(h[k]) for k in ("load", "mem_pct", "disk_pct")},
                         {"load": 48, "mem_pct": 48, "disk_pct": 48})
        self.assertEqual(h["load"][-1], 0.68)
        self.assertEqual(h["load"][-40:-38], [None, None])              # the reboot gap
        self.assertEqual(pve2, {"id": "Proxmox:pve2", "name": "pve2", "kind": "server", "reachable": False,
                                "checked": pve2["checked"], "url": up.url})
        self.assertNotIn("restartable", json.dumps(out))

    def test_pve9_minute_rows_become_288_points(self):
        end = 1762500000
        rows = [{"time": end - (1439 - i) * 60, "loadavg": float(i), "memused": i, "memtotal": 1440,
                 "rootused": 50, "roottotal": 100} for i in range(1440)]
        h = proxmox.history(rows)
        self.assertEqual((h["step"], len(h["load"]), len(h["mem_pct"]), len(h["disk_pct"])), (300, 288, 288, 288))
        self.assertEqual(h["load"][0], 2.0)                             # rows 0-4 averaged
        self.assertEqual(h["load"][-1], 1437.0)                         # rows 1435-1439
        self.assertEqual(h["mem_pct"][-1], 100)
        self.assertEqual(set(h["disk_pct"]), {50})
        self.assertTrue(h["end"].startswith("2025-11-0"))
        # Older than 24 h is dropped; an hour with no rows is null; nothing usable is no history at all.
        rows = [{"time": end - 30 * 3600, "loadavg": 9}] + [{"time": end - i * 300, "loadavg": 1} for i in range(12)]
        h = proxmox.history(rows)
        self.assertEqual((len(h["load"]), h["load"][0], h["load"][-1]), (288, None, 1.0))
        self.assertNotIn(9, h["load"])
        self.assertIsNone(proxmox.history([{"time": end}, {"time": end - 60}]))
        self.assertIsNone(proxmox.history("nope"))

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("odd")) as up:
            runner = run(spec(up.url))
            paths = [r["path"] for r in up.requests]
        self.assertIsNone(runner.states["Proxmox"].error)
        self.assertFalse(any(".." in p or "access" in p for p in paths), paths)   # a bad node name never reaches a URL
        out = runner.merged()
        self.assertEqual([h["id"] for h in out["hosts"]], ["Proxmox:5", "Proxmox:pve1", "Proxmox:pve3"])
        pve1 = out["hosts"][1]
        self.assertEqual((pve1["reachable"], pve1["cpu_count"]), (True, 8))
        self.assertNotIn("load", pve1)
        self.assertEqual(pve1["history"]["step"], 3600)
        self.assertIn("pve1: can't read guests 500", [p["text"] for p in out["problems"]])
        self.assertNotIn("not-a-real-one", json.dumps(out))

    def test_failures_are_one_warning(self):
        cases = [({"GET /api2/json/nodes": {"status": 401, "json": {"data": None, "message": "invalid token " + SECRET}}},
                  "Proxmox: 401"),
                 ({"GET /api2/json/nodes": {"json": {"data": {"node": "pve1"}}}}, "Proxmox: answer has no node list")]
        for routes, text in cases:
            with self.subTest(text=text), FakeUpstream({"routes": routes}) as up:
                out = run(spec(up.url)).merged()
            self.assertEqual([p["text"] for p in out["problems"]], [text])
        out = run(spec("http://127.0.0.1:9", env={})).merged()
        self.assertEqual([p["text"] for p in out["problems"]], ["Proxmox: PVE_TOKEN is not set"])

    def test_a_node_the_token_cant_read_is_a_warning(self):
        routes = load_recording("normal")["routes"]
        routes["GET /api2/json/nodes/pve1/status"] = {"status": 403, "json": {"data": None}}
        routes["GET /api2/json/nodes/pve1/rrddata"] = {"status": 403, "json": {"data": None}}
        with FakeUpstream({"routes": routes}) as up:
            out = run(spec(up.url)).merged()
        self.assertIn(("warning", "pve1: can't read status 403, history 403"),
                      [(p["severity"], p["text"]) for p in out["problems"]])
        self.assertEqual(len(out["hosts"][0]["container_list"]), 5)

    def test_config(self):
        bad = [({"url": "http://192.0.2.20:8006"}, "url must be https"),
               ({"token_id": None}, "token_id"), ({"token_id": "monitor@pve"}, "token_id"),
               ({"token_id": "monitor@pve!bridge=" + SECRET}, "token_id"),
               ({"key_env": None}, "key_env is required"),
               ({"token": SECRET}, "looks like a secret"), ({"api_token": SECRET}, "looks like a secret"),
               ({"expect_running": ["web"]}, "expect_running"), ({"disk_warning": 120}, "disk_warning"),
               ({"ui_url": "javascript:x"}, "ui_url"),
               ({"actions": {"reboot": [101]}}, "actions must be"), ({"actions": {"start": [5]}}, "not a VMID"),
               ({"actions": {"start": [{"vmid": 101, "label": 3}]}}, "not a VMID"),
               ({"actions": {"start": "101"}}, "list of VMIDs")]
        for cfg, words in bad:
            with self.subTest(cfg=cfg):
                raw = {"name": "Proxmox", "type": "proxmox", "url": "https://192.0.2.20:8006", "token_id": TOKEN_ID,
                       "key_env": "PVE_TOKEN"}
                raw.update(cfg)
                raw = {k: v for k, v in raw.items() if v is not None}
                with self.assertRaises(rs.ConfigError) as ctx:
                    rs.Config({"tokens": [TOKEN], "sources": [raw]}, env=ENV)
                self.assertIn(words, str(ctx.exception))
        for url in ("https://192.0.2.20:8006", "http://127.0.0.1:8006", "http://localhost:18006/"):
            self.assertEqual(spec(url)["cfg"]["url"], url)

    def test_insecure_is_a_warning_in_status_and_log(self):
        logs = []
        runner = sources.Runner([spec("https://192.0.2.20:8006", insecure=True)], logf=logs.append)
        self.assertEqual(runner.status()[0].get("insecure"), True)
        self.assertTrue(any("insecure: true" in line for line in logs))
        self.assertNotIn("insecure", sources.Runner([spec("https://192.0.2.20:8006")]).status()[0])


class ProxmoxActions(unittest.TestCase):
    """Start and stop are off by default and only for listed VMIDs; the guest is found where it runs now."""

    def setUp(self):
        self.up = FakeUpstream(recording("normal")).start()
        self.addCleanup(self.up.stop)

    def posts(self):
        return [r["path"] for r in self.up.requests if r["method"] != "GET"]

    def test_off_by_default(self):
        runner = run(spec(self.up.url))
        self.assertFalse(runner.actions)
        self.assertEqual(runner.actions.run("guest-start", {"arg": "Proxmox:103"})[0], 404)
        self.assertEqual(self.posts(), [])

    def test_listing(self):
        acts = run(spec(self.up.url, actions={"start": [103, {"vmid": 201, "label": "nginx"}], "stop": ["101"]})).actions
        listed = {a["name"]: a for a in acts.listing()["actions"]}
        self.assertEqual(sorted(listed), ["guest-start", "guest-stop"])
        self.assertNotIn("destructive", listed["guest-start"])
        self.assertTrue(listed["guest-stop"]["destructive"])
        [variant] = listed["guest-start"]["arg"]
        self.assertEqual(variant["parts"], [{"kind": "literal", "text": "Proxmox:"},
                                            {"kind": "choice", "label": "Guest", "options": [
                                                {"value": "103", "label": "103"},
                                                {"value": "201", "label": "nginx (201)"}]}])

    def test_start_and_stop(self):
        acts = run(spec(self.up.url, actions={"start": [103, 201], "stop": [101]})).actions
        self.assertEqual(acts.run("guest-start", {"arg": "Proxmox:103"}),
                         (200, {"ok": True, "text": "Starting win11 (103) on pve1."}))
        self.assertEqual(acts.run("guest-start", {"arg": "Proxmox:201"})[1]["ok"], True)
        self.assertEqual(acts.run("guest-stop", {"arg": "Proxmox:101"}),
                         (200, {"ok": True, "text": "Shutting down jellyfin (101) on pve1."}))
        self.assertEqual(self.posts(), ["/api2/json/nodes/pve1/qemu/103/status/start",
                                        "/api2/json/nodes/pve1/lxc/201/status/start",
                                        "/api2/json/nodes/pve1/qemu/101/status/shutdown"])
        for r in self.up.requests:
            self.assertEqual(r["headers"].get("Authorization"), "PVEAPIToken=%s=%s" % (TOKEN_ID, SECRET))

    def test_refused(self):
        acts = run(spec(self.up.url, actions={"start": [103], "stop": [101]})).actions
        for name, arg, code in (("guest-stop", "Proxmox:103", 400), ("guest-start", "Proxmox:101", 400),
                                ("guest-start", "Proxmox:103/../../../nodes/pve1/status", 400),
                                ("guest-start", "103", 400), ("guest-start", "Proxmox:pve1:103", 400),
                                ("guest-reboot", "Proxmox:103", 404), ("restart-container", "Proxmox:103", 404)):
            with self.subTest(name=name, arg=arg):
                self.assertEqual(acts.run(name, {"arg": arg})[0], code)
        self.assertEqual(self.posts(), [])

    def test_guest_not_found_and_errors_without_the_key(self):
        with FakeUpstream({"routes": {"GET /api2/json/cluster/resources": {"json": {"data": []}}}}) as up:
            acts = sources.SourceActions([spec(up.url, actions={"start": [150]})], secrets=[SECRET])
            self.assertEqual(acts.run("guest-start", {"arg": "Proxmox:150"})[1],
                             {"ok": False, "text": "Proxmox: 150 failed (guest 150 not found)"})
        routes = load_recording("normal")["routes"]
        routes["POST /api2/json/nodes/pve1/qemu/103/status/start"] = {
            "status": 403, "json": {"data": None, "message": "Permission check failed (token %s)" % SECRET}}
        with FakeUpstream({"routes": routes}) as up:
            acts = sources.SourceActions([spec(up.url, actions={"start": [103]})], secrets=[SECRET])
            code, answer = acts.run("guest-start", {"arg": "Proxmox:103"})
        self.assertEqual((code, answer), (200, {"ok": False, "text": "Proxmox: 103 failed (403)"}))


class DockerProxmoxBridge(unittest.TestCase):
    """The sample config with both sources against the fake upstreams: check-live-api passes, the key is in no reply."""

    def config(self):
        with open(os.path.join(HERE, "examples", "sources-docker-proxmox.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        docker = FakeUpstream(recording("normal", "docker")).start()
        pve = FakeUpstream(recording("normal")).start()
        self.addCleanup(docker.stop)
        self.addCleanup(pve.stop)
        by_type = {s["type"]: s for s in raw["sources"]}
        by_type["docker"]["url"], by_type["proxmox"]["url"] = docker.url, pve.url
        raw["listen"] = "127.0.0.1:0"
        return raw, docker, pve

    def start(self, raw):
        tmp = tempfile.mkdtemp(prefix="bridge-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "config.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(raw, fh)
        app = rs.RealApp(rs.Config.load(path, env={"HOMELAB_TOKENS": TOKEN, "PVE_TOKEN": SECRET}))
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and all(st.runs >= 1 for st in app.sources.states.values()))
        return httpd.server_address[1]

    def test_answers_and_no_key(self):
        raw, docker, pve = self.config()
        port = self.start(raw)
        texts = []
        for path in ("/api/v1/info", "/api/v1/state", "/api/v1/services", "/api/v1/actions", "/api/v1/nope"):
            code, resp, obj = call(port, "GET", path, headers=AUTH)
            texts.append(json.dumps(obj) + json.dumps(dict(resp.getheaders())))
        code, _, answer = call(port, "POST", "/api/v1/actions/guest-start", {"arg": "Proxmox:103"}, headers=AUTH)
        texts.append(json.dumps(answer))
        self.assertEqual((code, answer["ok"]), (200, True))
        for text in texts:
            self.assertNotIn(SECRET, text)
            self.assertNotIn("PVE_TOKEN", text)
        state = call(port, "GET", "/api/v1/state", headers=AUTH)[2]
        self.assertEqual([h["id"] for h in state["hosts"]][1:], ["Docker:nas", "Proxmox:pve1", "Proxmox:pve2"])
        self.assertEqual(state["status"], "problem")
        actions = call(port, "GET", "/api/v1/actions", headers=AUTH)[2]["actions"]
        self.assertEqual([a["name"] for a in actions], ["restart-container", "guest-start", "guest-stop"])

    def test_read_only_without_actions(self):
        raw, docker, pve = self.config()
        for s in raw["sources"]:
            s.pop("actions", None)
        port = self.start(raw)
        self.assertNotIn("run-actions", call(port, "GET", "/api/v1/info", headers=AUTH)[2]["features"])
        self.assertEqual(call(port, "GET", "/api/v1/actions", headers=AUTH)[0], 404)
        self.assertEqual([r["method"] for r in docker.requests + pve.requests], ["GET"] * len(docker.requests + pve.requests))

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_passes_on_the_sample_config(self):
        raw, _, _ = self.config()
        port = self.start(raw)
        script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
        res = subprocess.run(["bash", script, "--token", TOKEN, "http://127.0.0.1:%d" % port],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertNotIn(SECRET, res.stdout + res.stderr)
        self.assertNotIn("ERROR", res.stdout)


if __name__ == "__main__":
    unittest.main()
