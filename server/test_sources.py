#!/usr/bin/env python3
"""Tests for the Homelab Bridge sources interface (server/sources/, docs/BRIDGE.md). Run from the repo root:

    python3 -m unittest -v server/test_sources.py

Stdlib only; every upstream is server/fake_upstream.py replaying a recording on 127.0.0.1.
"""

import ast
import base64
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.parse
import urllib.request
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402
import sources  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None

RECORDINGS = os.path.join(HERE, "recordings")
SECRET = "s3cr3t-key-0123456789abcdef"
ENV = {"LAB_KEY": SECRET}


def recording(kind, case):
    return os.path.join(RECORDINGS, kind, case + ".json")


def fake_type(collect, check=None):
    mod = types.SimpleNamespace(collect=collect)
    if check:
        mod.check = check
    return mod


def spec(name="Lab", kind="example", env=None, **cfg):
    raw = dict({"name": name, "type": kind}, **cfg)
    return sources.parse([raw], ENV if env is None else env)[0]


def run(spec_):
    runner = sources.Runner([spec_])
    runner.run_one(spec_)
    return runner


# Test-only source types (sources.register): a crash, a hang, a junk result, one that leaks its key.
def _crash(cfg, fetch):
    raise RuntimeError("boom with %s inside" % fetch.secret())


_release = threading.Event()


def _hang(cfg, fetch):
    _release.wait(cfg.get("sleep", 3))
    return {}


def _static(cfg, fetch):
    return copy.deepcopy(cfg["result"])


def _leak(cfg, fetch):
    key = fetch.secret()
    return {"problems": [{"id": "p", "text": "key is %s" % key}],
            "hosts": [{"id": "h", "name": "h", "token": key, "note": "x" + key + "y"}],
            "cards": [{"id": "c", "title": key, "items": [{"title": "t", "value": key, "api_key": key}]}],
            "services": [{"name": "S", "url": "http://192.0.2.1/?k=" + key}]}


def _junk(cfg, fetch):
    return {"problems": [{"text": "when"}], "hosts": [{"id": "h", "seen": object()}]}


def _not_dict(cfg, fetch):
    return ["a list"]


def _count(cfg, fetch):
    _count.calls += 1
    return {"problems": [{"id": "always", "text": "still here"}]}


_count.calls = 0

for _kind, _fn in (("t-crash", _crash), ("t-hang", _hang), ("t-static", _static), ("t-leak", _leak),
                   ("t-junk", _junk), ("t-not-dict", _not_dict), ("t-count", _count)):
    sources.register(_kind, fake_type(_fn))


class ConfigRules(unittest.TestCase):
    """The `sources` key: defaults, names, types, and no secret in the config."""

    def test_no_sources_key_changes_nothing(self):
        cfg = rs.Config({"tokens": [TOKEN]}, env={})
        self.assertEqual(cfg.sources, [])
        self.assertIsNone(rs.RealApp(cfg).sources)
        self.assertEqual(rs.Config({"tokens": [TOKEN], "sources": []}, env={}).sources, [])

    def test_defaults(self):
        s = spec(url="http://192.0.2.10:8080", key_env="LAB_KEY")
        self.assertEqual((s["every"], s["timeout"], s["cfg"]["insecure"]), (60.0, 10.0, False))
        self.assertEqual(s["env"], {"LAB_KEY": SECRET})
        self.assertEqual(s["cfg"]["name"], "Lab")

    def test_only_the_named_env_reaches_the_source(self):
        s = sources.parse([{"name": "Lab", "type": "t-static", "result": {}, "key_env": "LAB_KEY"}],
                          {"LAB_KEY": SECRET, "OTHER": "nope", "HOMELAB_TOKENS": TOKEN})[0]
        self.assertEqual(s["env"], {"LAB_KEY": SECRET})

    def test_bad_configs(self):
        bad = [
            ({"name": "Lab", "type": "nope"}, "unknown type"),
            ({"name": "Lab", "type": "Bad Type"}, "type must be"),
            ({"name": "a:b", "type": "t-static"}, "name must be"),
            ({"name": "", "type": "t-static"}, "name must be"),
            ({"name": "Lab", "type": "t-static", "every": 0}, "every"),
            ({"name": "Lab", "type": "t-static", "timeout": "5"}, "timeout"),
            ({"name": "Lab", "type": "t-static", "insecure": "yes"}, "insecure"),
            ({"name": "Lab", "type": "t-static", "ca_file": "/nonexistent/ca.pem"}, "ca_file"),
            ({"name": "Lab", "type": "t-static", "url": "ftp://192.0.2.1"}, "url"),
            ({"name": "Lab", "type": "t-static", "url": "http://user:pw@192.0.2.1"}, "user or password"),
            ({"name": "Lab", "type": "t-static", "url": "http://192.0.2.1/api?apikey=abc"}, "query"),
            ({"name": "Lab", "type": "t-static", "key": "abc"}, "looks like a secret"),
            ({"name": "Lab", "type": "t-static", "api_key": "abc"}, "looks like a secret"),
            ({"name": "Lab", "type": "t-static", "password": "abc"}, "looks like a secret"),
            ({"name": "Lab", "type": "t-static", "auth": {"token": "abc"}}, "looks like a secret"),
            ({"name": "Lab", "type": "t-static", "key_env": "not a name"}, "env variable"),
            ({"name": "Lab", "type": "t-static", "key_env": "HOMELAB_TOKENS"}, "server's own secret"),
            ({"name": "Lab", "type": "example", "key_env": "LAB_KEY"}, "url is required"),
            ("not an object", "must be an object"),
        ]
        for raw, words in bad:
            with self.subTest(raw=raw):
                with self.assertRaises(rs.ConfigError) as ctx:
                    rs.Config({"tokens": [TOKEN], "sources": [raw]}, env=ENV)
                self.assertIn(words, str(ctx.exception))
        with self.assertRaises(rs.ConfigError):
            rs.Config({"tokens": [TOKEN], "sources": "Lab"}, env=ENV)
        with self.assertRaisesRegex(rs.ConfigError, "duplicate"):
            rs.Config({"tokens": [TOKEN], "sources": [{"name": "Lab", "type": "t-static"},
                                                      {"name": "lab", "type": "t-static"}]}, env=ENV)

    def test_comments_and_env_names_are_fine(self):
        s = sources.parse([{"name": "Lab", "type": "t-static", "_note": "key: in env", "key_env": "LAB_KEY",
                            "password_env": "LAB_PW", "token_id": "monitor@pve!ro"}], ENV)[0]
        self.assertNotIn("_note", s["cfg"])
        self.assertEqual(s["env"], {"LAB_KEY": SECRET, "LAB_PW": ""})

    def test_check_hook_error_names_the_source(self):
        def check(cfg):
            raise ValueError("slug is required")
        sources.register("t-checked", fake_type(_static, check))
        with self.assertRaisesRegex(rs.ConfigError, r"sources\[Kuma\]: slug is required"):
            rs.Config({"tokens": [TOKEN], "sources": [{"name": "Kuma", "type": "t-checked"}]}, env={})

    def test_known_types_list_the_files(self):
        self.assertIn("example", sources.known_types())

    def test_source_keys_stay_out_of_commands(self):
        rs.Config({"tokens": [TOKEN], "sources": [{"name": "Lab", "type": "t-static", "key_env": "LAB_KEY"}]},
                  env=ENV)
        with mock.patch.dict(os.environ, {"LAB_KEY": SECRET, "PLAIN": "1"}):
            env = rs.child_env()
        self.assertNotIn("LAB_KEY", env)
        self.assertEqual(env.get("PLAIN"), "1")


