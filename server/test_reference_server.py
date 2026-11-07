#!/usr/bin/env python3
"""Tests for reference_server.py. Run from the repo root:

    python3 -m unittest -v server/test_reference_server.py
"""

import http.client
import http.server
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402

rs.log = lambda msg: None  # keep test output readable (the CLI test checks real logging)

SERVER = os.path.join(HERE, "reference_server.py")
FIXTURES = os.path.join(os.path.dirname(HERE), "Sources", "HomelabKit", "Fixtures")
TOKEN = "test-token-0123456789abcdef"
LOGIN_HEADER = "Tailscale-User-Login"


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return json.load(fh)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_for(cond, timeout=10.0, step=0.05):
    end = time.time() + timeout
    while time.time() < end:
        value = cond()
        if value:
            return value
        time.sleep(step)
    raise AssertionError("condition not met within %.1f s" % timeout)


class Target(http.server.BaseHTTPRequestHandler):
    """A tiny local web app for the checks: /ok → 200, /bad → 500, /slow → 200 after 1.5 s."""

    def do_GET(self):
        if self.path == "/slow":
            time.sleep(1.5)
        code = {"/ok": 200, "/slow": 200}.get(self.path, 500)
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


class QuietServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def start_http(server):
    t = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
    t.start()
    return server


def start_app(app):
    httpd = rs.build_server(app, "127.0.0.1", 0)
    start_http(httpd)
    app.start()
    return httpd


def stop_app(httpd):
    httpd.app.stop()
    httpd.shutdown()
    httpd.server_close()


