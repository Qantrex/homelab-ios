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
        app = rs.RealApp(rs.Config({"tokens": [TOKEN], "this_host": {"disks": []}}, env={}))
        self.assertEqual(app.state({}, {})[1]["status"], "unknown")
        app.collector.run_once()
        self.assertEqual(app.state({}, {})[1]["status"], "ok")

    def test_state_never_blocks_on_checks(self):
        # app-slow takes 1.5 s each round; /state must still answer at once.
        for _ in range(5):
            start = time.time()
            self.state()
            self.assertLess(time.time() - start, 0.5)
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


if __name__ == "__main__":
    unittest.main()