class FetchRules(unittest.TestCase):
    """fetch: timeout, 8 MB, no redirects, no cookies, no proxy, keys only from the named env variable."""

    def routes(self, routes):
        return FakeUpstream({"routes": routes}).start()

    def fetch(self, up, **cfg):
        s = spec(kind="t-static", url=up.url, key_env="LAB_KEY", **cfg)
        return sources.Fetch(s["cfg"], s["env"])

    def test_json_and_relative_paths_and_headers(self):
        with FakeUpstream(recording("example", "normal")) as up:
            f = self.fetch(up)
            data = f.json("api/status", headers={"X-Api-Key": f.secret()})
            self.assertEqual(data["version"], "1.0")
            req = up.requests[-1]
            self.assertEqual(req["path"], "/api/status")
            self.assertEqual(req["headers"].get("X-Api-Key"), SECRET)

    def test_status_outside_ok_is_the_code(self):
        up = self.routes({"GET /x": {"status": 401, "json": {"error": "no"}}})
        try:
            f = self.fetch(up)
            with self.assertRaisesRegex(sources.SourceError, "^401$"):
                f("/x")
            self.assertEqual(f("/x", ok=None).status, 401)
        finally:
            up.stop()

    def test_no_redirects(self):
        up = self.routes({"GET /a": {"status": 302, "headers": {"Location": "/b"}},
                          "GET /b": {"json": {"followed": True}}})
        try:
            with self.assertRaisesRegex(sources.SourceError, "^302$"):
                self.fetch(up)("/a")
            self.assertEqual([r["path"] for r in up.requests], ["/a"])
        finally:
            up.stop()

    def test_no_cookies(self):
        up = self.routes({"GET /login": {"json": {}, "headers": {"Set-Cookie": "sid=abc123; Path=/"}},
                          "GET /next": {"json": {}}})
        try:
            f = self.fetch(up)
            f("/login")
            f("/next")
            self.assertNotIn("Cookie", up.requests[-1]["headers"])
        finally:
            up.stop()

    def test_size_limit(self):
        up = self.routes({"GET /big": {"json": {"a": 1}, "pad": 9 * 1024 * 1024},
                          "GET /fits": {"json": {"a": 1}, "pad": 1024 * 1024}})
        try:
            f = self.fetch(up)
            with self.assertRaisesRegex(sources.SourceError, "larger than 8 MB"):
                f("/big")
            self.assertEqual(f.json("/fits"), {"a": 1})
        finally:
            up.stop()

    def test_timeout(self):
        up = self.routes({"GET /slow": {"json": {}, "delay": 2}})
        try:
            t0 = time.monotonic()
            with self.assertRaisesRegex(sources.SourceError, "^timeout$"):
                self.fetch(up, timeout=0.3)("/slow")
            self.assertLess(time.monotonic() - t0, 1.5)
        finally:
            up.stop()

    def test_deadline_of_the_run(self):
        s = spec(kind="t-static", url="http://127.0.0.1:9")
        f = sources.Fetch(s["cfg"], s["env"], deadline=time.monotonic() - 1)
        with self.assertRaisesRegex(sources.SourceError, "^timeout$"):
            f("/x")

    def test_connection_refused_and_not_json(self):
        up = self.routes({"GET /text": {"body": "<html>"}})
        try:
            with self.assertRaisesRegex(sources.SourceError, "^answer is not JSON$"):
                self.fetch(up).json("/text")
        finally:
            up.stop()
        s = spec(kind="t-static", url=up.url)
        with self.assertRaisesRegex(sources.SourceError, "refused"):
            sources.Fetch(s["cfg"], s["env"])("/x")

    def test_proxy_from_the_environment_is_ignored(self):
        with FakeUpstream(recording("example", "normal")) as up, \
                mock.patch.dict(os.environ, {"http_proxy": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9",
                                             "no_proxy": "", "NO_PROXY": ""}):
            self.assertEqual(self.fetch(up).json("/api/status")["version"], "1.0")

    def test_secret_only_from_the_named_variable(self):
        s = spec(kind="t-static", url="http://192.0.2.1", key_env="LAB_KEY", env={"LAB_KEY": ""})
        with self.assertRaisesRegex(sources.SourceError, "^LAB_KEY is not set$"):
            sources.Fetch(s["cfg"], s["env"]).secret()
        s = spec(kind="t-static", url="http://192.0.2.1")
        with self.assertRaisesRegex(sources.SourceError, "key_env is missing"):
            sources.Fetch(s["cfg"], s["env"]).secret()
        with mock.patch.dict(os.environ, {"LAB_KEY": SECRET}):   # the process env is never read directly
            s = spec(kind="t-static", url="http://192.0.2.1", key_env="LAB_KEY", env={})
            with self.assertRaises(sources.SourceError):
                sources.Fetch(s["cfg"], s["env"]).secret()

    def test_insecure_and_ca_file(self):
        ctx = sources.ssl_context({"insecure": True})
        self.assertEqual(ctx.verify_mode, sources.ssl.CERT_NONE)
        self.assertFalse(ctx.check_hostname)
        self.assertEqual(sources.ssl_context({}).verify_mode, sources.ssl.CERT_REQUIRED)
        runner = sources.Runner([spec(kind="t-static", url="https://192.0.2.1", insecure=True)])
        self.assertEqual(runner.status()[0].get("insecure"), True)


