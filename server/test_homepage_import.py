#!/usr/bin/env python3
"""Tests for the import from Homepage (server/sources/_homepage.py, the `homepage` config key). Run from the repo root:

    python3 -m unittest -v server/test_homepage_import.py

The YAML tests need PyYAML and are skipped without it (only the Docker image has it); the "PyYAML missing" tests run
everywhere. The made-up services.yaml files: server/examples/homepage-services.yaml (normal) and ODD below.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reference_server as rs  # noqa: E402
from sources import _homepage as homepage  # noqa: E402
from fake_upstream import FakeUpstream  # noqa: E402
from test_reference_server import AUTH, TOKEN, call, start_app, stop_app, wait_for  # noqa: E402

rs.log = lambda msg: None

try:
    import yaml  # noqa: F401
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False
needs_yaml = unittest.skipUnless(HAVE_YAML, "PyYAML is not installed (only the Homelab Bridge image has it)")

NORMAL = os.path.join(HERE, "examples", "homepage-services.yaml")
GATUS_PASSWORD = "gatus-made-up-password-42"
PVE_SECRET = "pve-made-up-secret-0000-1111"
LITERAL = "literal-made-up-key-0123456789"   # a key written in services.yaml: must never come out anywhere
FILE_KEY = "file-made-up-password-77"

ODD = """
- Empty group:
- 2024:
    - 42:
        href: http://192.0.2.42
