#!/usr/bin/env python3
"""Tests for the Gatus source (server/sources/gatus.py) against its recordings. Run from the repo root:

    python3 -m unittest -v server/test_source_gatus.py
"""

import base64
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sources  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402

PASSWORD = "gatus-made-up-password-42"


def recording(case):
    return os.path.join(HERE, "recordings", "gatus", case + ".json")


def run_gatus(case, env=None, **cfg):
    """Run the source once against a recording; returns (merged result, runner, the requests it made)."""
    with FakeUpstream(recording(case)) as up:
        spec = sources.parse([dict({"name": "Gatus", "type": "gatus", "url": up.url}, **cfg)], env or {})[0]
        runner = sources.Runner([spec])
        runner.run_one(spec)
        return runner.merged(), runner, list(up.requests)


def problems(out):
    return [(p["id"], p["severity"], p["text"]) for p in out["problems"]]


class GatusSource(unittest.TestCase):
    """Failing endpoints are problems; failing only on response time or expiry, or slower than slow_ms, warnings."""

    def test_normal(self):
        out, runner, reqs = run_gatus("normal")
        self.assertIsNone(runner.states["Gatus"].error)
        self.assertEqual([r["path"] for r in reqs], ["/api/v1/endpoints/statuses?pageSize=3"])
        self.assertEqual(problems(out), [
            ("Gatus:endpoint-core_jellyfin", "problem", "jellyfin: down ([STATUS] (502) == 200)"),
            ("Gatus:endpoint-core_website", "warning", "website: slow ([RESPONSE_TIME] (812) < 500)"),
            ("Gatus:endpoint-core_vault", "warning",
             "vault: certificate expires soon ([CERTIFICATE_EXPIRATION] (48h0m0s) > 72h)"),
            ("Gatus:endpoint-infra_nas", "problem", "nas: down ([CONNECTED] (false) == true)")])
        for p in out["problems"]:
            self.assertNotIn("dial tcp", p["text"], "errors hold URLs and addresses; not shown")
        self.assertEqual((out["hosts"], out["services"]), ([], []))
        card = out["cards"][0]
        self.assertEqual((card["id"], card["title"], card["subtitle"], card["place"], card["style"]),
                         ("Gatus:monitors", "Gatus", "4 of 7 up", "lab", "list"))
        self.assertEqual([(i["title"], i["value"], i["tint"], i.get("subtitle")) for i in card["items"]], [
            ("api", "up", "green", "core · 38 ms"), ("jellyfin", "down", "red", "core"),
            ("website", "slow", "orange", "core · 812 ms"), ("vault", "certificate", "orange", "core · 25 ms"),
            ("nas", "down", "red", "infra"), ("backup-job", "up", "green", "infra"),
            ("printer", "no data", "gray", "infra")])

    def test_no_auth_header_without_user(self):
        _, _, reqs = run_gatus("normal")
        self.assertNotIn("authorization", {k.lower() for k in reqs[0]["headers"]})
        self.assertEqual(reqs[0]["method"], "GET")

    def test_basic_auth_from_the_env(self):
        _, runner, reqs = run_gatus("normal", env={"GATUS_PASSWORD": PASSWORD}, user="bridge",
                                    password_env="GATUS_PASSWORD")
        self.assertIsNone(runner.states["Gatus"].error)
        expected = "Basic " + base64.b64encode(("bridge:" + PASSWORD).encode()).decode()
        self.assertEqual(reqs[0]["headers"].get("Authorization"), expected)

    def test_401_is_one_warning(self):
        out, _, _ = run_gatus("auth-failed", env={"GATUS_PASSWORD": PASSWORD}, user="bridge",
                              password_env="GATUS_PASSWORD")
        self.assertEqual(problems(out), [("Gatus:source", "warning", "Gatus: 401")])
        self.assertEqual(out["cards"], [])

    def test_missing_password_is_one_warning(self):
        out, _, reqs = run_gatus("normal", user="bridge", password_env="GATUS_PASSWORD")
        self.assertEqual(problems(out), [("Gatus:source", "warning", "Gatus: GATUS_PASSWORD is not set")])
        self.assertEqual(reqs, [])

    def test_slow_ms(self):
        out, _, _ = run_gatus("normal", slow_ms=30)
        self.assertIn(("Gatus:endpoint-core_api", "warning", "api: slow (38 ms)"), problems(out))
        self.assertEqual(out["cards"][0]["items"][0]["value"], "slow")
        self.assertEqual(out["cards"][0]["subtitle"], "4 of 7 up")
        self.assertNotIn("Gatus:endpoint-infra_backup-job", [p["id"] for p in out["problems"]],
                         "external endpoints have no duration")

    def test_odd_never_crashes(self):
        out, runner, _ = run_gatus("odd", slow_ms=1)
        self.assertIsNone(runner.states["Gatus"].error)
        self.assertEqual(problems(out), [
            ("Gatus:endpoint-x_dns", "problem", "dns: down (7)"),
            ("Gatus:endpoint-_cert-only", "problem", "cert-only: down ([CERTIFICATE_EXPIRATION] (0s) > 72h)")])
        card = out["cards"][0]
        self.assertEqual(card["subtitle"], "1 of 4 up")
        self.assertEqual([(i["title"], i["value"]) for i in card["items"]],
                         [("router", "up"), ("12", "no data"), ("dns", "down"), ("cert-only", "down")])

    def test_not_a_list_is_empty(self):
        with FakeUpstream({"routes": {"GET /api/v1/endpoints/statuses": {"json": {"error": "nope"}}}}) as up:
            spec = sources.parse([{"name": "Gatus", "type": "gatus", "url": up.url}], {})[0]
            runner = sources.Runner([spec])
            runner.run_one(spec)
        self.assertEqual(runner.merged(), {"problems": [], "hosts": [], "cards": [], "services": []})

    def test_config_checks(self):
        bad = [({}, "url is required"),
               ({"url": "http://192.0.2.10:8080", "slow_ms": -1}, "slow_ms"),
               ({"url": "http://192.0.2.10:8080", "user": "bridge"}, "go together"),
               ({"url": "http://192.0.2.10:8080", "password_env": "GATUS_PASSWORD"}, "go together"),
               ({"url": "http://192.0.2.10:8080", "user": "a:b", "password_env": "GATUS_PASSWORD"}, "without ':'"),
               ({"url": "http://192.0.2.10:8080", "password": "plain"}, "looks like a secret")]
        for raw, words in bad:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, words):
                    sources.parse([dict({"name": "Gatus", "type": "gatus"}, **raw)], {})


if __name__ == "__main__":
    unittest.main()