class MergeRules(unittest.TestCase):
    """What a source returns is cleaned before the app sees it."""

    def norm(self, result, name="Kuma", secrets=(), checked="2026-11-07T10:00:00+01:00"):
        return sources.normalize(name, result, secrets, checked)

    def test_ids_are_prefixed_and_hosts_named(self):
        out = self.norm({"problems": [{"id": "m3", "text": "Jellyfin: down", "host": "pve1"},
                                      {"id": "m4", "text": "Other", "host": "elsewhere"}],
                         "hosts": [{"id": "pve1"}], "cards": [{"id": "monitors", "title": "Kuma"}]})
        self.assertEqual([p["id"] for p in out["problems"]], ["Kuma:m3", "Kuma:m4"])
        self.assertEqual(out["problems"][0]["host"], "Kuma:pve1")
        self.assertNotIn("host", out["problems"][1])
        self.assertEqual(out["hosts"], [{"id": "Kuma:pve1", "name": "pve1"}])
        self.assertEqual(out["cards"][0]["id"], "Kuma:monitors")
        self.assertEqual(out["cards"][0]["updated"], "2026-11-07T10:00:00+01:00")

    def test_problem_defaults(self):
        out = self.norm({"problems": ["plain text", {"text": "odd", "severity": "fatal"}, {"text": ""}, {"id": "x"},
                                      {"text": "plain text"}, 5]})
        self.assertEqual([(p["severity"], p["text"]) for p in out["problems"]],
                         [("problem", "plain text"), ("warning", "odd")])
        self.assertTrue(out["problems"][0]["id"].startswith("Kuma:"))

    def test_reserved_card_ids(self):
        out = self.norm({"cards": [{"id": "today"}, {"id": "departures"}, {"id": "queue"}]})
        self.assertEqual([c["id"] for c in out["cards"]], ["Kuma:queue"])

    def test_no_actions(self):
        out = self.norm({"cards": [{"id": "q", "action": {"action": "restart"},
                                    "items": [{"title": "a", "action": {"action": "stop"}}, "junk"]}],
                         "hosts": [{"id": "h", "container_list": [{"name": "web", "restartable": True}, 3]}]})
        self.assertNotIn("action", out["cards"][0])
        self.assertEqual(out["cards"][0]["items"], [{"title": "a"}])
        self.assertEqual(out["hosts"][0]["container_list"], [{"name": "web"}])

    def test_history_at_most_288(self):
        out = self.norm({"hosts": [{"id": "h", "history": {"step": 300, "load": list(range(400))}}]})
        self.assertEqual(out["hosts"][0]["history"]["load"], list(range(112, 400)))

    def test_limits_and_duplicates(self):
        out = self.norm({"problems": [{"id": "p%d" % i, "text": "t"} for i in range(150)] + [{"id": "p0", "text": "t"}],
                         "hosts": [{"id": "h"}, {"id": "h", "name": "again"}] + [{"id": "h%d" % i} for i in range(200)],
                         "cards": [{"id": "c%d" % i} for i in range(80)],
                         "services": [{"name": "s%d" % i, "url": "http://192.0.2.1"} for i in range(150)]})
        self.assertEqual([len(out[k]) for k in ("problems", "hosts", "cards", "services")], [100, 100, 50, 100])
        self.assertEqual(out["hosts"][0], {"id": "Kuma:h", "name": "h"})

    def test_services(self):
        out = self.norm({"services": [{"name": "Web", "url": "http://192.0.2.1", "extra": 1},
                                      {"name": "No url"}, {"name": "G", "url": "http://192.0.2.2", "group": "Mine"}]})
        self.assertEqual(out["services"], [{"name": "Web", "url": "http://192.0.2.1", "group": "Kuma"},
                                           {"name": "G", "url": "http://192.0.2.2", "group": "Mine"}])

    def test_secrets_scrubbed_everywhere(self):
        out = self.norm(_leak({}, types.SimpleNamespace(secret=lambda: SECRET)), secrets=[SECRET])
        text = json.dumps(out)
        self.assertNotIn(SECRET, text)
        self.assertNotIn("api_key", text)
        self.assertNotIn('"token"', text)
        self.assertIn("x***y", text)

    def test_bad_results(self):
        for bad, words in ((["a list"], "not a dict"), ({"hosts": [{"id": "h", "t": object()}]}, "not JSON"),
                           ({"hosts": [{"id": "h", "load": float("nan")}]}, "not JSON")):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(sources.SourceError, words):
                    self.norm(bad)

    def test_unknown_keys_and_missing_keys(self):
        self.assertEqual(self.norm({"status": "ok", "other": 1}),
                         {"problems": [], "hosts": [], "cards": [], "services": []})
        self.assertEqual(self.norm({"hosts": "nope", "cards": None})["hosts"], [])