- yes:
    - Bool named: {href: http://192.0.2.43}
- Odd:
    - just a string
    - {Two: {href: http://192.0.2.1}, Keys: {href: http://192.0.2.2}}
    - No href:
        description: only a widget
        widget: {type: gatus, url: "http://192.0.2.5:8080"}
    - FTP:
        href: ftp://192.0.2.6/
    - Key in query:
        href: http://192.0.2.7/?apikey=%(literal)s
    - User in href:
        href: http://admin:%(literal)s@192.0.2.8/
    - Secret placeholder:
        href: http://192.0.2.9/?x={{HOMEPAGE_VAR_SOME_TOKEN}}
    - Unset host:
        href: http://{{HOMEPAGE_VAR_NOT_SET}}/
    - Not a dict: 17
    - Widget junk:
        href: http://192.0.2.10
        icon: https://cdn.example.org/icons/png/plex-light.png
        widget: "gatus"
        widgets: [7, {url: http://192.0.2.10}, {type: sonarr, url: http://192.0.2.11, key: %(literal)s}]
    - "Kuma \U0001F7E2 (main)":
        href: http://192.0.2.12:3001
        widget: {type: uptimekuma, url: http://192.0.2.12:3001, slug: home}
    - Kuma (main):
        widgets:
          - {type: uptimekuma, url: http://192.0.2.13:3001, slug: home}
          - {type: uptimekuma, url: http://192.0.2.14:3001}
          - {type: uptimekuma, url: "http://{{HOMEPAGE_VAR_NOT_SET}}:3001", slug: home}
    - Gatus half auth:
        widget: {type: gatus, url: http://192.0.2.15:8080, username: bridge}
    - Gatus file key:
        widget: {type: gatus, url: http://192.0.2.16:8080, username: bridge, password: {{HOMEPAGE_FILE_GATUS_PW}}}
    - Deep:
        - Deeper:
            - Deepest:
                - Bottom: {href: http://192.0.2.17, icon: mdi-home-assistant}
- Skipped group:
    - Hidden: {href: http://192.0.2.18}
- Top service: {href: http://192.0.2.19}
- [not, a, group]
""" % {"literal": LITERAL}


def write(tmp, name, text):
    path = os.path.join(tmp, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def services_of(res):
    return [(s["name"], s["url"], s.get("group"), s.get("icon")) for s in res.services]


class TmpFiles:
    """A temp folder and the log lines of one test (mixed into the test classes below)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="homepage-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.logs = []

    def load(self, text_or_path, env=None, **opts):
        path = text_or_path if os.path.isfile(text_or_path) else write(self.tmp, "services.yaml", text_or_path)
        return homepage.load(dict({"file": path}, **opts), env or {}, logf=self.logs.append)


@needs_yaml
class HomepageNormal(TmpFiles, unittest.TestCase):
    """server/examples/homepage-services.yaml: every service a launcher entry, Kuma and Gatus widgets sources."""

    ENV = {"HOMEPAGE_VAR_KUMA_HOST": "192.0.2.10:3001", "HOMEPAGE_VAR_GATUS_HOST": "192.0.2.10:8080",
           "HOMEPAGE_VAR_GATUS_PASSWORD": GATUS_PASSWORD, "HOMEPAGE_VAR_PVE_URL": "https://192.0.2.30:8006",
           "HOMEPAGE_VAR_PVE_SECRET": PVE_SECRET}

    def test_launcher(self):
        res = self.load(NORMAL, self.ENV)
        self.assertEqual(services_of(res), [
            ("Uptime Kuma", "http://192.0.2.10:3001", "Monitoring", "waveform.path.ecg"),
            ("Gatus", "http://192.0.2.10:8080", "Monitoring", "waveform.path.ecg"),
            ("Jellyfin", "https://nas.tail1234.ts.net:8920", "Media", "play.rectangle"),
            ("Sonarr", "http://192.0.2.20:8989", "Media", "tv"),
            ("qBittorrent", "http://192.0.2.20:8081", "Downloads", "arrow.down.circle"),
            ("Proxmox", "https://192.0.2.30:8006", "Servers", "server.rack"),
            ("Pi-hole", "http://192.0.2.2/admin", "Network", "shield"),
            ("Router", "http://192.0.2.1", "Network", "network")])
        self.assertEqual(res.services[0]["description"], "Status of everything")
        self.assertNotIn("description", res.services[1])

    def test_sources(self):
        res = self.load(NORMAL, self.ENV)
        self.assertEqual(res.sources, [
            {"name": "Uptime Kuma", "every": 60, "type": "uptime-kuma", "url": "http://192.0.2.10:3001",
             "slug": "home", "services": False},
            {"name": "Gatus", "every": 60, "type": "gatus", "url": "http://192.0.2.10:8080", "user": "bridge",
             "password_env": "HOMEPAGE_VAR_GATUS_PASSWORD"},
            {"name": "Proxmox", "every": 60, "type": "proxmox", "url": "https://192.0.2.30:8006",
             "token_id": "monitor@pve!homepage", "key_env": "HOMEPAGE_VAR_PVE_SECRET"}])
        self.assertEqual(res.env, {})

    def test_log_lists_what_is_not_supported(self):
        self.load(NORMAL, self.ENV)
        self.assertEqual(self.logs, [
            "homepage: 8 launcher entries and 3 sources from homepage-services.yaml",
            "homepage: Monitoring / Uptime Kuma: widget uptimekuma is the source 'Uptime Kuma' (uptime-kuma)",
            "homepage: Monitoring / Gatus: widget gatus is the source 'Gatus' (gatus)",
            "homepage: Media / Jellyfin: widget jellyfin is not yet supported by the Homelab Bridge",
            "homepage: Media / Sonarr: widget sonarr is not yet supported by the Homelab Bridge",
            "homepage: Media / Downloads / qBittorrent: widget qbittorrent is not yet supported by the Homelab Bridge",
            "homepage: Servers / Proxmox: widget proxmox is the source 'Proxmox' (proxmox)",
            "homepage: Network / Pi-hole: widget pihole is not yet supported by the Homelab Bridge"])

    def test_options(self):
        res = self.load(NORMAL, self.ENV, sources=False, skip=["media", "ROUTER"], every=300)
        self.assertEqual([s["name"] for s in res.services], ["Uptime Kuma", "Gatus", "Proxmox", "Pi-hole"])
        self.assertEqual(res.sources, [])
        res = self.load(NORMAL, self.ENV, every=300)
        self.assertEqual({s["every"] for s in res.sources}, {300})

    def test_extra_keys_for_a_source(self):
        res = self.load(NORMAL, self.ENV, extra={"proxmox": {"ca_file": "/certs/pve.pem", "_note": "x"},
                                                 "Nothing here": {"insecure": True}})
        self.assertEqual(res.sources[2]["ca_file"], "/certs/pve.pem")
        self.assertNotIn("_note", res.sources[2])
        self.assertIn("homepage: extra: no imported source for the service 'nothing here'", self.logs)

    def test_extra_is_checked_like_any_source(self):
        yml = write(self.tmp, "services.yaml", "- S:\n    - Gatus:\n        widget: {type: gatus, url: "
                    "http://192.0.2.5:8080}\n")
        with self.assertRaisesRegex(rs.ConfigError, "looks like a secret") as ctx:
            rs.Config({"tokens": [TOKEN], "homepage": {"file": yml, "extra": {"Gatus": {"password": LITERAL}}}},
                      env={})
        self.assertNotIn(LITERAL, str(ctx.exception))
        cfg = rs.Config({"tokens": [TOKEN], "homepage": {"file": yml, "extra": {"Gatus": {"slow_ms": -1}}}}, env={})
        self.assertEqual(cfg.sources, [], "a bad extra key skips that widget, with a note")

    def test_bad_options(self):
        for raw, words in [("services.yaml", "must be an object"), ({}, "homepage.file"),
                           ({"file": NORMAL, "sources": "yes"}, "homepage.sources"),
                           ({"file": NORMAL, "every": 0}, "homepage.every"),
                           ({"file": NORMAL, "skip": "Media"}, "homepage.skip"),
                           ({"file": NORMAL, "widgets": True}, "not a known key"),
                           ({"file": NORMAL, "extra": {"Proxmox": True}}, "homepage.extra must map"),
                           ({"file": NORMAL, "extra": {"Proxmox": {"type": "json"}}}, "can't be changed"),
                           ({"file": os.path.join(self.tmp, "missing.yaml")}, "cannot read")]:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(homepage.ImportFailed, words):
                    homepage.load(raw, {})

    def test_names_avoid_the_configs_own_sources(self):
        opts = homepage.options({"file": NORMAL})
        res = homepage.convert(homepage.read_yaml(NORMAL), self.ENV, opts, taken_names=["gatus"])
        self.assertEqual([s["name"] for s in res.sources], ["Uptime Kuma", "Gatus 2", "Proxmox"])

    def test_own_services_are_not_repeated(self):
        opts = homepage.options({"file": NORMAL})
        own = [{"name": "Router", "url": "http://192.0.2.1"}]
        res = homepage.convert(homepage.read_yaml(NORMAL), self.ENV, opts, own_services=own)
        self.assertNotIn("Router", [s["name"] for s in res.services])

    def test_icons(self):
        for icon, symbol in [("sonarr.png", "tv"), ("mdi-sonarr", "tv"), ("si-jellyfin", "play.rectangle"),
                             ("sh-home-assistant.svg", "house"), ("https://cdn.example.org/x/proxmox-light.webp",
                                                                   "server.rack"),
                             ("/icons/uptime-kuma.png", "waveform.path.ecg"), ("mdi-flask-outline", None),
                             ("", None), (7, None), (None, None)]:
            with self.subTest(icon=icon):
                self.assertEqual(homepage.icon_for(icon), symbol)


@needs_yaml
class HomepageOdd(TmpFiles, unittest.TestCase):
    """Odd entries are skipped with a note, never a crash; nothing that looks like a key goes into the launcher."""

    def run_odd(self):
        path = write(self.tmp, "gatus-pw", FILE_KEY + "\n")
        return self.load(ODD, {"HOMEPAGE_FILE_GATUS_PW": path}, skip=["Skipped group"])

    def test_launcher(self):
        res = self.run_odd()
        self.assertEqual(services_of(res), [
            ("42", "http://192.0.2.42", "2024", None),
            ("Widget junk", "http://192.0.2.10", "Odd", "play.rectangle"),
            ("Kuma \U0001F7E2 (main)", "http://192.0.2.12:3001", "Odd", "waveform.path.ecg"),
            ("Bottom", "http://192.0.2.17", "Deepest", "house"),
            ("Top service", "http://192.0.2.19", None, None)])

    def test_sources(self):
        res = self.run_odd()
        self.assertEqual([(s["name"], s["type"], s["url"]) for s in res.sources], [
            ("No href", "gatus", "http://192.0.2.5:8080"),
            ("Kuma main", "uptime-kuma", "http://192.0.2.12:3001"),
            ("Kuma main 2", "uptime-kuma", "http://192.0.2.13:3001"),
            ("Gatus half auth", "gatus", "http://192.0.2.15:8080"),
            ("Gatus file key", "gatus", "http://192.0.2.16:8080")])
        self.assertNotIn("user", res.sources[3], "Homepage sends Basic only with username and password")
        self.assertEqual(res.sources[4]["password_env"], "HOMEPAGE_FILE_GATUS_PW")
        self.assertEqual(res.env, {"HOMEPAGE_FILE_GATUS_PW": FILE_KEY}, "the file's content, without the newline")

    def test_notes(self):
        self.run_odd()
        text = "\n".join(self.logs)
        for words in ["Odd: an entry that is not `- Name: ...` skipped",
                      "Odd / FTP: launcher entry skipped, href is not an http(s) address",
                      "Odd / Key in query: launcher entry skipped, its address would hold a key",
                      "Odd / User in href: launcher entry skipped, its address would hold a key",
                      "Odd / Secret placeholder: launcher entry skipped, its address would hold a key",
                      "Odd / Unset host: launcher entry skipped, HOMEPAGE_VAR_NOT_SET is not set",
                      "Odd / Not a dict: not a service, skipped",
                      "Odd / Widget junk: a widget without a type skipped",
                      "Odd / Widget junk: widget sonarr is not yet supported",
                      "Odd / Kuma (main): widget uptimekuma skipped (slug is required",
                      "Odd / Kuma (main): widget uptimekuma skipped, HOMEPAGE_VAR_NOT_SET is not set",
                      "top: an entry that is not `- Group name: [...]` skipped"]:
            self.assertIn(words, text)

    def test_no_literal_key_anywhere(self):
        res = self.run_odd()
        everything = json.dumps([res.services, res.sources]) + "\n".join(self.logs)
        self.assertNotIn(LITERAL, everything)
        self.assertNotIn(FILE_KEY, everything, "a file's key only in res.env, for the source's password_env")

    def test_empty_and_not_a_list(self):
        self.assertEqual(self.load("").services, [])
        self.assertEqual(self.load("# only a comment\n").sources, [])
        with self.assertRaisesRegex(homepage.ImportFailed, "must be a list of groups"):
            self.load("Media: {}\n")

    def test_bad_yaml_names_only_the_line(self):
        with self.assertRaises(homepage.ImportFailed) as ctx:
            self.load("- Media:\n    - Sonarr: {href: [%s\n" % LITERAL)
        self.assertIn("is not valid YAML (line", str(ctx.exception))
        self.assertNotIn(LITERAL, str(ctx.exception))

    def test_too_big(self):
        with self.assertRaisesRegex(homepage.ImportFailed, "larger than 1 MB"):
            self.load("#" * (homepage.MAX_FILE + 10))

    def test_aliases_do_not_blow_up(self):
        # Each group holds the one before twice: 2^30 entries if followed blindly.
        text = "- G: &a0 [{S: {href: 'http://192.0.2.1'}}]\n" + "".join(
            "- G%d: &a%d [{N: *a%d}, {N: *a%d}]\n" % (n, n, n - 1, n - 1) for n in range(1, 31))
        res = self.load(text)
        self.assertEqual(res.services, [{"name": "S", "url": "http://192.0.2.1", "group": "G"}])
        self.assertLessEqual(len(self.logs), homepage.MAX_NOTES + 2)
        self.assertIn("homepage: stopped after %d entries" % homepage.MAX_ENTRIES, self.logs[1:])


@needs_yaml
class HomepageLiteralKeys(TmpFiles, unittest.TestCase):
    """A key written in services.yaml for a widget the bridge imports stops the start; the key is never printed."""

    CASES = [
        "- M:\n    - Gatus:\n        widget: {type: gatus, url: http://192.0.2.5:8080, username: bridge, "
        "password: %s}\n" % LITERAL,
        "- M:\n    - Gatus:\n        widget: {type: gatus, url: http://192.0.2.5:8080, username: bridge, "
        "password: 'x{{HOMEPAGE_VAR_GATUS_PW}}'}\n".replace("x", LITERAL, 1),
        "- M:\n    - Gatus:\n        widget: {type: gatus, url: http://192.0.2.5:8080, username: bridge, "
        "password: 1234567}\n",
        "- M:\n    - Kuma:\n        widget: {type: uptimekuma, url: 'http://192.0.2.5:3001/?token=%s', slug: home}\n"
        % LITERAL,
        "- M:\n    - Gatus:\n        widget: {type: gatus, url: 'http://bridge:%s@192.0.2.5:8080'}\n" % LITERAL,
        "- M:\n    - PVE:\n        widget: {type: proxmox, url: 'https://192.0.2.30:8006', "
        "username: 'monitor@pve!homepage', password: %s}\n" % LITERAL,
    ]

    def test_refused_without_the_key(self):
        for i, text in enumerate(self.CASES):
            with self.subTest(case=i):
                with self.assertRaises(homepage.ImportFailed) as ctx:
                    self.load(text)
                msg = str(ctx.exception)
                self.assertNotIn(LITERAL, msg)
                self.assertNotIn("1234567", msg)
                self.assertIn("M / ", msg)
                self.assertIn("env variable", msg)

    def test_the_message_says_how(self):
        with self.assertRaises(homepage.ImportFailed) as ctx:
            self.load(self.CASES[0])
        self.assertEqual(str(ctx.exception), (
            "homepage: M / Gatus: the widget's password is written in services.yaml. The bridge reads keys only "
            "from env variables: set HOMEPAGE_VAR_GATUS_PASSWORD (for Homepage and the bridge) and write "
            "\"{{HOMEPAGE_VAR_GATUS_PASSWORD}}\" as the password in services.yaml instead, or leave this service "
            "out with \"skip\""))

    def test_skip_lets_it_start(self):
        res = self.load(self.CASES[0], skip=["Gatus"])
        self.assertEqual(res.sources, [])

    def test_literal_keys_of_unsupported_widgets_are_never_read(self):
        res = self.load("- M:\n    - Sonarr:\n        href: http://192.0.2.20:8989\n"
                        "        widget: {type: sonarr, url: http://192.0.2.20:8989, key: %s}\n" % LITERAL)
        self.assertEqual([s["name"] for s in res.services], ["Sonarr"])
        self.assertNotIn(LITERAL, json.dumps(res.services) + "\n".join(self.logs))

    def test_server_stops_at_start_and_the_log_has_no_key(self):
        path = write(self.tmp, "services.yaml", self.CASES[0])
        cfg = write(self.tmp, "config.json", json.dumps({"listen": "127.0.0.1:0", "homepage": {"file": path}}))
        env = dict(os.environ, HOMELAB_TOKENS=TOKEN)
        res = subprocess.run([sys.executable, os.path.join(HERE, "reference_server.py"), "--config", cfg],
                             capture_output=True, text=True, timeout=30, env=env)
        self.assertEqual(res.returncode, 2)
        self.assertIn("the widget's password is written in services.yaml", res.stderr)
        self.assertNotIn(LITERAL, res.stdout + res.stderr)


@needs_yaml
class HomepageConfig(TmpFiles, unittest.TestCase):
    """The `homepage` key in reference_server.Config: imported entries after the config's own, keys from the env."""

    def test_merged_with_the_configs_own(self):
        yml = write(self.tmp, "services.yaml", (
            "- M:\n    - Gatus:\n        href: http://192.0.2.5:8080\n"
            "        widget: {type: gatus, url: http://192.0.2.5:8080, username: bridge, "
            "password: '{{HOMEPAGE_FILE_GATUS_PW}}'}\n"))
        secret = write(self.tmp, "pw", FILE_KEY + "\n")
        cfg = rs.Config({"tokens": [TOKEN], "homepage": {"file": yml},
                         "services": [{"name": "Own", "url": "http://192.0.2.1"}],
                         "sources": [{"name": "Gatus", "type": "gatus", "url": "http://192.0.2.6:8080"}]},
                        env={"HOMEPAGE_FILE_GATUS_PW": secret})
        self.assertEqual([s["name"] for s in cfg.services], ["Own", "Gatus"])
        self.assertEqual([(s["name"], s["env"]) for s in cfg.sources],
                         [("Gatus", {}), ("Gatus 2", {"HOMEPAGE_FILE_GATUS_PW": FILE_KEY})])
        self.assertIn("HOMEPAGE_FILE_GATUS_PW", rs.SOURCE_SECRET_ENV, "kept from commands, like every key")

    def test_unreadable_file_key_is_not_set_never_the_path(self):
        yml = write(self.tmp, "services.yaml", (
            "- M:\n    - Gatus:\n        widget: {type: gatus, url: http://192.0.2.5:8080, username: bridge, "
            "password: '{{HOMEPAGE_FILE_GATUS_PW}}'}\n"))
        logs = []
        with mock.patch.object(rs, "log", logs.append):
            cfg = rs.Config({"tokens": [TOKEN], "homepage": {"file": yml}},
                            env={"HOMEPAGE_FILE_GATUS_PW": os.path.join(self.tmp, "missing")})
        self.assertEqual(cfg.sources[0]["env"], {"HOMEPAGE_FILE_GATUS_PW": ""})
        self.assertIn("homepage: M / Gatus: cannot read the file that HOMEPAGE_FILE_GATUS_PW names", logs)

    def test_launcher_only_runs_no_sources(self):
        yml = write(self.tmp, "services.yaml", "- M:\n    - A: {href: http://192.0.2.5}\n")
        cfg = rs.Config({"tokens": [TOKEN], "homepage": {"file": yml, "sources": False}}, env={})
        self.assertEqual((cfg.sources, [s["name"] for s in cfg.services]), ([], ["A"]))
        self.assertIsNone(rs.RealApp(cfg).sources)


class PyYAMLMissing(TmpFiles, unittest.TestCase):
    """Without PyYAML (reference_server.py outside the Docker image) the import says what is missing."""

    def test_read_yaml_says_what_is_missing(self):
        path = write(self.tmp, "services.yaml", "- Media: []\n")
        with mock.patch.dict(sys.modules, {"yaml": None}):
            with self.assertRaises(homepage.ImportFailed) as ctx:
                homepage.read_yaml(path)
        msg = str(ctx.exception)
        self.assertIn("needs PyYAML", msg)
        self.assertIn("Docker image", msg)
        self.assertIn("pip install pyyaml", msg)
        self.assertIn("remove the \"homepage\" key", msg)

    def test_config_stops_with_that_message(self):
        path = write(self.tmp, "services.yaml", "- Media: []\n")
        with mock.patch.dict(sys.modules, {"yaml": None}):
            with self.assertRaisesRegex(rs.ConfigError, "needs PyYAML"):
                rs.Config({"tokens": [TOKEN], "homepage": {"file": path}}, env={})

    def test_without_the_key_nothing_is_read(self):
        with mock.patch.dict(sys.modules, {"yaml": None}):
            cfg = rs.Config({"tokens": [TOKEN], "services": [{"name": "A", "url": "http://192.0.2.1"}]}, env={})
        self.assertEqual((cfg.sources, len(cfg.services)), ([], 1))


@needs_yaml
class HomepageBridge(TmpFiles, unittest.TestCase):
    """server/examples/sources-homepage.json against the Kuma and Gatus fake upstreams: /services, /state, /info,
    the key from the env sent to Gatus and never answered, and scripts/check-live-api."""

    def start(self, extra_env=None):
        with open(os.path.join(HERE, "examples", "sources-homepage.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        kuma = FakeUpstream(os.path.join(HERE, "recordings", "uptime-kuma", "normal.json")).start()
        gatus = FakeUpstream(os.path.join(HERE, "recordings", "gatus", "normal.json")).start()
        pve = FakeUpstream(os.path.join(HERE, "recordings", "proxmox", "normal.json")).start()
        for up in (kuma, gatus, pve):
            self.addCleanup(up.stop)
        self.pve = pve
        self.gatus = gatus
        raw["listen"] = "127.0.0.1:0"
        raw["homepage"]["file"] = NORMAL
        path = write(self.tmp, "config.json", json.dumps(raw))
        env = {"HOMELAB_TOKENS": TOKEN, "HOMEPAGE_VAR_KUMA_HOST": kuma.url.split("//", 1)[1],
               "HOMEPAGE_VAR_GATUS_HOST": gatus.url.split("//", 1)[1],
               "HOMEPAGE_VAR_GATUS_PASSWORD": GATUS_PASSWORD, "HOMEPAGE_VAR_PVE_URL": pve.url,
               "HOMEPAGE_VAR_PVE_SECRET": PVE_SECRET}
        env.update(extra_env or {})
        cfg = rs.Config.load(path, env=env)
        app = rs.RealApp(cfg)
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and all(st.runs >= 1 for st in app.sources.states.values()))
        return httpd.server_address[1]

    def test_answers(self):
        port = self.start()
        _, _, services = call(port, "GET", "/api/v1/services", headers=AUTH)
        self.assertEqual([s["name"] for s in services["services"]],
                         ["Uptime Kuma", "Gatus", "Jellyfin", "Sonarr", "qBittorrent", "Proxmox", "Pi-hole",
                          "Router"],
                         "Kuma's monitor links are not added: Homepage's entries are the launcher")
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        ids = [p["id"] for p in state["problems"]]
        self.assertIn("Uptime Kuma:monitor-1", ids)
        self.assertIn("Gatus:endpoint-core_jellyfin", ids)
        self.assertEqual([c["id"] for c in state["cards"]], ["Uptime Kuma:monitors", "Gatus:monitors"])
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertIn("services", info["features"])
        self.assertEqual([(s["name"], s["type"], s["state"]) for s in info["sources"]],
                         [("Uptime Kuma", "uptime-kuma", "ok"), ("Gatus", "gatus", "ok"), ("Proxmox", "proxmox", "ok")])
        self.assertTrue(any(h["id"].startswith("Proxmox:") for h in state["hosts"]))
        self.assertEqual(self.pve.requests[0]["headers"].get("Authorization"),
                         "PVEAPIToken=monitor@pve!homepage=" + PVE_SECRET)
        self.assertTrue(self.gatus.requests[0]["headers"].get("Authorization", "").startswith("Basic "))
        for body in (services, state, info):
            self.assertNotIn(GATUS_PASSWORD, json.dumps(body))
            self.assertNotIn(PVE_SECRET, json.dumps(body))

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_passes(self):
        port = self.start()
        script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
        res = subprocess.run(["bash", script, "--token", TOKEN, "http://127.0.0.1:%d" % port],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
