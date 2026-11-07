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
RADARR_FILE_KEY = "file-made-up-radarr-key-88"

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
        widgets: [7, {url: http://192.0.2.10}, {type: jellyfin, url: http://192.0.2.11, key: %(literal)s}]
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
    - Pi-hole no version:
        widget: {type: pihole, url: http://192.0.2.20, key: %(literal)s}
    - Pi-hole v5:
        widget: {type: pihole, url: http://192.0.2.21, version: 5, key: "{{HOMEPAGE_VAR_PIHOLE_KEY}}"}
    - Pi-hole six:
        widget: {type: pihole, url: http://192.0.2.22, version: six, key: "{{HOMEPAGE_VAR_PIHOLE_KEY}}"}
    - Pi-hole unset version:
        widget: {type: pihole, url: http://192.0.2.29, version: "{{HOMEPAGE_VAR_NOT_SET}}"}
    - Pi-hole open:
        widget: {type: pihole, url: http://192.0.2.23, version: "6.1"}
    - AdGuard user only:
        widget: {type: adguard, url: "http://192.0.2.24:3000", username: monitor}
    - Sonarr no key:
        widget: {type: sonarr, url: "http://192.0.2.25:8989", enableQueue: true}
    - Radarr file key:
        widget: {type: radarr, url: "http://192.0.2.26:7878", key: "{{HOMEPAGE_FILE_RADARR_KEY}}"}
    - qBittorrent both:
        widget: {type: qbittorrent, url: "http://192.0.2.27:8080", username: admin,
                 password: "{{HOMEPAGE_VAR_QBIT_PASSWORD}}", key: "{{HOMEPAGE_VAR_QBIT_KEY}}"}
    - qBittorrent no password:
        widget: {type: qbittorrent, url: "http://192.0.2.28:8080", username: admin}
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
class HomepageMinecraft(TmpFiles, unittest.TestCase):
    """A minecraft widget (url: udp://host:port) becomes a gameserver source with that one server; gamedig is not
    mapped."""

    YAML = """
- Games:
    - Survival:
        href: https://mc.example.com
        widget: {type: minecraft, url: "udp://mc.example.com:25570"}
    - Creative:
        widget: {type: minecraft, url: "udp://nas.tail1234.ts.net"}
    - Broken:
        widget: {type: minecraft, url: "not a url"}
    - Login:
        widget: {type: minecraft, url: "udp://user:pw@mc.example.com:25565"}
    - Counter:
        widget: {type: gamedig, url: "udp://mc.example.com:27015", serverType: csgo}
"""

    def test_minecraft_widget(self):
        res = self.load(self.YAML)
        self.assertEqual(res.sources, [
            {"name": "Survival", "every": 60, "type": "gameserver",
             "servers": [{"name": "Survival", "type": "minecraft", "host": "mc.example.com", "port": 25570}]},
            {"name": "Creative", "every": 60, "type": "gameserver",
             "servers": [{"name": "Creative", "type": "minecraft", "host": "nas.tail1234.ts.net", "port": 25565}]}])
        self.assertIn("homepage: Games / Survival: widget minecraft is the source 'Survival' (gameserver)", self.logs)
        self.assertIn("homepage: Games / Broken: widget minecraft is not supported by the Homelab Bridge: "
                      "the widget's url is not udp://host:port", self.logs)
        self.assertIn("homepage: Games / Counter: widget gamedig is not yet supported by the Homelab Bridge",
                      self.logs)
        self.assertEqual([s["name"] for s in res.sources if "actions" in s or "expect_up" in str(s)], [])


@needs_yaml
class HomepageNormal(TmpFiles, unittest.TestCase):
    """server/examples/homepage-services.yaml: every service a launcher entry, every supported widget a source."""

    ENV = {"HOMEPAGE_VAR_KUMA_HOST": "192.0.2.10:3001", "HOMEPAGE_VAR_GATUS_HOST": "192.0.2.10:8080",
           "HOMEPAGE_VAR_GATUS_PASSWORD": GATUS_PASSWORD, "HOMEPAGE_VAR_PVE_URL": "https://192.0.2.30:8006",
           "HOMEPAGE_VAR_PVE_SECRET": PVE_SECRET, "HOMEPAGE_VAR_SONARR_HOST": "192.0.2.20:8989",
           "HOMEPAGE_VAR_RADARR_HOST": "192.0.2.20:7878", "HOMEPAGE_VAR_QBIT_HOST": "192.0.2.20:8081",
           "HOMEPAGE_VAR_PIHOLE_HOST": "192.0.2.2", "HOMEPAGE_VAR_ADGUARD_HOST": "192.0.2.3:3000"}

    def test_launcher(self):
        res = self.load(NORMAL, self.ENV)
        self.assertEqual(services_of(res), [
            ("Uptime Kuma", "http://192.0.2.10:3001", "Monitoring", "waveform.path.ecg"),
            ("Gatus", "http://192.0.2.10:8080", "Monitoring", "waveform.path.ecg"),
            ("Jellyfin", "https://nas.tail1234.ts.net:8920", "Media", "play.rectangle"),
            ("Sonarr", "http://192.0.2.20:8989", "Media", "tv"),
            ("Radarr", "http://192.0.2.20:7878", "Media", "film"),
            ("qBittorrent", "http://192.0.2.20:8081", "Downloads", "arrow.down.circle"),
            ("Proxmox", "https://192.0.2.30:8006", "Servers", "server.rack"),
            ("Pi-hole", "http://192.0.2.2/admin", "Network", "shield"),
            ("AdGuard Home", "http://192.0.2.3:3000", "Network", "shield"),
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
            {"name": "Sonarr", "every": 60, "type": "sonarr", "url": "http://192.0.2.20:8989",
             "key_env": "HOMEPAGE_VAR_SONARR_KEY"},
            {"name": "Radarr", "every": 60, "type": "radarr", "url": "http://192.0.2.20:7878",
             "key_env": "HOMEPAGE_VAR_RADARR_KEY"},
            {"name": "qBittorrent", "every": 60, "type": "qbittorrent", "url": "http://192.0.2.20:8081",
             "username": "admin", "password_env": "HOMEPAGE_VAR_QBIT_PASSWORD"},
            {"name": "Proxmox", "every": 60, "type": "proxmox", "url": "https://192.0.2.30:8006",
             "token_id": "monitor@pve!homepage", "key_env": "HOMEPAGE_VAR_PVE_SECRET"},
            {"name": "Pi-hole", "every": 60, "type": "pihole", "url": "http://192.0.2.2",
             "key_env": "HOMEPAGE_VAR_PIHOLE_KEY"},
            {"name": "AdGuard Home", "every": 60, "type": "adguard", "url": "http://192.0.2.3:3000",
             "username": "monitor", "password_env": "HOMEPAGE_VAR_ADGUARD_PASSWORD"}])
        self.assertEqual(res.env, {})

    def test_log_lists_what_is_not_supported(self):
        self.load(NORMAL, self.ENV)
        self.assertEqual(self.logs, [
            "homepage: 10 launcher entries and 8 sources from homepage-services.yaml",
            "homepage: Monitoring / Uptime Kuma: widget uptimekuma is the source 'Uptime Kuma' (uptime-kuma)",
            "homepage: Monitoring / Gatus: widget gatus is the source 'Gatus' (gatus)",
            "homepage: Media / Jellyfin: widget jellyfin is not yet supported by the Homelab Bridge",
            "homepage: Media / Sonarr: widget sonarr is the source 'Sonarr' (sonarr)",
            "homepage: Media / Radarr: widget radarr is the source 'Radarr' (radarr)",
            "homepage: Media / Downloads / qBittorrent: widget qbittorrent is the source 'qBittorrent' (qbittorrent)",
            "homepage: Servers / Proxmox: widget proxmox is the source 'Proxmox' (proxmox)",
            "homepage: Network / Pi-hole: widget pihole is the source 'Pi-hole' (pihole)",
            "homepage: Network / AdGuard Home: widget adguard is the source 'AdGuard Home' (adguard)"])

    def test_options(self):
        res = self.load(NORMAL, self.ENV, sources=False, skip=["media", "ROUTER"], every=300)
        self.assertEqual([s["name"] for s in res.services],
                         ["Uptime Kuma", "Gatus", "Proxmox", "Pi-hole", "AdGuard Home"])
        self.assertEqual(res.sources, [])
        res = self.load(NORMAL, self.ENV, every=300)
        self.assertEqual({s["every"] for s in res.sources}, {300})

    def test_extra_keys_for_a_source(self):
        res = self.load(NORMAL, self.ENV, extra={"proxmox": {"ca_file": "/certs/pve.pem", "_note": "x"},
                                                 "Nothing here": {"insecure": True}})
        pve = next(s for s in res.sources if s["name"] == "Proxmox")
        self.assertEqual(pve["ca_file"], "/certs/pve.pem")
        self.assertNotIn("_note", pve)
        self.assertIn("homepage: extra: no imported source for the service 'nothing here'", self.logs)

    def test_actions_only_by_hand(self):
        res = self.load(NORMAL, self.ENV)
        self.assertEqual([s["name"] for s in res.sources if "actions" in s], [], "the import never adds actions")
        res = self.load(NORMAL, self.ENV, extra={"Pi-hole": {"actions": {"pause": [5, 15]}}})
        self.assertEqual([(s["name"], s["actions"]) for s in res.sources if "actions" in s],
                         [("Pi-hole", {"pause": [5, 15]})], "only the pause written in the bridge's config")

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
        self.assertEqual([s["name"] for s in res.sources], ["Uptime Kuma", "Gatus 2", "Sonarr", "Radarr",
                                                            "qBittorrent", "Proxmox", "Pi-hole", "AdGuard Home"])

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
        radarr = write(self.tmp, "radarr-key", RADARR_FILE_KEY)
        return self.load(ODD, {"HOMEPAGE_FILE_GATUS_PW": path, "HOMEPAGE_FILE_RADARR_KEY": radarr},
                         skip=["Skipped group"])

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
            ("Gatus file key", "gatus", "http://192.0.2.16:8080"),
            ("Pi-hole open", "pihole", "http://192.0.2.23"),
            ("AdGuard user only", "adguard", "http://192.0.2.24:3000"),
            ("Radarr file key", "radarr", "http://192.0.2.26:7878"),
            ("qBittorrent both", "qbittorrent", "http://192.0.2.27:8080")])
        by_name = {s["name"]: s for s in res.sources}
        self.assertNotIn("user", by_name["Gatus half auth"], "Homepage sends Basic only with username and password")
        self.assertEqual(by_name["Gatus file key"]["password_env"], "HOMEPAGE_FILE_GATUS_PW")
        self.assertNotIn("key_env", by_name["Pi-hole open"], "version \"6.1\" is v6; no key: a Pi-hole without one")
        self.assertNotIn("username", by_name["AdGuard user only"], "no password: no Basic, as in Homepage")
        self.assertEqual(by_name["Radarr file key"]["key_env"], "HOMEPAGE_FILE_RADARR_KEY")
        self.assertEqual({k: v for k, v in by_name["qBittorrent both"].items() if k.endswith("_env") or k == "username"},
                         {"key_env": "HOMEPAGE_VAR_QBIT_KEY"}, "the key first, the login only without it")
        self.assertEqual([s["name"] for s in res.sources if "actions" in s], [])
        self.assertEqual(res.env, {"HOMEPAGE_FILE_GATUS_PW": FILE_KEY, "HOMEPAGE_FILE_RADARR_KEY": RADARR_FILE_KEY},
                         "the files' content, without the newline")

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
                      "Odd / Widget junk: widget jellyfin is not yet supported",
                      "Odd / Pi-hole no version: widget pihole is not supported by the Homelab Bridge: Pi-hole v5 or "
                      "older (no version: 6 in the widget); the bridge reads Pi-hole v6 and newer",
                      "Odd / Pi-hole v5: widget pihole is not supported by the Homelab Bridge: Pi-hole v5 or older",
                      "Odd / Pi-hole six: widget pihole is not supported by the Homelab Bridge: its version is not "
                      "a number",
                      "Odd / Pi-hole unset version: widget pihole skipped, HOMEPAGE_VAR_NOT_SET is not set",
                      "Odd / Sonarr no key: widget sonarr skipped (key_env is required",
                      "Odd / qBittorrent no password: widget qbittorrent skipped (key_env (an API key) or username",
                      "Odd / Kuma (main): widget uptimekuma skipped (slug is required",
                      "Odd / Kuma (main): widget uptimekuma skipped, HOMEPAGE_VAR_NOT_SET is not set",
                      "top: an entry that is not `- Group name: [...]` skipped"]:
            self.assertIn(words, text)

    def test_no_literal_key_anywhere(self):
        res = self.run_odd()
        everything = json.dumps([res.services, res.sources]) + "\n".join(self.logs)
        self.assertNotIn(LITERAL, everything)
        self.assertNotIn(FILE_KEY, everything, "a file's key only in res.env, for the source's password_env")
        self.assertNotIn(RADARR_FILE_KEY, everything)

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
        "- M:\n    - Pi-hole:\n        widget: {type: pihole, url: http://192.0.2.53, version: 6, key: %s}\n"
        % LITERAL,
        "- M:\n    - AdGuard:\n        widget: {type: adguard, url: 'http://192.0.2.54:3000', username: admin, "
        "password: %s}\n" % LITERAL,
        "- M:\n    - AdGuard:\n        widget: {type: adguard, url: 'http://192.0.2.54:3000', password: %s}\n"
        % LITERAL,
        "- M:\n    - Sonarr:\n        widget: {type: sonarr, url: 'http://192.0.2.20:8989', key: %s}\n" % LITERAL,
        "- M:\n    - Radarr:\n        widget: {type: radarr, url: 'http://192.0.2.20:7878/?apikey=%s'}\n" % LITERAL,
        "- M:\n    - qBit:\n        widget: {type: qbittorrent, url: 'http://192.0.2.20:8080', key: qbt_%s}\n"
        % LITERAL,
        "- M:\n    - qBit:\n        widget: {type: qbittorrent, url: 'http://192.0.2.20:8080', username: admin, "
        "password: %s, key: '{{HOMEPAGE_VAR_QBIT_KEY}}'}\n" % LITERAL,
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

    def test_key_placeholder_in_a_widget_url_path(self):
        text = ("- M:\n    - Kuma:\n        widget: {type: uptimekuma, "
                "url: 'http://192.0.2.5:3001/{{HOMEPAGE_VAR_KUMA_TOKEN}}/', slug: home}\n")
        with self.assertRaises(homepage.ImportFailed) as ctx:
            self.load(text, env={"HOMEPAGE_VAR_KUMA_TOKEN": LITERAL})
        self.assertIn("M / Kuma: the widget's url holds", str(ctx.exception))
        self.assertNotIn(LITERAL, str(ctx.exception) + "\n".join(self.logs))
        res = self.load(text.replace("KUMA_TOKEN", "KUMA_HOST"), env={"HOMEPAGE_VAR_KUMA_HOST": "kuma"})
        self.assertEqual([s["url"] for s in res.sources], ["http://192.0.2.5:3001/kuma/"])

    def test_skip_lets_it_start(self):
        res = self.load(self.CASES[0], skip=["Gatus"])
        self.assertEqual(res.sources, [])

    def test_literal_keys_of_unsupported_widgets_are_never_read(self):
        res = self.load("- M:\n    - Jellyfin:\n        href: http://192.0.2.20:8096\n"
                        "        widget: {type: jellyfin, url: http://192.0.2.20:8096, key: %s}\n"
                        "    - Old Pi-hole:\n        href: http://192.0.2.53/admin\n"
                        "        widget: {type: pihole, url: http://192.0.2.53, version: 5, key: %s}\n"
                        % (LITERAL, LITERAL))
        self.assertEqual([s["name"] for s in res.services], ["Jellyfin", "Old Pi-hole"])
        self.assertEqual(res.sources, [], "a Pi-hole v5 is not imported, so its key is not looked at")
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
    """server/examples/sources-homepage.json against a fake upstream per widget: /services, /state, /info, the keys
    from the env sent upstream and never answered, no actions, and scripts/check-live-api."""

    # recording folder -> the HOMEPAGE_VAR_ with its address in homepage-services.yaml
    UPSTREAMS = {"uptime-kuma": "KUMA_HOST", "gatus": "GATUS_HOST", "proxmox": "PVE_URL", "pihole": "PIHOLE_HOST",
                 "adguard": "ADGUARD_HOST", "sonarr": "SONARR_HOST", "radarr": "RADARR_HOST",
                 "qbittorrent": "QBIT_HOST"}
    KEYS = {"HOMEPAGE_VAR_GATUS_PASSWORD": GATUS_PASSWORD, "HOMEPAGE_VAR_PVE_SECRET": PVE_SECRET,
            "HOMEPAGE_VAR_PIHOLE_KEY": "made-up-pihole-0123456789",
            "HOMEPAGE_VAR_ADGUARD_PASSWORD": "made-up-adguard-0123456789",
            "HOMEPAGE_VAR_SONARR_KEY": "made-up-sonarr-0123456789",
            "HOMEPAGE_VAR_RADARR_KEY": "made-up-radarr-0123456789",
            "HOMEPAGE_VAR_QBIT_PASSWORD": "made-up-qbit-0123456789"}

    def start(self, extra_env=None):
        with open(os.path.join(HERE, "examples", "sources-homepage.json"), encoding="utf-8") as fh:
            raw = json.load(fh)
        env = dict(self.KEYS, HOMELAB_TOKENS=TOKEN)
        self.up = {}
        for kind, var in self.UPSTREAMS.items():
            up = FakeUpstream(os.path.join(HERE, "recordings", kind, "normal.json")).start()
            self.addCleanup(up.stop)
            self.up[kind] = up
            env["HOMEPAGE_VAR_" + var] = up.url if var.endswith("_URL") else up.url.split("//", 1)[1]
        raw["listen"] = "127.0.0.1:0"
        raw["homepage"]["file"] = NORMAL
        path = write(self.tmp, "config.json", json.dumps(raw))
        env.update(extra_env or {})
        cfg = rs.Config.load(path, env=env)
        self.assertEqual([s["name"] for s in cfg.sources if s.get("actions")], [], "the import adds no actions")
        app = rs.RealApp(cfg)
        httpd = start_app(app)
        self.addCleanup(stop_app, httpd)
        wait_for(lambda: app.collector.runs >= 1 and all(st.runs >= 1 for st in app.sources.states.values()))
        return httpd.server_address[1]

    def header(self, kind, name):
        """The header `name` of the first request to that upstream that has it."""
        for req in self.up[kind].requests:
            for k, v in req["headers"].items():
                if k.lower() == name.lower():
                    return v
        return None

    def test_answers(self):
        port = self.start()
        _, _, services = call(port, "GET", "/api/v1/services", headers=AUTH)
        self.assertEqual([s["name"] for s in services["services"]],
                         ["Uptime Kuma", "Gatus", "Jellyfin", "Sonarr", "Radarr", "qBittorrent", "Proxmox", "Pi-hole",
                          "AdGuard Home", "Router"],
                         "Kuma's monitor links are not added: Homepage's entries are the launcher")
        _, _, state = call(port, "GET", "/api/v1/state", headers=AUTH)
        ids = [p["id"] for p in state["problems"]]
        self.assertIn("Uptime Kuma:monitor-1", ids)
        self.assertIn("Gatus:endpoint-core_jellyfin", ids)
        cards = [c["id"] for c in state["cards"]]
        for want in ("Uptime Kuma:monitors", "Gatus:monitors", "Pi-hole:dns", "AdGuard Home:dns", "Sonarr:queue",
                     "Radarr:queue", "qBittorrent:downloads"):
            self.assertIn(want, cards)
        _, _, info = call(port, "GET", "/api/v1/info", headers=AUTH)
        self.assertIn("services", info["features"])
        self.assertNotIn("run-actions", info["features"])
        self.assertEqual([(s["name"], s["type"], s["state"]) for s in info["sources"]],
                         [("Uptime Kuma", "uptime-kuma", "ok"), ("Gatus", "gatus", "ok"), ("Sonarr", "sonarr", "ok"),
                          ("Radarr", "radarr", "ok"), ("qBittorrent", "qbittorrent", "ok"),
                          ("Proxmox", "proxmox", "ok"), ("Pi-hole", "pihole", "ok"),
                          ("AdGuard Home", "adguard", "ok")])
        self.assertTrue(any(h["id"].startswith("Proxmox:") for h in state["hosts"]))
        self.assertEqual(self.header("proxmox", "Authorization"), "PVEAPIToken=monitor@pve!homepage=" + PVE_SECRET)
        self.assertTrue(self.header("gatus", "Authorization").startswith("Basic "))
        self.assertTrue(self.header("adguard", "Authorization").startswith("Basic "))
        self.assertEqual(self.header("sonarr", "X-Api-Key"), self.KEYS["HOMEPAGE_VAR_SONARR_KEY"])
        self.assertEqual(self.header("radarr", "X-Api-Key"), self.KEYS["HOMEPAGE_VAR_RADARR_KEY"])
        logins = {k: [r for r in self.up[k].requests if r["method"] == "POST"][0]["body"]
                  for k in ("pihole", "qbittorrent")}
        self.assertIn(self.KEYS["HOMEPAGE_VAR_PIHOLE_KEY"], logins["pihole"])
        self.assertIn("username=admin", logins["qbittorrent"])
        self.assertEqual([r["path"] for k in ("pihole", "adguard") for r in self.up[k].requests
                          if r["path"].startswith(("/api/dns/blocking", "/control/protection"))
                          and r["method"] == "POST"], [], "read-only: no pause")
        for body in (services, state, info):
            for value in self.KEYS.values():
                self.assertNotIn(value, json.dumps(body))

    @unittest.skipUnless(shutil.which("bash"), "needs bash")
    def test_check_live_api_passes(self):
        port = self.start()
        script = os.path.join(os.path.dirname(HERE), "scripts", "check-live-api")
        res = subprocess.run(["bash", script, "--token", TOKEN, "http://127.0.0.1:%d" % port],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