class RunnerRules(unittest.TestCase):
    """A failing source is exactly one warning; the others still answer; each runs on its own `every`."""

    def test_crash_is_one_warning_without_the_key(self):
        logs = []
        s = spec("Kuma", "t-crash", key_env="LAB_KEY")
        runner = sources.Runner([s], logf=logs.append)
        runner.run_one(s)
        out = runner.merged()
        self.assertEqual(len(out["problems"]), 1)
        p = out["problems"][0]
        self.assertEqual((p["id"], p["severity"]), ("Kuma:source", "warning"))
        self.assertEqual(p["text"], "Kuma: RuntimeError: boom with *** inside")
        self.assertTrue(p["since"])
        self.assertEqual(out["hosts"] + out["cards"] + out["services"], [])
        self.assertNotIn(SECRET, "\n".join(logs))
        self.assertTrue(any("crashed" in line for line in logs))

    def test_upstream_errors_are_short(self):
        cases = [({"GET /api/status": {"status": 401, "json": {"error": "bad key " + SECRET}}}, "Lab: 401"),
                 ({"GET /api/status": {"body": "<html>"}}, "Lab: answer is not JSON")]
        for routes, text in cases:
            with self.subTest(text=text), FakeUpstream({"routes": routes}) as up:
                runner = run(spec(url=up.url, key_env="LAB_KEY"))
                self.assertEqual([p["text"] for p in runner.merged()["problems"]], [text])
        runner = run(spec(url="http://127.0.0.1:9", key_env="LAB_KEY"))
        self.assertEqual([p["text"] for p in runner.merged()["problems"]], ["Lab: connection refused"])
        runner = run(spec(url="http://127.0.0.1:9", key_env="LAB_KEY", env={}))
        self.assertEqual([p["text"] for p in runner.merged()["problems"]], ["Lab: LAB_KEY is not set"])

    def test_one_failing_source_leaves_the_others(self):
        with FakeUpstream(recording("example", "normal")) as up:
            good = spec("Lab", url=up.url, key_env="LAB_KEY")
            bad = spec("Kuma", "t-crash", key_env="LAB_KEY")
            runner = sources.Runner([bad, good])
            runner.run_one(bad)
            runner.run_one(good)
        out = runner.merged()
        self.assertEqual([p["id"] for p in out["problems"]], ["Kuma:source", "Lab:monitor-3"])
        self.assertEqual([h["id"] for h in out["hosts"]], ["Lab:pve1", "Lab:backup"])

    def test_hang_is_one_warning_and_does_not_block(self):
        hang = spec("Slow", "t-hang", every=1, timeout=0.2, sleep=30)
        _release.clear()
        self.addCleanup(_release.set)
        quick = spec("Quick", "t-static", every=1, result={"hosts": [{"id": "h"}]})
        runner = sources.Runner([hang, quick], tick=0.05)
        runner.start()
        try:
            wait_for(lambda: runner.states["Quick"].runs >= 1, timeout=5)
            self.assertEqual(runner.merged()["problems"], [])   # still within its time
            out = wait_for(lambda: runner.merged()["problems"] and runner.merged(), timeout=5)
            self.assertEqual([p["text"] for p in out["problems"]], ["Slow: timeout"])
            self.assertEqual([h["id"] for h in out["hosts"]], ["Quick:h"])
            self.assertEqual(runner.status()[0]["error"], "timeout")
            runs = runner.states["Quick"].runs
            wait_for(lambda: runner.states["Quick"].runs > runs, timeout=5)   # the hang blocks nobody
            self.assertEqual(runner.states["Slow"].runs, 0)
        finally:
            runner.stop()

    def test_each_source_on_its_own_every(self):
        fast = spec("Fast", "t-static", every=1, result={})
        slow = spec("Rare", "t-static", every=3600, result={})
        runner = sources.Runner([fast, slow], tick=0.05)
        runner.start()
        try:
            wait_for(lambda: runner.states["Fast"].runs >= 3, timeout=8)
            self.assertEqual(runner.states["Rare"].runs, 1)
        finally:
            runner.stop()

    def test_since_stays_while_a_problem_stays(self):
        s = spec("Kuma", "t-count")
        runner = sources.Runner([s])
        runner.run_one(s)
        first = runner.merged()["problems"][0]["since"]
        with mock.patch.object(sources, "now_iso", return_value="2099-01-01T00:00:00+00:00"):
            runner.run_one(s)
        self.assertEqual(runner.merged()["problems"][0]["since"], first)

    def test_status_rows(self):
        s = spec("Kuma", "t-crash", key_env="LAB_KEY")
        runner = sources.Runner([s])
        self.assertEqual(runner.status(), [{"name": "Kuma", "type": "t-crash", "state": "never"}])
        runner.run_one(s)
        row = runner.status()[0]
        self.assertEqual((row["state"], row["error"]), ("failing", "RuntimeError: boom with *** inside"))

    def test_merged_is_a_copy(self):
        s = spec("Lab", "t-static", result={"hosts": [{"id": "h"}]})
        runner = run(s)
        runner.merged()["hosts"][0]["id"] = "changed"
        self.assertEqual(runner.merged()["hosts"][0]["id"], "Lab:h")