def call(port, method, path, body=None, headers=None, raw=None, ctype="application/json"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    h = dict(headers or {})
    data = None
    if raw is not None:
        data = raw
    elif body is not None:
        data = json.dumps(body).encode()
    if data is not None and ctype:
        h["Content-Type"] = ctype
    conn.request(method, path, body=data, headers=h)
    resp = conn.getresponse()
    payload = resp.read()
    conn.close()
    try:
        obj = json.loads(payload.decode()) if payload else None
    except ValueError:
        obj = payload
    return resp.status, resp, obj


AUTH = {"Authorization": "Bearer " + TOKEN}


def keys_union(items):
    out = set()
    for i in items:
        out |= set(i)
    return out


class RealModeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="refsrv-")
        cls.target = start_http(QuietServer(("127.0.0.1", 0), Target))
        tport = cls.target.server_address[1]
        cls.closed = free_port()
        cls.cards = os.path.join(cls.tmp, "cards")
        cls.pending = os.path.join(cls.tmp, "pending")
        os.makedirs(cls.cards)
        os.makedirs(cls.pending)
        with open(os.path.join(cls.cards, "10-backup.json"), "w") as fh:
            json.dump({"id": "backup", "title": "Backup", "icon": "externaldrive", "tint": "green", "style": "list",
                       "items": [{"title": "restic", "value": "ok", "progress": 1}, "not an object"]}, fh)
        with open(os.path.join(cls.cards, "20-broken.json"), "w") as fh:
            fh.write("{not json")
        with open(os.path.join(cls.cards, "30-noid.json"), "w") as fh:
            json.dump({"title": "no id"}, fh)
        cls.config = {
            "_comment": "test config",
            "name": "test lab",
            "tokens": [TOKEN],
            "trust_identity_header": LOGIN_HEADER,
            "allowed_logins": ["alice@example.com"],
            "interval": 1,
            "this_host": {"id": "box", "kind": "server", "disks": ["/"], "docker": False},
            # The real machine's temperature and disk fill must not decide any test's problem list.
            "thresholds": {"temp_warning": 1000, "disk_warning": 1000, "disk_problem": 1001},
            "hosts": [
                {"id": "nas", "name": "nas", "kind": "nas", "check": "tcp://127.0.0.1:%d" % cls.closed},
                {"id": "gpu", "name": "gaming-pc", "kind": "desktop", "sleeps": True,
                 "check": "tcp://127.0.0.1:%d" % cls.closed},
                {"id": "web", "kind": "server", "check": "http://127.0.0.1:%d/bad" % tport},
                {"id": "pc2", "name": "pc-no-dns", "kind": "desktop", "sleeps": True,
                 "check": "ping://no-such-host.invalid"},
            ],
            "checks": [
                {"name": "app-ok", "url": "http://127.0.0.1:%d/ok" % tport, "host": "box"},
                {"name": "app-bad", "url": "http://127.0.0.1:%d/bad" % tport, "host": "box"},
                {"name": "app-warn", "url": "http://127.0.0.1:%d/bad" % tport, "severity": "warning"},
                {"name": "app-slow", "url": "http://127.0.0.1:%d/slow" % tport, "timeout": 5},
                {"name": "app-closed", "url": "tcp://127.0.0.1:%d" % cls.closed, "timeout": 1},
            ],
            "cards_dir": cls.cards,
            "services": [{"name": "Jellyfin", "url": "https://box.example.ts.net:8920", "group": "Media",
                          "icon": "play.rectangle"}],
            "pending_dir": cls.pending,
            "actions": {"restart": ["/bin/echo", "restarted", "{arg}"]},
            "chat_command": ["/bin/cat"],
            "state_dir": os.path.join(cls.tmp, "state"),
        }
        cls.cfg = rs.Config(cls.config, env={})
        cls.app = rs.RealApp(cls.cfg)
        cls.httpd = start_app(cls.app)
        cls.port = cls.httpd.server_address[1]
        wait_for(lambda: cls.app.collector.runs >= 1)

        minimal = {"tokens": [TOKEN], "this_host": {"id": "mini"}, "interval": 60,
                   "thresholds": {"temp_warning": 1000, "disk_warning": 1000, "disk_problem": 1001},
                   "checks": [{"name": "warn-only", "url": "http://127.0.0.1:%d/bad" % tport,
                               "severity": "warning"}]}
        cls.mini_app = rs.RealApp(rs.Config(minimal, env={}))
        cls.mini = start_app(cls.mini_app)
        cls.mini_port = cls.mini.server_address[1]
        wait_for(lambda: cls.mini_app.collector.runs >= 1)

    @classmethod
    def tearDownClass(cls):
        stop_app(cls.httpd)
        stop_app(cls.mini)
        cls.target.shutdown()
        cls.target.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def get(self, path, headers=AUTH, port=None):
        return call(port or self.port, "GET", path, headers=headers)

    def post(self, path, body, headers=AUTH, port=None, **kw):
        return call(port or self.port, "POST", path, body=body, headers=headers, **kw)

    def state(self):
        code, _, obj = self.get("/api/v1/state")
        self.assertEqual(code, 200)
        return obj

    def add_pending(self, pid, **data):
        doc = {"id": pid, "job": "watchdog", "action": "restart", "arg": "media sonarr",
               "reason": "unhealthy for 20 minutes"}
        doc.update(data)
        path = os.path.join(self.pending, pid + ".json")
        with open(path, "w") as fh:
            json.dump(doc, fh)
        return path

    def signed(self, verb, pid):
        """A correctly signed button for the pending file as the server sees it now."""
        return self.app.actions.button(verb, pid, self.app.actions._scan()[pid][1])

    def buttons(self, pid):
        for p in self.state()["pending"]:
            if p["id"] == pid:
                return p["buttons"]
        self.fail("pending %s not listed" % pid)

    # --- auth ---------------------------------------------------------------------------------
    def test_auth_no_credentials_401(self):
        code, _, obj = self.get("/api/v1/info", headers={})
        self.assertEqual(code, 401)
        self.assertIn("error", obj)

    def test_auth_wrong_token_403(self):
        self.assertEqual(self.get("/api/v1/state", headers={"Authorization": "Bearer nope"})[0], 403)
        self.assertEqual(self.get("/api/v1/state", headers={"Authorization": "Basic " + TOKEN})[0], 403)

    def test_auth_right_token_200(self):
        self.assertEqual(self.get("/api/v1/info")[0], 200)

    def test_auth_identity_header_allowed(self):
        code, _, _ = self.get("/api/v1/info", headers={LOGIN_HEADER: "Alice@Example.com"})
        self.assertEqual(code, 200)

    def test_auth_identity_header_not_allowed_403(self):
        self.assertEqual(self.get("/api/v1/info", headers={LOGIN_HEADER: "mallory@example.com"})[0], 403)

    def test_auth_identity_header_ignored_from_remote_peer(self):
        auth = rs.Auth([TOKEN], LOGIN_HEADER, ["alice@example.com"])
        self.assertIsNone(auth.check({LOGIN_HEADER: "alice@example.com"}, "127.0.0.1"))
        self.assertIsNone(auth.check({LOGIN_HEADER: "alice@example.com"}, "::ffff:127.0.0.1"))
        self.assertEqual(auth.check({LOGIN_HEADER: "alice@example.com"}, "100.64.0.7")[0], 401)
        self.assertIsNone(auth.check({"Authorization": "Bearer " + TOKEN}, "100.64.0.7"))

    def test_browser_origin_rejected(self):
        self.assertEqual(self.get("/api/v1/info", headers=dict(AUTH, Origin="https://evil.example"))[0], 403)

    # --- info ---------------------------------------------------------------------------------
    def test_info_shape(self):
        code, _, info = self.get("/api/v1/info")
        self.assertEqual(code, 200)
        self.assertEqual(info["api"], 1)
        self.assertEqual(info["name"], "test lab")
        self.assertEqual(info["auth"], "identity")
        self.assertEqual(set(info["features"]), {"status", "hosts", "actions", "chat", "cards", "services"})
        self.assertLessEqual(set(info), set(fixture("info.json")))

    def test_info_minimal_features(self):
        code, _, info = self.get("/api/v1/info", port=self.mini_port)
        self.assertEqual(info["features"], ["status", "hosts"])
        self.assertEqual(info["auth"], "token")

    def test_headers(self):
        _, resp, _ = self.get("/api/v1/info")
        self.assertEqual(resp.getheader("Content-Type"), "application/json; charset=utf-8")
        self.assertEqual(resp.getheader("Cache-Control"), "no-store")
        _, resp, _ = self.get("/nope", headers={})
        self.assertEqual(resp.getheader("Cache-Control"), "no-store")

    # --- state --------------------------------------------------------------------------------
    def test_state_shape(self):
        s = self.state()
        for key in ("time", "status", "checked", "problems", "hosts", "pending", "cards", "busy"):
            self.assertIn(key, s)
        self.assertIsInstance(s["hosts"], list)
        self.assertIsInstance(s["problems"], list)
        self.assertLessEqual(set(s), set(fixture("state-problem.json")))
        self.assertEqual(s["status"], "problem")

    def test_state_local_host(self):
        box = self.state()["hosts"][0]
        self.assertEqual(box["id"], "box")
        self.assertTrue(box["reachable"])
        self.assertIsInstance(box["cpu_count"], int)
        self.assertIsInstance(box["load"], float)
        self.assertIsInstance(box["disks"]["/"], int)
        self.assertTrue(0 <= box["disks"]["/"] <= 100)
        if os.path.exists("/proc/meminfo"):
            self.assertTrue(0 <= box["mem_pct"] <= 100)
            self.assertIn("reboot_required", box["updates"])

    def test_state_host_keys_match_fixture(self):
        allowed = keys_union(fixture("state-problem.json")["hosts"]) | keys_union(fixture("state-ok.json")["hosts"])
        for h in self.state()["hosts"]:
            self.assertLessEqual(set(h), allowed, h)
            self.assertIsInstance(h["id"], str)

    def test_unreachable_host_is_problem(self):
        s = self.state()
        nas = [h for h in s["hosts"] if h["id"] == "nas"][0]
        self.assertFalse(nas["reachable"])
        self.assertEqual(nas["flags"], [])
        p = [p for p in s["problems"] if p.get("host") == "nas"]
        self.assertEqual(len(p), 1)
        self.assertEqual(p[0]["severity"], "problem")

    def test_sleeping_host_flag(self):
        s = self.state()
        gpu = [h for h in s["hosts"] if h["id"] == "gpu"][0]
        self.assertFalse(gpu["reachable"])
        self.assertEqual(gpu["flags"], ["asleep"])
        self.assertEqual(gpu["name"], "gaming-pc")
        self.assertFalse([p for p in s["problems"] if p.get("host") == "gpu"])

    def test_sleeping_host_that_does_not_resolve_is_a_warning(self):
        s = self.state()
        pc = [h for h in s["hosts"] if h["id"] == "pc2"][0]
        self.assertEqual(pc["flags"], ["asleep"])
        p = [p for p in s["problems"] if p.get("host") == "pc2"]
        self.assertEqual(len(p), 1)
        self.assertEqual(p[0]["severity"], "warning")
        self.assertIn("can't resolve no-such-host.invalid", p[0]["text"])
        self.assertIn("100.x", p[0]["text"])

    def test_http_host_any_answer_is_reachable(self):
        web = [h for h in self.state()["hosts"] if h["id"] == "web"][0]
        self.assertTrue(web["reachable"])

    def test_checks_make_problems(self):
        probs = {p["id"]: p for p in self.state()["problems"]}
        self.assertNotIn("check-app-ok", probs)
        self.assertNotIn("check-app-slow", probs)
        self.assertEqual(probs["check-app-bad"]["severity"], "problem")
        self.assertIn("HTTP 500", probs["check-app-bad"]["text"])
        self.assertEqual(probs["check-app-bad"]["host"], "box")
        self.assertEqual(probs["check-app-warn"]["severity"], "warning")
        self.assertEqual(probs["check-app-closed"]["severity"], "problem")

    def test_problem_keys_match_fixture(self):
        allowed = keys_union(fixture("state-problem.json")["problems"])
        for p in self.state()["problems"]:
            self.assertLessEqual(set(p), allowed)
            self.assertIn("text", p)
            self.assertIn("since", p)

    def test_problem_since_is_stable(self):
        first = {p["id"]: p["since"] for p in self.state()["problems"]}
        runs = self.app.collector.runs
        wait_for(lambda: self.app.collector.runs > runs)
        second = {p["id"]: p["since"] for p in self.state()["problems"]}
        self.assertEqual(first["check-app-bad"], second["check-app-bad"])

    def test_status_warning_only(self):
        _, _, s = self.get("/api/v1/state", port=self.mini_port)
        self.assertEqual(s["status"], "warning")
        self.assertEqual(s["pending"], [])
        self.assertEqual(s["cards"], [])

    def test_status_unknown_and_ok(self):
        # The reading of this machine (temperature, disks) must not matter: thresholds no real value can reach.
        app = rs.RealApp(rs.Config({"tokens": [TOKEN], "this_host": {"disks": []},
                                    "thresholds": {"temp_warning": 1000}}, env={}))
        self.assertEqual(app.state({}, {})[1]["status"], "unknown")
        app.collector.run_once()
        self.assertEqual(app.state({}, {})[1]["status"], "ok")

    def test_state_never_blocks_on_checks(self):
        # app-slow takes 1.5 s each round; /state must still answer at once.
        for _ in range(5):
            start = time.time()
            self.state()
            self.assertLess(time.time() - start, 1.2)   # a blocked answer would take 1.5 s+
            time.sleep(0.2)

    # --- cards / services ---------------------------------------------------------------------
    def test_cards_loaded_bad_skipped(self):
        cards = self.state()["cards"]
        self.assertEqual([c["id"] for c in cards], ["backup"])
        self.assertEqual(cards[0]["items"], [{"title": "restic", "value": "ok", "progress": 1}])
        self.assertIn("updated", cards[0])
        self.assertLessEqual(set(cards[0]), keys_union(fixture("state-problem.json")["cards"]))

    def test_services(self):
        code, _, obj = self.get("/api/v1/services")
        self.assertEqual(code, 200)
        self.assertEqual(obj["services"][0]["name"], "Jellyfin")
        self.assertLessEqual(keys_union(obj["services"]), keys_union(fixture("services.json")["services"]))
        self.assertEqual(self.get("/api/v1/services", port=self.mini_port)[0], 404)

    # --- pending and buttons ------------------------------------------------------------------
    def test_pending_shape_and_signature(self):
        self.add_pending("sh01")
        p = [p for p in self.state()["pending"] if p["id"] == "sh01"][0]
        fx = fixture("state-problem.json")["pending"]
        self.assertLessEqual(set(p), keys_union(fx))
        self.assertLessEqual(set(p["buttons"]), keys_union(x["buttons"] for x in fx))
        self.assertEqual(set(p["buttons"]), {"approve", "deny"})
        data = self.app.actions._scan()["sh01"][1]
        msg = ("APPROVE:sh01:" + rs.Actions.digest(data)).encode()
        sig = rs.hmac.new(self.cfg.button_secret, msg, rs.hashlib.sha256).hexdigest()[:16]
        self.assertEqual(p["buttons"]["approve"], "HOMELAB_APPROVE_sh01_" + sig)
        self.assertIn("created", p)
        os.remove(os.path.join(self.pending, "sh01.json"))

    def test_button_forged_403(self):
        self.add_pending("fg01")
        good = self.buttons("fg01")["approve"]
        forged = good[:-1] + ("0" if good[-1] != "0" else "1")
        self.assertEqual(self.post("/api/v1/button", {"action": forged})[0], 403)
        self.assertEqual(self.post("/api/v1/button", {"action": "HOMELAB_APPROVE_fg01"})[0], 403)
        self.assertEqual(self.post("/api/v1/button", {"action": "rm -rf /"})[0], 403)
        self.assertTrue(os.path.exists(os.path.join(self.pending, "fg01.json")))
        os.remove(os.path.join(self.pending, "fg01.json"))

    def test_button_unknown_id_403(self):
        btn = self.app.actions.button("APPROVE", "gone", {})
        self.assertEqual(self.post("/api/v1/button", {"action": btn})[0], 403)

    def test_button_approve_runs_action(self):
        path = self.add_pending("ap01")
        btn = self.buttons("ap01")["approve"]
        code, _, obj = self.post("/api/v1/button", {"action": btn})
        self.assertEqual(code, 200)
        self.assertIn("restarted media sonarr", obj["text"])
        self.assertIn("exit 0", obj["text"])
        self.assertFalse(os.path.exists(path))
        self.assertEqual(self.post("/api/v1/button", {"action": btn})[0], 403)   # works once

    def test_button_deny_removes(self):
        path = self.add_pending("dn01")
        code, _, obj = self.post("/api/v1/button", {"action": self.buttons("dn01")["deny"]})
        self.assertEqual((code, obj["text"]), (200, "denied dn01"))
        self.assertFalse(os.path.exists(path))

    def test_button_always_only_when_offered(self):
        self.add_pending("al01")
        self.assertNotIn("always", self.buttons("al01"))
        self.assertEqual(self.post("/api/v1/button", {"action": self.signed("ALWAYS", "al01")})[0], 403)
        os.remove(os.path.join(self.pending, "al01.json"))
        self.add_pending("al02", offer_always=True)
        code, _, obj = self.post("/api/v1/button", {"action": self.buttons("al02")["always"]})
        self.assertEqual(code, 200)
        self.assertIn("restarted", obj["text"])

    def test_old_button_does_not_approve_a_new_action_with_the_same_id(self):
        self.add_pending("re01", arg="old")
        old = self.buttons("re01")["approve"]
        self.add_pending("re01", arg="different", created="2026-11-05T10:00:00+01:00")   # a script reuses the id
        code, _, obj = self.post("/api/v1/button", {"action": old})
        self.assertEqual(code, 403)
        self.assertIn("outdated", obj["error"])
        new = self.buttons("re01")["approve"]
        self.assertNotEqual(new, old)
        code, _, obj = self.post("/api/v1/button", {"action": new})
        self.assertEqual(code, 200)
        self.assertIn("different", obj["text"])

    def test_unmounted_volume_is_a_warning_not_root_usage(self):
        folder = tempfile.mkdtemp()   # a plain folder, like /opt/stacks before unlock.sh
        cfg = rs.Config({"name": "t", "tokens": ["x" * 20], "this_host": {"id": "me", "disks": ["/", folder]}}, env={})
        hosts, problems = [], []
        col = rs.Collector(cfg)
        h = col._local(problems)
        self.assertNotIn(folder, h.get("disks", {}))
        self.assertTrue(any("is not mounted" in p["text"] for p in problems))
        os.rmdir(folder)

    def test_trailing_newline_is_not_a_valid_arg(self):
        self.assertIsNone(rs.ARG_RE.fullmatch("safe\n"))
        path = self.add_pending("nl01", arg="safe\n")
        self.assertEqual(set(self.buttons("nl01")), {"deny"})
        os.remove(path)

    def test_chunked_body_refused(self):
        import http.client
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.putrequest("POST", "/api/v1/messages")
        c.putheader(LOGIN_HEADER, "alice@example.com")
        c.putheader("Content-Type", "application/json")
        c.putheader("Transfer-Encoding", "chunked")
        c.endheaders()
        c.send(b"5\r\n{\"a\"}\r\n0\r\n\r\n")
        r = c.getresponse()
        self.assertEqual(r.status, 411)
        c.close()

    def test_host_header_allowlist(self):
        self.assertTrue(rs.host_allowed("box.tail1234.ts.net", rs.DEFAULT_ALLOWED_HOSTS))
        self.assertTrue(rs.host_allowed("127.0.0.1:8791", rs.DEFAULT_ALLOWED_HOSTS))
        self.assertTrue(rs.host_allowed("[::1]:8791", rs.DEFAULT_ALLOWED_HOSTS))
        self.assertFalse(rs.host_allowed("evil.example", rs.DEFAULT_ALLOWED_HOSTS))
        self.assertFalse(rs.host_allowed("ts.net.evil.example", rs.DEFAULT_ALLOWED_HOSTS))
        self.assertFalse(rs.host_allowed("", rs.DEFAULT_ALLOWED_HOSTS))
        import http.client
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", "/api/v1/state", headers={"Host": "evil.example", LOGIN_HEADER: "alice@example.com"})
        r = c.getresponse()
        self.assertEqual(r.status, 403)
        self.assertIn("host not allowed", r.read().decode())
        c.close()

    def test_bad_arg_rejected(self):
        path = self.add_pending("ba01", arg="; rm -rf /")
        self.assertEqual(set(self.buttons("ba01")), {"deny"})
        code, _, obj = self.post("/api/v1/button", {"action": self.signed("APPROVE", "ba01")})
        self.assertEqual(code, 400)
        self.assertNotIn("restarted", json.dumps(obj))
        self.assertTrue(os.path.exists(path))
        os.remove(path)

    def test_unconfigured_action_has_no_approve(self):
        self.add_pending("uc01", action="reboot")
        self.assertEqual(set(self.buttons("uc01")), {"deny"})
        self.assertEqual(self.post("/api/v1/button", {"action": self.signed("APPROVE", "uc01")})[0], 403)
        os.remove(os.path.join(self.pending, "uc01.json"))

    def test_overlapping_presses_run_the_action_once(self):
        path = self.add_pending("ov01")
        btn = self.buttons("ov01")["approve"]
        counter = os.path.join(self.tmp, "ov01.count")
        self.app.actions.commands["count"] = ["/bin/sh", "-c", "echo x >> %s; sleep 0.5" % counter]
        data = self.app.actions._scan()["ov01"][1]
        data["action"] = "count"
        with open(path, "w") as fh:
            json.dump(data, fh)
        btn = self.buttons("ov01")["approve"]
        results = []
        barrier = threading.Barrier(2)

        def press():
            barrier.wait()
            results.append(self.app.actions.press(btn)[0])

        threads = [threading.Thread(target=press) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        with open(counter) as fh:
            self.assertEqual(len(fh.read().split()), 1)
        self.assertEqual(sorted(results), [200, 403] if 403 in results else [200, 200])
        self.assertFalse(os.path.exists(path))
        self.assertFalse(os.path.exists(path + ".running"))
        del self.app.actions.commands["count"]

    def test_arg_regex_and_argv(self):
        for good in ("media sonarr", "nginx.service", "user@host", "a_b-c"):
            self.assertTrue(rs.ARG_RE.match(good), good)
        for bad in ("; rm -rf /", "a  b", " a", "a ", "$(id)", "a;b", "x" * 65, "a\nb", "a/b", "-rf", "media --force"):
            self.assertFalse(rs.ARG_RE.match(bad), bad)
        self.assertEqual(rs.Actions.build_argv(["/bin/echo", "restarted", "{arg}"], "media sonarr"),
                         ["/bin/echo", "restarted", "media", "sonarr"])
        self.assertEqual(rs.Actions.build_argv(["x", "{arg}"], ""), ["x"])

    def test_button_without_actions_403(self):
        self.assertEqual(self.post("/api/v1/button", {"action": "HOMELAB_APPROVE_ab12_0123456789abcdef"},
                                   port=self.mini_port)[0], 403)

    # --- chat ---------------------------------------------------------------------------------
    def test_chat_404_when_not_configured(self):
        self.assertEqual(self.get("/api/v1/messages", port=self.mini_port)[0], 404)
        self.assertEqual(self.post("/api/v1/messages", {"text": "hi"}, port=self.mini_port)[0], 404)

    def test_chat_round_trip(self):
        code, _, obj = self.post("/api/v1/messages", {"text": "hello homelab ✓"})
        self.assertEqual(code, 200)
        self.assertTrue(obj["ok"])
        mid = obj["id"]

        def reply():
            page = self.get("/api/v1/messages?after=%d" % mid)[2]
            return page if page["messages"] else None
        page = wait_for(reply)
        msg = page["messages"][0]
        self.assertEqual((msg["from"], msg["text"], msg["job"], msg["status"]), ("agent", "hello homelab ✓", "chat", "OK"))
        self.assertGreater(msg["id"], mid)
        self.assertLessEqual(set(msg), keys_union(fixture("messages.json")["messages"]))
        self.assertEqual(self.state()["last_message"]["id"], msg["id"])
        wait_for(lambda: not self.app.chat.busy)
        everything = self.get("/api/v1/messages")[2]["messages"]
        self.assertIn(mid, [m["id"] for m in everything])
        self.assertEqual(self.get("/api/v1/messages?after=x")[0], 400)

    def test_chat_busy_429_and_history_file(self):
        state_dir = os.path.join(self.tmp, "chat2")
        chat = rs.Chat(["sleep", "1"], state_dir)
        self.assertEqual(chat.post("one")[0], 200)
        self.assertEqual(chat.page(0)["busy"], ["chat"])
        self.assertEqual(chat.post("two")[0], 429)
        wait_for(lambda: not chat.busy)
        self.assertEqual(chat.page(0)["messages"][-1]["text"], "(no output)")
        again = rs.Chat(["/bin/cat"], state_dir)
        self.assertEqual([m["text"] for m in again.page(0)["messages"]], ["one", "(no output)"])
        self.assertEqual(os.stat(os.path.join(state_dir, "messages.jsonl")).st_mode & 0o077, 0)

    def test_chat_busy_is_reset_when_storing_the_reply_fails(self):
        chat = rs.Chat(["/bin/cat"], os.path.join(self.tmp, "chat3"))
        real = chat._append
        calls = []

        def flaky(msg):
            calls.append(msg)
            if len(calls) == 2:
                raise OSError("disk full")
            real(msg)

        chat._append = flaky
        self.assertEqual(chat.post("one")[0], 200)
        wait_for(lambda: not chat.busy)
        self.assertEqual(chat.post("two")[0], 200)
        wait_for(lambda: not chat.busy)

    # --- request validation -------------------------------------------------------------------
    def test_415_not_json(self):
        self.assertEqual(self.post("/api/v1/messages", None, raw=b"text=hi", ctype="text/plain")[0], 415)

    def test_413_too_large(self):
        big = json.dumps({"text": "x" * 20000}).encode()
        self.assertEqual(self.post("/api/v1/messages", None, raw=big)[0], 413)

    def test_400_bad_bodies(self):
        self.assertEqual(self.post("/api/v1/messages", {"text": ""})[0], 400)
        self.assertEqual(self.post("/api/v1/messages", {"text": "   "})[0], 400)
        self.assertEqual(self.post("/api/v1/messages", {"text": "x" * 4001})[0], 400)
        self.assertEqual(self.post("/api/v1/messages", {"nope": 1})[0], 400)
        self.assertEqual(self.post("/api/v1/messages", None, raw=b"{bad")[0], 400)
        self.assertEqual(self.post("/api/v1/messages", None, raw=b"[1]")[0], 400)
        self.assertEqual(self.post("/api/v1/button", {"action": 7})[0], 400)

    def test_404_and_405(self):
        self.assertEqual(self.get("/api/v1/nope")[0], 404)
        self.assertEqual(self.get("/")[0], 404)
        self.assertEqual(self.get("/__control?state=state-ok.json")[0], 404)
        self.assertEqual(self.get("/api/v1/button")[0], 405)

    def test_real_mode_has_no_deals(self):
        # The reference server has no watcher: /deals is the plain 404 a server answers when it lacks the feature,
        # and the app hides the Deals screen on it.
        self.assertEqual(self.get("/api/v1/deals")[0], 404)

    # --- config -------------------------------------------------------------------------------
    def test_config_errors(self):
        with self.assertRaises(rs.ConfigError):
            rs.Config({}, env={})  # no auth
        with self.assertRaises(rs.ConfigError):
            rs.Config({"tokens": [TOKEN], "hosts": [{"id": "x", "check": "ftp://x"}]}, env={})
        with self.assertRaises(rs.ConfigError):
            rs.Config({"tokens": [TOKEN], "actions": {"r": "systemctl restart x"}, "pending_dir": "/tmp"}, env={})
        with self.assertRaises(rs.ConfigError):
            rs.build_server(rs.RealApp(rs.Config({"tokens": [TOKEN]}, env={})), "0.0.0.0", 0)

    def test_tokens_from_env(self):
        cfg = rs.Config({}, env={"HOMELAB_TOKENS": "aaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbb"})
        self.assertEqual(cfg.tokens, ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"])
        cfg = rs.Config({}, env={"HOMELAB_TOKENS": "aaaaaaaaaaaaaaaa", "HOMELAB_BUTTON_SECRET": "s3cret"})
        self.assertEqual(cfg.button_secret, b"s3cret")

    def test_probe_kinds(self):
        tport = self.target.server_address[1]
        self.assertEqual(rs.probe("http://127.0.0.1:%d/ok" % tport, 2, [200]), (True, "HTTP 200"))
        self.assertFalse(rs.probe("http://127.0.0.1:%d/bad" % tport, 2, [200])[0])
        self.assertTrue(rs.probe("http://127.0.0.1:%d/bad" % tport, 2, None)[0])
        self.assertTrue(rs.probe("tcp://127.0.0.1:%d" % tport, 2)[0])
        self.assertEqual(rs.probe("tcp://127.0.0.1:%d" % self.closed, 2), (False, "connection refused"))


class FixtureModeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = rs.FixtureApp(FIXTURES, "state-problem.json", echo_delay=0.3)
        cls.httpd = start_app(cls.app)
        cls.port = cls.httpd.server_address[1]

    @classmethod
    def tearDownClass(cls):
        stop_app(cls.httpd)

    def setUp(self):
        call(self.port, "GET", "/__control?state=state-problem.json&reset=1")

    def test_serves_every_fixture(self):
        self.assertEqual(call(self.port, "GET", "/api/v1/info")[2], fixture("info.json"))
        self.assertEqual(call(self.port, "GET", "/api/v1/state")[2], fixture("state-problem.json"))
        self.assertEqual(call(self.port, "GET", "/api/v1/services")[2], fixture("services.json"))
        page = call(self.port, "GET", "/api/v1/messages")[2]
        self.assertEqual(page["messages"], fixture("messages.json")["messages"])
        self.assertEqual(page["busy"], [])

    def test_search_filters_the_catalogue(self):
        code, _, obj = call(self.port, "GET", "/api/v1/search?q=%20%20QUIET%20")
        self.assertEqual(code, 200)
        self.assertEqual(obj["query"], "QUIET")
        self.assertEqual([i["title"] for c in obj["cards"] for i in c["items"]], ["The Long Quiet", "The Quiet Garden"])
        self.assertEqual(obj["cards"][0]["style"], "poster-grid")
        self.assertEqual(call(self.port, "GET", "/api/v1/search?q=zzzz")[2], {"query": "zzzz", "cards": []})
        for bad in ("", "?q=", "?q=a", "?q=" + "x" * 101, "?q=a%00b"):
            self.assertEqual(call(self.port, "GET", "/api/v1/search" + bad)[0], 400, bad)
        self.assertEqual(call(self.port, "POST", "/api/v1/search", {})[0], 405)
        self.assertIn("search", call(self.port, "GET", "/api/v1/info")[2]["features"])

    def test_deals_are_served_as_they_are(self):
        code, _, obj = call(self.port, "GET", "/api/v1/deals")
        self.assertEqual((code, obj), (200, fixture("deals.json")))
        self.assertIn("deals", call(self.port, "GET", "/api/v1/info")[2]["features"])
        self.assertEqual(call(self.port, "POST", "/api/v1/deals", {})[0], 405)
        # The contract's shape: newest first, at most 100, an ad number and a title each.
        deals = obj["deals"]
        self.assertTrue(0 < len(deals) <= 100)
        self.assertEqual([d["seen"] for d in deals if d.get("verdict") == "act"],
                         sorted((d["seen"] for d in deals if d.get("verdict") == "act"), reverse=True))
        for d in deals:
            self.assertTrue(isinstance(d["id"], int) and d["title"])
            self.assertIn(d.get("verdict"), ("act", "consider", "skip", None))
            self.assertIn(d.get("conf"), ("high", "medium", "low", None))

    def test_posters_are_pngs_for_named_files_only(self):
        item = fixture("search.json")["cards"][0]["items"][0]
        code, resp, body = call(self.port, "GET", item["image"])
        self.assertEqual(code, 200)
        self.assertEqual(resp.getheader("Content-Type"), "image/png")
        self.assertTrue(body.startswith(b"\x89PNG\r\n\x1a\n") and len(body) < 20000)
        self.assertEqual(call(self.port, "GET", item["image"].replace("w342", "w154"))[0], 200)
        for bad in ("/api/v1/poster/w342/unknownfile1.png", "/api/v1/poster/w999/demoposter01.png",
                    "/api/v1/poster/w342/../demoposter01.png", "/api/v1/poster/w342/demoposter01.gif"):
            self.assertEqual(call(self.port, "GET", bad)[0], 404, bad)

    def test_control_switches_state(self):
        for name in ("state-ok.json", "state-empty.json", "state-legacy.json"):
            code, _, obj = call(self.port, "GET", "/__control?state=" + name)
            self.assertEqual((code, obj["state"]), (200, name))
            self.assertEqual(call(self.port, "GET", "/api/v1/state")[2], fixture(name))
        self.assertEqual(call(self.port, "GET", "/__control?state=../etc/passwd")[0], 400)
        self.assertEqual(call(self.port, "GET", "/__control?state=missing.json")[0], 400)

    def test_echo_and_busy(self):
        code, _, obj = call(self.port, "POST", "/api/v1/messages", {"text": "ping"})
        self.assertEqual(code, 200)
        page = call(self.port, "GET", "/api/v1/messages?after=%d" % obj["id"])[2]
        self.assertEqual((page["messages"], page["busy"]), ([], ["chat"]))
        self.assertEqual(call(self.port, "GET", "/api/v1/state")[2]["busy"], ["chat"])
        page = wait_for(lambda: call(self.port, "GET", "/api/v1/messages?after=%d" % obj["id"])[2]["messages"])
        self.assertEqual(page[0]["text"], "echo: ping")
        self.assertEqual(page[0]["from"], "agent")
        self.assertEqual(call(self.port, "GET", "/api/v1/messages")[2]["busy"], [])

    def test_buttons(self):
        code, _, obj = call(self.port, "POST", "/api/v1/button", {"action": "HOMELAB_APPROVE_ab12_0123456789abcdef"})
        self.assertEqual((code, obj), (200, {"text": "approved ab12 (fixture)"}))
        code, _, obj = call(self.port, "POST", "/api/v1/button", {"action": "HOMELAB_DENY_cd34_4123456789abcdef"})
        self.assertEqual((code, obj["text"]), (200, "denied cd34 (fixture)"))
        self.assertEqual(call(self.port, "POST", "/api/v1/button",
                              {"action": "HOMELAB_APPROVE_ab12_ffffffffffffffff"})[0], 403)
        call(self.port, "GET", "/__control?state=state-ok.json")
        self.assertEqual(call(self.port, "POST", "/api/v1/button",
                              {"action": "HOMELAB_APPROVE_ab12_0123456789abcdef"})[0], 403)

    def test_message_proposals_have_working_buttons(self):
        msgs = call(self.port, "GET", "/api/v1/messages")[2]["messages"]
        pending = [p for m in msgs for p in m.get("pending", [])]
        self.assertTrue(pending)
        self.assertTrue(any(m.get("cards") for m in msgs))
        for p in pending:
            for verb, button in p["buttons"].items():
                self.assertEqual(call(self.port, "POST", "/api/v1/button", {"action": button})[0], 200, verb)

    def test_card_item_actions_are_listed(self):
        names = {a["name"] for a in fixture("actions.json")["actions"]}
        cards = fixture("state-problem.json")["cards"]
        used = [c["action"] for c in cards if "action" in c] + [i["action"] for c in cards for i in c.get("items", [])
                                                                 if "action" in i]
        self.assertTrue(used)
        for a in used:
            self.assertIn(a["name"], names)
            if a["name"] == "todo-done":
                code, _, obj = call(self.port, "POST", "/api/v1/actions/todo-done",
                                    {"arg": a.get("arg", ""), "payload": a["payload"]})
                self.assertEqual((code, obj["ok"]), (200, True))

    def test_actions(self):
        self.assertEqual(call(self.port, "GET", "/api/v1/actions")[2], fixture("actions.json"))
        self.assertIn("run-actions", fixture("info.json")["features"])
        code, _, obj = call(self.port, "POST", "/api/v1/actions/wake-set", {"arg": "2026-11-07T07:00", "payload": {}})
        self.assertEqual((code, obj), (200, {"ok": True, "text": "Done: wake-set 2026-11-07T07:00 (fixture)"}))
        code, _, obj = call(self.port, "POST", "/api/v1/actions/todo-add", {"payload": {"summary": "Milk"}})
        self.assertEqual((code, obj["ok"]), (200, True))
        # "arg": null is no argument, like a missing or empty one.
        code, _, obj = call(self.port, "POST", "/api/v1/actions/todo-add", {"arg": None, "payload": {"summary": "Milk"}})
        self.assertEqual((code, obj["ok"]), (200, True))
        msgs = call(self.port, "GET", "/api/v1/messages")[2]["messages"][-2:]
        self.assertEqual([m["text"] for m in msgs], ["Add a to-do: Milk", "Done: todo-add (fixture)"])
        bad = [("todo-add", {"payload": {}}), ("todo-add", {"payload": {"summary": "x", "evil": "y"}}),
               ("todo-add", {"payload": {"summary": 5}}), ("wake-set", {"arg": ""}), ("todo-add", {"arg": "x"}),
               ("todo-add", {"payload": ["x"]})]
        for name, body in bad:
            self.assertEqual(call(self.port, "POST", "/api/v1/actions/" + name, body)[0], 400, (name, body))
        self.assertEqual(call(self.port, "POST", "/api/v1/actions/nope", {})[0], 404)
        self.assertEqual(call(self.port, "GET", "/api/v1/actions/todo-add")[0], 405)

    # ---- documents and shares (fixture mode keeps them in memory)

    def pdf_call(self, body=b"%PDF-1.4 fixture", headers=None, ctype="application/pdf", port=None):
        h = {"X-Homelab-Id": "0b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c11"}
        h.update(headers or {})
        return call(port or self.port, "POST", "/api/v1/documents", raw=body, headers=h, ctype=ctype)

    def test_info_lists_documents_and_share(self):
        features = call(self.port, "GET", "/api/v1/info")[2]["features"]
        self.assertIn("documents", features)
        self.assertIn("share", features)

    def test_document_upload(self):
        code, _, obj = self.pdf_call(headers={"X-Homelab-Title": "Rechnung%20M%C3%A4rz%0A%00x"})
        self.assertEqual(code, 202)
        self.assertEqual(obj["ok"], True)
        self.assertEqual(obj["id"], "0b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c11")
        self.assertIn("Paperless", obj["text"])
        doc = self.app.documents[-1]
        self.assertEqual((doc["title"], doc["bytes"]), ("Rechnung März x", len(b"%PDF-1.4 fixture")))
        # the same id again: the first answer, nothing stored twice
        before = len(self.app.documents)
        self.assertEqual(self.pdf_call(body=b"%PDF-1.4 other")[2], obj)
        self.assertEqual(len(self.app.documents), before)

    def test_document_rejections(self):
        self.assertEqual(self.pdf_call(ctype="application/json")[0], 415)
        self.assertEqual(self.pdf_call(ctype="text/plain")[0], 415)
        self.assertEqual(self.pdf_call(body=b"GIF89a....")[0], 400)
        self.assertEqual(self.pdf_call(headers={"X-Homelab-Id": "not-a-uuid"})[0], 400)
        self.assertEqual(self.pdf_call(headers={"X-Homelab-Id": "X" * 36})[0], 400)
        self.assertEqual(call(self.port, "POST", "/api/v1/documents", raw=b"%PDF-1", ctype="application/pdf")[0], 400)
        self.assertEqual(call(self.port, "GET", "/api/v1/documents")[0], 405)
        self.assertEqual(self.pdf_call(headers={"Origin": "https://evil.example"})[0], 403)

    def raw_post(self, headers):
        """Sends only headers (no body), for sizes we don't want to transfer."""
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        try:
            lines = ["POST /api/v1/documents HTTP/1.1", "Host: 127.0.0.1"] + headers + ["", ""]
            sock.sendall("\r\n".join(lines).encode())
            return int(sock.recv(4096).split(b" ", 2)[1])
        finally:
            sock.close()

    def test_document_size_and_length_rules(self):
        base = ["Content-Type: application/pdf", "X-Homelab-Id: 0b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c12"]
        self.assertEqual(self.raw_post(base + ["Content-Length: %d" % (25 * 1024 * 1024 + 1)]), 413)
        self.assertEqual(self.raw_post(base), 411)
        self.assertEqual(self.raw_post(base + ["Content-Length: abc"]), 400)

    def test_document_quota(self):
        for i in range(rs.UPLOADS_PER_HOUR):
            code = self.pdf_call(headers={"X-Homelab-Id": "%036x" % (i + 1)})[0]
            self.assertEqual(code, 202, i)
        self.assertEqual(self.pdf_call(headers={"X-Homelab-Id": "%036x" % 999})[0], 429)

    def test_document_token(self):
        app = rs.FixtureApp(FIXTURES, token="fixture-token")
        httpd = start_app(app)
        try:
            port = httpd.server_address[1]
            self.assertEqual(self.pdf_call(port=port)[0], 401)
            self.assertEqual(self.pdf_call(port=port, headers={"Authorization": "Bearer fixture-token"})[0], 202)
        finally:
            stop_app(httpd)

    def share(self, **body):
        body.setdefault("id", "1b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c11")
        body.setdefault("kind", "url")
        return call(self.port, "POST", "/api/v1/share", body)

    def test_share_routes(self):
        code, _, obj = self.share(url="https://www.willhaben.at/iad/kaufen-und-verkaufen/d/phone-1234567890/", title="Ad")
        self.assertEqual((code, obj["route"], obj["ok"]), (200, "willhaben", True))
        self.assertEqual(self.app.shares[-1]["ad_id"], "1234567890")
        code, _, obj = self.share(id="2b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c11",
                                  url="https://www.willhaben.at/iad/object?adId=998877665")
        self.assertEqual((code, obj["route"]), (200, "willhaben"))
        self.assertEqual(self.app.shares[-1]["ad_id"], "998877665")
        code, _, obj = self.share(id="3b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c11", url="https://example.org/post?a=1",
                                  title="A\nB")
        self.assertEqual((code, obj["route"]), (200, "read-later"))
        self.assertEqual(self.app.shares[-1]["title"], "A B")
        code, _, obj = self.share(id="4b9c2f3e-3b1a-4d6f-8e0a-2f6f1f6a9c11",
                                  url="https://www.willhaben.at.evil.example/iad/x-1234567890/")
        self.assertEqual(obj["route"], "read-later")

    def test_share_is_idempotent(self):
        first = self.share(url="https://example.org/a")[2]
        again = self.share(url="https://example.org/DIFFERENT")[2]
        self.assertEqual(first, again)
        self.assertEqual(len(self.app.shares), 1)

    def test_share_refusals(self):
        bad = [dict(url="file:///etc/passwd"), dict(url="javascript:alert(1)"), dict(url="ftp://x.org/f"),
               dict(url="https://user:pw@example.org/"), dict(url="https://example.org/" + "a" * 2100),
               dict(url="no link here"), dict(url=5), dict(url="https://example.org", kind="text"),
               dict(url="https://example.org", id="nope"), dict(url="https://example.org", title=5)]
        for body in bad:
            self.assertEqual(self.share(**body)[0], 400, body)
        self.assertEqual(self.app.shares, [])
        self.assertEqual(call(self.port, "POST", "/api/v1/share", None, raw=b"x", ctype="text/plain")[0], 415)

    def test_share_quota(self):
        for i in range(rs.SHARES_PER_HOUR):
            self.assertEqual(self.share(id="%036x" % (i + 1), url="https://example.org/%d" % i)[0], 200, i)
        self.assertEqual(self.share(id="%036x" % 999, url="https://example.org/x")[0], 429)

    def test_validation(self):
        self.assertEqual(call(self.port, "POST", "/api/v1/messages", {"text": ""})[0], 400)
        self.assertEqual(call(self.port, "POST", "/api/v1/messages", None, raw=b"hi", ctype="text/plain")[0], 415)
        self.assertEqual(call(self.port, "GET", "/api/v1/nothing")[0], 404)

    def test_token(self):
        app = rs.FixtureApp(FIXTURES, token="fixture-token")
        httpd = start_app(app)
        port = httpd.server_address[1]
        try:
            self.assertEqual(call(port, "GET", "/api/v1/info")[0], 401)
            self.assertEqual(call(port, "GET", "/api/v1/info", headers={"Authorization": "Bearer x"})[0], 403)
            code, _, info = call(port, "GET", "/api/v1/info", headers={"Authorization": "Bearer fixture-token"})
            self.assertEqual(code, 200)
        finally:
            stop_app(httpd)


GOLDENS = os.path.join(HERE, "goldens")


def _masked(obj, this_host):
    """Times become "<time>"; this host's own numbers (load, temperature, disks: they differ per machine and run) are
    reduced to what doesn't change. Everything else stays as served."""
    if isinstance(obj, dict):
        if obj.get("id") == this_host and "reachable" in obj:
            return {k: obj[k] for k in ("id", "name", "kind", "reachable") if k in obj}
        return {k: ("<time>" if k in ("time", "checked", "since") else _masked(v, this_host)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_masked(x, this_host) for x in obj]
    return obj


class NoSourcesGolden(unittest.TestCase):
    """docs/plans/MODULAR.md, M0.2: without a `sources` key the server answers exactly as before. Real mode with a
    fixed config and fixture mode, GET /info, /state, /actions, /services, compared with server/goldens/no-sources.json.
    A difference means a change reached setups that don't use sources: stop and ask the owner. UPDATE_GOLDENS=1
    rewrites the file for an approved change."""

    def test_answers_match_the_golden(self):
        tmp = tempfile.mkdtemp(prefix="refsrv-golden-")
        try:
            cfg = {"name": "golden lab", "tokens": [TOKEN], "interval": 60,
                   "this_host": {"id": "box", "kind": "server", "disks": ["/"], "docker": False},
                   "thresholds": {"temp_warning": 1000, "disk_warning": 1000, "disk_problem": 1001},
                   "hosts": [{"id": "nas", "name": "nas", "kind": "nas", "check": "tcp://127.0.0.1:%d" % free_port()}],
                   "services": [{"name": "Jellyfin", "url": "https://box.example.ts.net:8920", "group": "Media",
                                 "icon": "play.rectangle"}],
                   "pending_dir": os.path.join(tmp, "pending"), "actions": {"restart": ["/bin/echo", "{arg}"]},
                   "state_dir": os.path.join(tmp, "state")}
            os.makedirs(cfg["pending_dir"])
            real = rs.RealApp(rs.Config(cfg, env={}))
            fix = rs.FixtureApp(FIXTURES, "state-problem.json", echo_delay=0.3)
            servers = {"real": start_app(real), "fixtures": start_app(fix)}
            wait_for(lambda: real.collector.runs >= 1)
            seen = {}
            for mode, httpd in servers.items():
                for path in ("/api/v1/info", "/api/v1/state", "/api/v1/actions", "/api/v1/services"):
                    code, _, obj = call(httpd.server_address[1], "GET", path, headers=AUTH)
                    seen["%s %s" % (mode, path)] = {"code": code, "body": _masked(obj, "box")}
            for httpd in servers.values():
                stop_app(httpd)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        now = json.dumps(seen, indent=2, sort_keys=True) + "\n"
        path = os.path.join(GOLDENS, "no-sources.json")
        if os.environ.get("UPDATE_GOLDENS") == "1":
            os.makedirs(GOLDENS, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(now)
        with open(path, encoding="utf-8") as fh:
            golden = json.load(fh)
        for key in sorted(set(golden) | set(seen)):
            self.assertEqual(seen.get(key), golden.get(key), "answer changed: %s (server/goldens/no-sources.json)" % key)


class CliTest(unittest.TestCase):
    def test_fixture_cli_and_sigterm(self):
        port = free_port()
        proc = subprocess.Popen([sys.executable, SERVER, "--fixtures", FIXTURES, "--port", str(port),
                                 "--state", "state-ok.json", "--token", "cli-token"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            def up():
                try:
                    return call(port, "GET", "/api/v1/state", headers={"Authorization": "Bearer cli-token"})
                except OSError:
                    return None
            code, _, state = wait_for(up)
            self.assertEqual(code, 200)
            self.assertEqual(state["status"], "ok")
            call(port, "POST", "/api/v1/messages", {"text": "secret message"},
                 headers={"Authorization": "Bearer cli-token"})
        finally:
            proc.send_signal(signal.SIGTERM)
            _, err = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0)
        err = err.decode()
        self.assertIn("stopped", err)
        self.assertIn("GET /api/v1/state 200", err)
        self.assertNotIn("cli-token", err)
        self.assertNotIn("secret message", err)

    def test_real_cli_refuses_remote_bind(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"listen": "0.0.0.0:0", "tokens": [TOKEN]}, fh)
        try:
            res = subprocess.run([sys.executable, SERVER, "--config", fh.name], capture_output=True, timeout=10)
        finally:
            os.remove(fh.name)
        self.assertEqual(res.returncode, 2)
        self.assertIn(b"refusing to listen", res.stderr)

    def test_example_config_loads(self):
        cfg = rs.Config.load(os.path.join(HERE, "config.example.json"), env={"HOMELAB_TOKENS": TOKEN})
        self.assertEqual((cfg.host, cfg.port), ("127.0.0.1", 8791))
        self.assertIsNone(cfg.chat_command)
        self.assertEqual(cfg.actions, {})


class StaleRunningTest(unittest.TestCase):
    def test_old_running_files_are_swept_at_start(self):
        d = tempfile.mkdtemp(prefix="pend-")
        self.addCleanup(shutil.rmtree, d, True)
        old, new, pend = (os.path.join(d, n) for n in ("a.json.running", "b.json.running", "c.json"))
        for p in (old, new, pend):
            open(p, "w").write("{}")
        os.utime(old, (time.time() - 1000, time.time() - 1000))
        rs.Actions(d, {}, b"secret", timeout=110.0)
        self.assertEqual(sorted(os.listdir(d)), ["b.json.running", "c.json"])


class TailscaleModeTest(unittest.TestCase):
    """The bridge image refuses TS_USERSPACE=true with a trusted Tailscale login header (every tailnet device could
    reach 127.0.0.1:8791 and fake the header) and stops when the shared namespace has no tailscale0."""

    IMAGE = {"HOMELAB_BRIDGE_IMAGE": "1"}

    def setUp(self):
        self.logs = []
        orig = rs.log
        rs.log = self.logs.append
        self.addCleanup(setattr, rs, "log", orig)
        self.tmp = tempfile.mkdtemp(prefix="netdev-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def cfg(self, header=LOGIN_HEADER):
        raw = {"listen": "127.0.0.1:0", "trust_identity_header": header, "allowed_logins": ["you@example.com"]}
        return rs.Config(raw, {})

    def net_dev(self, *names):
        path = os.path.join(self.tmp, "dev")
        with open(path, "w") as fh:
            fh.write("Inter-|   Receive\n face |bytes\n")
            fh.writelines("%6s: 0 0 0 0\n" % n for n in names)
        return path

    def check(self, env, *names, header=LOGIN_HEADER):
        self.exits = []
        thread = rs.check_tailscale_mode(self.cfg(header), env, wait=0.2, step=0.02, net_dev=self.net_dev(*names),
                                         exit_fn=self.exits.append)
        if thread:
            thread.join(5)
        return thread

    def test_userspace_refused_unless_overridden(self):
        for value in ("true", "1", "TRUE"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(rs.ConfigError, "HOMELAB_ALLOW_USERSPACE=1"):
                    self.check(dict(self.IMAGE, TS_USERSPACE=value), "lo", "eth0")
        self.assertIsNone(self.check(dict(self.IMAGE, TS_USERSPACE="true", HOMELAB_ALLOW_USERSPACE="1"), "lo"))
        self.assertTrue(any(line.startswith("WARNING: TS_USERSPACE=true") for line in self.logs))

    def test_no_tailscale0_fails_closed(self):
        self.assertIsNotNone(self.check(dict(self.IMAGE), "lo", "eth0"))
        self.assertEqual(self.exits, [3])
        self.assertEqual(len(self.logs), 1)
        self.assertTrue(self.logs[0].startswith("ERROR: no tailscale0 interface"))
        self.assertIn("127.0.0.1 ports", self.logs[0])

    def test_no_tailscale0_with_override_only_warns(self):
        self.check(dict(self.IMAGE, HOMELAB_ALLOW_USERSPACE="1"), "lo", "eth0")
        self.assertEqual(self.exits, [])
        self.assertTrue(self.logs[0].startswith("WARNING: no tailscale0 interface"))

    def test_kernel_mode_is_quiet(self):
        self.check(dict(self.IMAGE, TS_USERSPACE="false"), "lo", "eth0", "tailscale0")
        self.assertEqual(self.logs, [])
        self.assertEqual(self.exits, [])

    def test_only_in_the_image_and_with_a_tailscale_header(self):
        self.assertIsNone(self.check({"TS_USERSPACE": "true"}, "lo"))
        self.assertIsNone(self.check(dict(self.IMAGE, TS_USERSPACE="true"), "lo", header="X-Forwarded-User"))
        tokens = rs.Config({"listen": "127.0.0.1:0", "tokens": [TOKEN]}, {})
        self.assertIsNone(rs.check_tailscale_mode(tokens, dict(self.IMAGE, TS_USERSPACE="true")))
        self.assertEqual(self.logs, [])

    def test_header_not_trusted_until_tailscale0_exists(self):
        now = [0.0]
        gate = rs.TailscaleGate(recheck=2.0, clock=lambda: now[0])
        auth = rs.Auth([TOKEN], LOGIN_HEADER, ["you@example.com"])
        auth.identity_ready = gate.ready
        net = self.net_dev("lo", "eth0")
        rs.check_tailscale_mode(self.cfg(), dict(self.IMAGE), wait=0.0, net_dev=net, exit_fn=lambda c: None, gate=gate)
        forged = {LOGIN_HEADER: "you@example.com"}
        self.assertEqual(auth.check(forged, "127.0.0.1")[0], 401)
        self.assertIsNone(auth.check({"Authorization": "Bearer " + TOKEN}, "127.0.0.1"))
        self.net_dev("lo", "eth0", "tailscale0")
        self.assertEqual(auth.check(forged, "127.0.0.1")[0], 401)  # re-probe is cached for `recheck`
        now[0] = 3.0
        self.assertIsNone(auth.check(forged, "127.0.0.1"))
        self.net_dev("lo")  # once found, stays trusted
        now[0] = 10.0
        self.assertIsNone(auth.check(forged, "127.0.0.1"))

    def test_a_request_waiting_for_the_probe_sees_its_result(self):
        # A thread that waited on the lock while another thread's probe found tailscale0 gets True, not a 401.
        gate = rs.TailscaleGate(recheck=60.0, clock=lambda: 0.0)
        gate.arm(self.net_dev("lo"))
        result = []
        with gate.lock:
            t = threading.Thread(target=lambda: result.append(gate.ready()))
            t.start()
            time.sleep(0.2)                       # past the lock-free check, now waiting for the lock
            gate.found, gate.next_probe = True, 60.0
        t.join(5)
        self.assertEqual(result, [True])

    def test_header_trusted_with_the_override_and_outside_the_image(self):
        for env in (dict(self.IMAGE, HOMELAB_ALLOW_USERSPACE="1"), {}):
            gate = rs.TailscaleGate()
            auth = rs.Auth([TOKEN], LOGIN_HEADER, ["you@example.com"])
            auth.identity_ready = gate.ready
            rs.check_tailscale_mode(self.cfg(), env, wait=0.0, net_dev=self.net_dev("lo"), exit_fn=lambda c: None,
                                    gate=gate)
            self.assertIsNone(auth.check({LOGIN_HEADER: "you@example.com"}, "127.0.0.1"))

    def test_unreadable_proc_fails_closed(self):
        gate = rs.TailscaleGate()
        auth = rs.Auth([TOKEN], LOGIN_HEADER, ["you@example.com"])
        auth.identity_ready = gate.ready
        missing = os.path.join(self.tmp, "nope")
        rs.check_tailscale_mode(self.cfg(), dict(self.IMAGE), wait=0.0, net_dev=missing, exit_fn=lambda c: None,
                                gate=gate)
        self.assertEqual(auth.check({LOGIN_HEADER: "you@example.com"}, "127.0.0.1")[0], 401)
        self.assertTrue(any("cannot read" in line for line in self.logs))
        gate = rs.TailscaleGate()
        rs.check_tailscale_mode(self.cfg(), dict(self.IMAGE, HOMELAB_ALLOW_USERSPACE="1"), wait=0.0, net_dev=missing,
                                exit_fn=lambda c: None, gate=gate)
        self.assertTrue(gate.ready())

    def test_cli_stops_at_start(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"listen": "127.0.0.1:0", "trust_identity_header": LOGIN_HEADER,
                       "allowed_logins": ["you@example.com"]}, fh)
        self.addCleanup(os.remove, fh.name)
        env = dict(os.environ, HOMELAB_BRIDGE_IMAGE="1", TS_USERSPACE="true")
        env.pop("HOMELAB_ALLOW_USERSPACE", None)
        res = subprocess.run([sys.executable, SERVER, "--config", fh.name], capture_output=True, timeout=10, env=env)
        self.assertEqual(res.returncode, 2)
        self.assertIn(b"TS_USERSPACE=true with trust_identity_header: refused", res.stderr)


if __name__ == "__main__":
    unittest.main()