class ExampleSource(unittest.TestCase):
    """server/sources/example.py, the template, against its recordings."""

    def test_normal(self):
        with FakeUpstream(recording("example", "normal")) as up:
            runner = run(spec(url=up.url, key_env="LAB_KEY"))
            self.assertEqual(up.requests[0]["headers"].get("X-Api-Key"), SECRET)
        out = runner.merged()
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]],
                         [("Lab:monitor-3", "problem", "Jellyfin: down (timeout)")])
        self.assertEqual(out["hosts"], [
            {"id": "Lab:pve1", "name": "pve1", "kind": "server", "reachable": True, "load": 0.42},
            {"id": "Lab:backup", "name": "Backup box", "kind": "server", "reachable": False}])
        card = out["cards"][0]
        self.assertEqual((card["id"], card["place"], len(card["items"])), ("Lab:monitors", "lab", 3))
        self.assertEqual([s["name"] for s in out["services"]], ["Jellyfin", "Vaultwarden"])
        self.assertEqual({s["group"] for s in out["services"]}, {"Lab"})

    def test_odd_never_crashes(self):
        with FakeUpstream(recording("example", "odd")) as up:
            runner = run(spec(url=up.url, key_env="LAB_KEY"))
        self.assertIsNone(runner.states["Lab"].error)
        out = runner.merged()
        self.assertEqual([h["id"] for h in out["hosts"]], ["Lab:pve1", "Lab:7"])
        self.assertEqual(out["hosts"][0], {"id": "Lab:pve1", "name": "pve1", "kind": "server"})
        self.assertEqual(out["services"], [])
        self.assertEqual(len(out["problems"]), 2)


class SourceModuleRules(unittest.TestCase):
    """Every module in server/sources/ keeps the contract (docs/BRIDGE.md): collect(cfg, fetch), no env, no shell,
    no own HTTP, and a recording folder with a normal and an odd case."""

    FORBIDDEN_IMPORTS = ("os", "subprocess", "urllib", "http", "socket", "ssl", "requests", "shutil", "ctypes",
                         "reference_server")
    FORBIDDEN_NAMES = ("open", "eval", "exec", "__import__", "environ", "getenv", "reference_server")

    def forbidden(self, text):
        """What a module uses that it must not (read from its syntax tree, so docstrings and comments don't count)."""
        hits = []
        for node in ast.walk(ast.parse(text)):
            if isinstance(node, ast.Import):
                hits += [a.name for a in node.names if a.name.split(".")[0] in self.FORBIDDEN_IMPORTS]
            elif isinstance(node, ast.ImportFrom) and node.level == 0:
                if (node.module or "").split(".")[0] in self.FORBIDDEN_IMPORTS:
                    hits.append(node.module)
            elif isinstance(node, ast.Name) and node.id in self.FORBIDDEN_NAMES:
                hits.append(node.id)
            elif isinstance(node, ast.Attribute) and node.attr in self.FORBIDDEN_NAMES:
                hits.append(node.attr)
        return hits

    def test_the_check_itself(self):
        harmless = '"""Reads two requests via urllib and os.environ."""\nx = 1  # open( socket\n'
        self.assertEqual(self.forbidden(harmless), [])
        bad = "import os\nfrom urllib import request\nopen('f')\nimport sys\nsys.modules['os'].environ"
        self.assertEqual(sorted(self.forbidden(bad)), ["environ", "open", "os", "urllib"])

    def test_every_module(self):
        folder = os.path.join(HERE, "sources")
        mods = sorted(f[:-3] for f in os.listdir(folder) if f.endswith(".py") and not f.startswith("_"))
        self.assertIn("example", mods)
        for m in mods:
            with self.subTest(module=m):
                with open(os.path.join(folder, m + ".py"), encoding="utf-8") as fh:
                    text = fh.read()
                self.assertTrue(ast.get_docstring(ast.parse(text)), "a docstring: upstream, keys, tested version")
                self.assertEqual(self.forbidden(text), [], "use fetch and fetch.secret() only")
                kind = m.replace("_", "-")
                self.assertTrue(callable(sources.load_type(kind).collect))
                for case in ("normal", "odd"):
                    self.assertTrue(os.path.isfile(recording(kind, case)),
                                    "server/recordings/%s/%s.json" % (kind, case))


class BridgeEndToEnd(unittest.TestCase):
    """The reference server with sources: merged answers, the worst status, and the key in no reply."""

    def start(self, raw_sources, env=None):
        cfg = rs.Config({"name": "bridge", "tokens": [TOKEN], "interval": 60,
                         "this_host": {"id": "box", "disks": ["/"]},
                         "thresholds": {"temp_warning": 1000, "disk_warning": 1000, "disk_problem": 1001},
                         "sources": raw_sources}, env=ENV if env is None else env)
        app = rs.RealApp(cfg)
        app.sources.tick_seconds = 0.05
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and all(st.runs >= 1 for st in app.sources.states.values()))
        return httpd.server_address[1]

    def get_all(self, port):
        out = {}
        for path in ("/api/v1/info", "/api/v1/state", "/api/v1/services", "/api/v1/actions", "/api/v1/messages",
                     "/api/v1/nope"):
            code, resp, obj = call(port, "GET", path, headers=AUTH)
            out[path] = (code, json.dumps(obj) + json.dumps(dict(resp.getheaders())))
        return out

    def test_merged_answers(self):
        up = FakeUpstream(recording("example", "normal")).start()
        self.addCleanup(up.stop)
        port = self.start([{"name": "Lab", "type": "example", "url": up.url, "key_env": "LAB_KEY"},
                           {"name": "Kuma", "type": "t-crash", "key_env": "LAB_KEY"}])
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertEqual(info["features"], ["status", "hosts", "cards", "services"])
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertEqual(state["status"], "problem")
        self.assertEqual([p["id"] for p in state["problems"]], ["Lab:monitor-3", "Kuma:source"])
        self.assertEqual([h["id"] for h in state["hosts"]], ["box", "Lab:pve1", "Lab:backup"])
        self.assertEqual([c["id"] for c in state["cards"]], ["Lab:monitors"])
        _, _, services = call(port, "GET", "/api/v1/services", headers=AUTH)
        self.assertEqual([s["name"] for s in services["services"]], ["Jellyfin", "Vaultwarden"])

    def test_warning_only_source_makes_status_warning(self):
        port = self.start([{"name": "Kuma", "type": "t-crash", "key_env": "LAB_KEY"}])
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertEqual(state["status"], "warning")
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertEqual(info["features"], ["status", "hosts"])
        self.assertEqual(call(port, "GET", "/api/v1/services", headers=AUTH)[2], {"services": []})

    def test_the_key_is_in_no_reply(self):
        up = FakeUpstream({"routes": {"GET /api/status": {"status": 500, "body": "error for key " + SECRET}}}).start()
        self.addCleanup(up.stop)
        port = self.start([{"name": "Leak", "type": "t-leak", "key_env": "LAB_KEY"},
                           {"name": "Crash", "type": "t-crash", "key_env": "LAB_KEY"},
                           {"name": "Lab", "type": "example", "url": up.url, "key_env": "LAB_KEY"}])
        for path, (code, text) in self.get_all(port).items():
            with self.subTest(path=path):
                self.assertNotIn(SECRET, text)
                self.assertNotIn("LAB_KEY", text)
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        self.assertIn("Lab: 500", [p["text"] for p in state["problems"]])

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_passes_on_the_sample_config(self):
        with open(os.path.join(HERE, "examples", "sources-example.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        up = FakeUpstream(recording("example", "normal")).start()
        self.addCleanup(up.stop)
        raw["sources"][0]["url"] = up.url
        raw["listen"] = "127.0.0.1:0"
        tmp = tempfile.mkdtemp(prefix="bridge-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "config.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(raw, fh)
        cfg = rs.Config.load(path, env={"HOMELAB_TOKENS": TOKEN, "LAB_KEY": SECRET})
        app = rs.RealApp(cfg)
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and app.sources.states["Lab"].runs >= 1)
        script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
        res = subprocess.run(["bash", script, "--token", TOKEN, "http://127.0.0.1:%d" % httpd.server_address[1]],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertNotIn(SECRET, res.stdout + res.stderr)


class FakeUpstreamRules(unittest.TestCase):
    def test_routes_queries_and_404(self):
        with FakeUpstream({"routes": {"GET /a": {"json": {"any": True}}, "GET /a?page=2": {"json": {"page": 2}},
                                      "POST /b": {"status": 201, "body": "made"}}}) as up:
            def get(path, method="GET", data=None):
                req = urllib.request.Request(up.url + path, method=method, data=data)
                try:
                    with urllib.request.urlopen(req, timeout=5) as r:
                        return r.status, r.read()
                except urllib.error.HTTPError as exc:
                    with exc:
                        return exc.code, exc.read()
            self.assertEqual(get("/a?page=1"), (200, b'{"any": true}'))
            self.assertEqual(get("/a?page=2"), (200, b'{"page": 2}'))
            self.assertEqual(get("/b", "POST", b"{}"), (201, b"made"))
            self.assertEqual(get("/c")[0], 404)
            self.assertEqual(up.requests[2]["body"], "{}")

    def test_cli_needs_a_recording(self):
        with self.assertRaises(ValueError):
            FakeUpstream({"nothing": 1})


# Security review 2026-11-07: an env key with a line break made http.client raise "Invalid header value
# b'<key>\n'", and that text reached /info, /state and the log. Every type that sends its key in a header:
HEADER_TYPES = [("example", {}), ("json", {}), ("sonarr", {}), ("radarr", {}), ("qbittorrent", {}),
                ("proxmox", {"token_id": "monitor@pve!bridge"})]
LEAK_KEY = "Sup3rSecretLeakKey0123456789abcdef"


def leak_forms(key):
    """The forms the old scrub missed: escaped, %-encoded, in base64 (also inside Basic auth's user:password)."""
    raw = key.encode()
    return [repr(key)[1:-1], repr(raw)[2:-1], urllib.parse.quote(key, safe=""), key[:16],
            base64.b64encode(raw).decode()[:16], base64.b64encode(b"bridge:" + raw).decode()[12:28]]


class KeyLeakRules(unittest.TestCase):
    """A key never reaches /info, /state or the log, whatever form an error puts it in."""

    def test_trailing_line_break_is_stripped(self):
        for kind, extra in HEADER_TYPES:
            with self.subTest(kind=kind):
                s = sources.parse([dict({"name": "S", "type": kind, "url": "http://127.0.0.1:9", "key_env": "K"},
                                        **extra)], {"K": LEAK_KEY + "\r\n"})[0]
                self.assertEqual(s["env"], {"K": LEAK_KEY})
        with FakeUpstream(recording("example", "normal")) as up:
            runner = run(spec(url=up.url, key_env="K", env={"K": "  " + LEAK_KEY + "\n"}))
            self.assertIsNone(runner.states["Lab"].error)
            self.assertEqual({k.lower(): v for k, v in up.requests[0]["headers"].items()}["x-api-key"], LEAK_KEY)

    def test_control_character_inside_stops_the_start(self):
        for kind, extra in HEADER_TYPES:
            for bad in (LEAK_KEY[:10] + "\n" + LEAK_KEY[10:], LEAK_KEY + "\x00x", "x\r" + LEAK_KEY):
                with self.subTest(kind=kind, bad=bad[:3]):
                    with self.assertRaises(ValueError) as ctx:
                        sources.parse([dict({"name": "S", "type": kind, "url": "http://127.0.0.1:9",
                                             "key_env": "SONARR_KEY"}, **extra)], {"SONARR_KEY": bad})
                    msg = str(ctx.exception)
                    self.assertIn("SONARR_KEY", msg)
                    self.assertIn("control character", msg)
                    for form in leak_forms(LEAK_KEY):
                        self.assertNotIn(form, msg)

    def test_poc_without_parse_leaks_nothing(self):
        """The PoC's key, put past parse(): the error is a fixed text, and no form of the key is anywhere."""
        with FakeUpstream({"routes": {}}) as up:
            for kind, extra in HEADER_TYPES:
                with self.subTest(kind=kind):
                    s = sources.parse([dict({"name": "S", "type": kind, "url": up.url, "key_env": "K"}, **extra)],
                                      {"K": "placeholder"})[0]
                    s["env"] = {"K": LEAK_KEY + "\n"}
                    logs = []
                    runner = sources.Runner([s], logf=logs.append)
                    runner.run_one(s)
                    status = runner.status()[0]
                    self.assertEqual(status["error"], sources.BAD_REQUEST)
                    seen = json.dumps([status, runner.merged()]) + "\n".join(logs)
                    for form in leak_forms(LEAK_KEY):
                        self.assertNotIn(form, seen)

    def test_short_error_drops_the_text_of_value_errors(self):
        import http.client
        for exc in (ValueError("Invalid header value b'%s\\n'" % LEAK_KEY), http.client.InvalidURL(LEAK_KEY),
                    http.client.BadStatusLine(LEAK_KEY), UnicodeEncodeError("latin-1", LEAK_KEY, 0, 1, "x")):
            with self.subTest(exc=type(exc).__name__):
                self.assertEqual(sources.short_error(exc), type(exc).__name__)

    def test_scrub_and_clean_catch_every_form(self):
        key = "k3y/with+odd=chars\"'%0123456789"
        raw = key.encode()
        forms = [key, repr(key)[1:-1], repr(raw)[2:-1], json.dumps(key)[1:-1], urllib.parse.quote(key, safe=""),
                 urllib.parse.quote_plus(key), base64.b64encode(raw).decode(), base64.urlsafe_b64encode(raw).decode()]
        for user in ("", "u", "bridge", "admin:"):   # Basic auth: base64 of "user:password" at every alignment
            forms.append(base64.b64encode((user + ":").encode() + raw).decode())
        for form in forms:
            with self.subTest(form=form):
                text = "before %s after" % form
                self.assertNotIn(key[:12], sources.scrub(text, [key]))
                out = sources.scrub(text, [key])
                self.assertTrue(out.startswith("before ") and out.endswith(" after"), out)
                cleaned = sources._clean({"a": [text]}, [key])["a"][0]
                for f in forms[:6]:
                    self.assertNotIn(f, cleaned)
                self.assertNotIn(base64.b64encode(raw).decode()[4:20], cleaned)


class UpstreamTextRules(unittest.TestCase):
    """Texts from upstream: no URLs, no `key=value` secrets, capped; lists capped; links without users or keys."""

    def norm(self, result):
        logs = []
        return sources.normalize("Kuma", result, (), "2026-11-07T10:00:00+01:00", logs.append), logs

    def test_arr_health_with_apikey(self):
        health = [{"source": "IndexerSearchCheck", "type": "error",
                   "message": "Search failed: http://192.0.2.30:9696/api/v1/indexer?apikey=0a1b2c3d4e5f6a7b8c9d"},
                  {"source": "IndexerRssCheck", "type": "warning",
                   "message": "RSS sync failed (apikey=0a1b2c3d4e5f6a7b8c9d&t=search, token: 9f8e7d6c5b4a)"}]
        with open(recording("sonarr", "normal"), encoding="utf-8") as fh:
            routes = json.load(fh)["routes"]
        routes["GET /api/v3/health"] = {"json": health}
        with FakeUpstream({"routes": routes}) as up:
            s = sources.parse([{"name": "Sonarr", "type": "sonarr", "url": up.url, "key_env": "K"}],
                              {"K": "made-up-sonarr-key"})[0]
            runner = run(s)
        texts = [p["text"] for p in runner.merged()["problems"] if p["id"].startswith("Sonarr:health")]
        self.assertEqual(texts, ["Sonarr: Search failed: <url>",
                                 "Sonarr: RSS sync failed (apikey=***&t=search, token: ***)"])
        self.assertNotIn("0a1b2c3d4e5f", json.dumps(runner.merged()))

    def test_card_and_item_texts(self):
        out, _ = self.norm({"cards": [{"id": "c", "title": "see https://x.example/?token=abc", "subtitle": "a" * 500,
                                       "text": "t" * 1500,
                                       "items": [{"title": "password=hunter22", "value": "v" * 300,
                                                  "url": "https://nas.example/"}]}]})
        card = out["cards"][0]
        self.assertEqual(card["title"], "see <url>")
        self.assertEqual(len(card["subtitle"]), sources.MAX_TEXT)
        self.assertEqual(len(card["text"]), sources.MAX_LONG_TEXT)
        self.assertEqual(card["items"][0]["title"], "password=***")
        self.assertEqual(len(card["items"][0]["value"]), sources.MAX_TEXT)
        self.assertEqual(card["items"][0]["url"], "https://nas.example/")
        out, _ = self.norm({"problems": [{"text": "x" * 1000}]})
        self.assertEqual(len(out["problems"][0]["text"]), sources.MAX_TEXT)

    def test_items_and_containers_capped(self):
        out, _ = self.norm({"cards": [{"id": "c", "items": [{"title": str(i)} for i in range(5000)]}],
                            "hosts": [{"id": "h", "container_list": [{"name": "c%d" % i} for i in range(5000)]}]})
        self.assertEqual(len(out["cards"][0]["items"]), sources.MAX_ITEMS)
        self.assertEqual(len(out["hosts"][0]["container_list"]), sources.MAX_CONTAINERS)
        self.assertEqual((sources.MAX_ITEMS, sources.MAX_CONTAINERS), (200, 200))

    def test_links_with_a_user_or_key_are_dropped(self):
        bad = ["http://admin:pw@192.0.2.1/", "https://user@nas.example/", "http://192.0.2.1/?api_key=abc",
               "https://nas.example/x?token=abc&y=1"]
        out, logs = self.norm({"services": [{"name": "S%d" % i, "url": u} for i, u in enumerate(bad)] +
                                           [{"name": "Good", "url": "https://nas.example/?page=2"}],
                               "cards": [{"id": "c", "items": [{"title": "t", "url": u} for u in bad]}]})
        self.assertEqual([s["name"] for s in out["services"]], ["Good"])
        self.assertEqual(out["cards"][0]["items"], [{"title": "t"}] * len(bad))
        self.assertTrue(any("skipped a service" in line for line in logs))


class PlainHttpRules(unittest.TestCase):
    """A key over plain http:// to a host that is not loopback: a warning in the status row and the log."""

    def test_plain_http_rows(self):
        cases = [("http://192.0.2.10:8989", "K", True), ("http://nas.example:8989", "K", True),
                 ("https://192.0.2.10:8989", "K", False), ("http://127.0.0.1:8989", "K", False),
                 ("http://localhost:8989", "K", False), ("http://[::1]:8989", "K", False),
                 ("http://192.0.2.10:8989", None, False)]
        for url, key_env, warned in cases:
            with self.subTest(url=url, key_env=key_env):
                raw = {"name": "Lab", "type": "example" if key_env else "docker", "url": url}
                if key_env:
                    raw["key_env"] = key_env
                s = sources.parse([raw], {"K": "a-key-0123456789"})[0]
                logs = []
                row = sources.Runner([s], logf=logs.append).status()[0]
                self.assertEqual(row.get("plain_http"), True if warned else None)
                self.assertEqual(any("plain http://" in line for line in logs), warned)


class IdentityWithSources(unittest.TestCase):
    """Identity mode with sources needs allowed_logins; without sources an empty list stays as it was."""

    def config(self, **raw):
        return rs.Config(dict({"listen": "127.0.0.1:0", "trust_identity_header": "Tailscale-User-Login"}, **raw), {})

    def test_empty_logins_with_sources_refused(self):
        for logins in (None, [], ["  "]):
            with self.subTest(logins=logins):
                raw = {"sources": [{"name": "Lab", "type": "example", "url": "http://127.0.0.1:9", "key_env": "K"}]}
                if logins is not None:
                    raw["allowed_logins"] = logins
                with self.assertRaisesRegex(rs.ConfigError, "allowed_logins is empty"):
                    self.config(**raw)
        cfg = self.config(sources=[{"name": "Lab", "type": "example", "url": "http://127.0.0.1:9", "key_env": "K",
                                    "actions": None}], allowed_logins=["you@example.com"])
        self.assertEqual(len(cfg.sources), 1)

    def test_tokens_only_or_no_sources_unchanged(self):
        self.assertEqual(self.config().allowed_logins, [])
        self.assertEqual(self.config(allowed_logins=[]).sources, [])
        cfg = rs.Config({"listen": "127.0.0.1:0", "tokens": [TOKEN],
                         "sources": [{"name": "Lab", "type": "example", "url": "http://127.0.0.1:9", "key_env": "K"}]}, {})
        self.assertEqual(len(cfg.sources), 1)


if __name__ == "__main__":
    unittest.main()
