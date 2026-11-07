#!/usr/bin/env python3
"""Homelab Companion API v1 reference server (stdlib only, Python 3.9+).

Two modes:

  reference_server.py --config config.json
      Real mode. Reports this machine, other hosts, HTTP checks, cards from a folder, services, and
      (opt-in) pending actions and chat. Meant to sit behind `tailscale serve` on 127.0.0.1.

  reference_server.py --fixtures DIR [--port N] [--state state-problem.json] [--token T]
      Fixture mode. Serves the app's example JSON files, for tests and screenshots.

See docs/REFERENCE_SERVER.md and server/openapi.yaml.
"""

import argparse
import concurrent.futures
import datetime
import glob
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import traceback
import zlib
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "2026-11-04"
SERVER_NAME = "homelab-reference"
API_PREFIX = "/api/v1/"
MAX_BODY = 16 * 1024
MAX_TEXT = 4000
MAX_FILE = 64 * 1024
MAX_CARDS = 50
MAX_PENDING = 100
KEEP_MESSAGES = 1000
PAGE_MESSAGES = 200
MAX_UPLOAD = 25 * 1024 * 1024
MAX_PDF_TITLE = 128
MAX_SHARE_TITLE = 200
MAX_SHARE_URL = 2048
UPLOADS_PER_HOUR = 20
SHARES_PER_HOUR = 30
SHARE_ID_RE = re.compile(r"^[0-9a-f-]{36}$")
WILLHABEN_PATH_RE = re.compile(r"-(\d{6,12})/?$")

BUTTON_RE = re.compile(r"^HOMELAB_(APPROVE|ALWAYS|DENY)_([A-Za-z0-9-]{1,32})_([0-9a-f]{16})$")
PENDING_ID_RE = re.compile(r"^[A-Za-z0-9-]{1,32}$")
# No word may start with "-": a stray arg must never become an option of the command.
# Always used with fullmatch(): "$" alone would also accept a trailing newline.
ARG_RE = re.compile(r"^[A-Za-z0-9_.@][A-Za-z0-9_.@-]{0,63}( [A-Za-z0-9_.@][A-Za-z0-9_.@-]{0,63})*$")
HOSTNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.:-]*$")
SECRET_ENV = ("HOMELAB_TOKENS", "HOMELAB_BUTTON_SECRET")
# Env variables that sources read their keys from (key_env, *_env). Filled by a Config with `sources`; kept from
# every command the server runs, like SECRET_ENV.
SOURCE_SECRET_ENV = set()
SEVERITIES = ("problem", "warning")

# Local checks must never go through an HTTP proxy from the environment.
_NO_PROXY = urllib.request.ProxyHandler({})


class ConfigError(Exception):
    pass


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg):
    sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


def child_env(extra=None):
    """Environment for commands we run: ours, minus our secrets."""
    env = {k: v for k, v in os.environ.items() if k not in SECRET_ENV and k not in SOURCE_SECRET_ENV}
    env.update(extra or {})
    return env


def short_error(exc):
    if isinstance(exc, urllib.error.URLError) and not isinstance(exc, urllib.error.HTTPError):
        if not isinstance(exc.reason, BaseException):
            return str(exc.reason)[:120]
        exc = exc.reason
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return "timeout"
    if isinstance(exc, ConnectionRefusedError):
        return "connection refused"
    if isinstance(exc, socket.gaierror):
        return "name not found"
    if isinstance(exc, ssl.SSLError):
        return "TLS error: %s" % (getattr(exc, "reason", None) or exc)
    text = str(exc) or exc.__class__.__name__
    return text[:120]


DEFAULT_ALLOWED_HOSTS = ["localhost", "127.0.0.1", "::1", "*.ts.net"]


def host_allowed(header, allowed):
    """The Host header without its port, matched against names and "*.domain" patterns."""
    host = (header or "").strip().lower()
    if host.startswith("["):
        host = host[1:host.find("]")] if "]" in host else host
    elif host.count(":") == 1:
        host = host.rsplit(":", 1)[0]
    if not host:
        return False
    for a in allowed:
        if a == "*" or a == host or (a.startswith("*.") and host.endswith(a[1:])):
            return True
    return False


def is_loopback(addr):
    try:
        ip = ipaddress.ip_address(addr.split("%", 1)[0])
    except ValueError:
        return addr == "localhost"
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_loopback


def parse_listen(text):
    text = str(text).strip()
    if text.startswith("["):
        host, _, port = text[1:].partition("]:")
    else:
        host, _, port = text.rpartition(":")
    try:
        port = int(port)
    except ValueError:
        raise ConfigError("listen must look like 127.0.0.1:8791, got %r" % text)
    if not host or not 0 <= port <= 65535:
        raise ConfigError("listen must look like 127.0.0.1:8791, got %r" % text)
    return host, port


_warned = {}


def warn_once(path, msg):
    """Log a bad file once per version of that file, not on every /state."""
    try:
        key = (path, os.path.getmtime(path))
    except OSError:
        key = (path, None)
    if _warned.get(path) != key:
        _warned[path] = key
        log(msg)


def read_json_file(path, limit=MAX_FILE):
    if os.path.getsize(path) > limit:
        raise ValueError("file larger than %d bytes" % limit)
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


# --------------------------------------------------------------------------------------------- probes

def _opener(insecure):
    handlers = [_NO_PROXY]
    if insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener(*handlers)


def validate_target(target):
    """Raise ConfigError if a check target is not tcp://host:port, ping://host or http(s)://..."""
    if not isinstance(target, str):
        raise ConfigError("check target must be a string")
    u = urllib.parse.urlsplit(target)
    if u.scheme in ("http", "https"):
        if not u.hostname:
            raise ConfigError("bad URL %r" % target)
    elif u.scheme == "tcp":
        if not u.hostname or not u.port:
            raise ConfigError("tcp check needs tcp://host:port, got %r" % target)
    elif u.scheme == "ping":
        if not u.hostname or not HOSTNAME_RE.fullmatch(u.hostname):
            raise ConfigError("ping check needs ping://host, got %r" % target)
    else:
        raise ConfigError("unsupported check %r (use tcp://, ping://, http:// or https://)" % target)


RESOLVE_FAILED = "can't resolve "


def probe(target, timeout=5.0, expect=None, insecure=False):
    """Return (ok, detail). With expect=None any HTTP answer counts as ok (host reachability)."""
    u = urllib.parse.urlsplit(target)
    try:
        # A name that doesn't resolve is a setup problem (e.g. MagicDNS off on this server), not a sleeping host.
        if u.hostname:
            try:
                socket.getaddrinfo(u.hostname, None)
            except socket.gaierror:
                return False, RESOLVE_FAILED + u.hostname
        if u.scheme in ("http", "https"):
            req = urllib.request.Request(target, method="GET", headers={"User-Agent": SERVER_NAME + "/1"})
            try:
                with _opener(insecure).open(req, timeout=timeout) as resp:
                    code = resp.status
            except urllib.error.HTTPError as exc:
                code = exc.code
                exc.close()
            if expect is None or code in expect:
                return True, "HTTP %d" % code
            return False, "HTTP %d (expected %s)" % (code, "/".join(str(e) for e in expect))
        if u.scheme == "tcp":
            with socket.create_connection((u.hostname, u.port), timeout=timeout):
                return True, "open"
        if u.scheme == "ping":
            wait = str(max(1, int(round(timeout))))
            try:
                res = subprocess.run(["ping", "-c1", "-W", wait, u.hostname], stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout + 3)
            except FileNotFoundError:
                return False, "ping is not installed"
            except subprocess.TimeoutExpired:
                return False, "timeout"
            return res.returncode == 0, "reply" if res.returncode == 0 else "no reply"
    except Exception as exc:  # noqa: BLE001 - every failure is a result here
        return False, short_error(exc)
    return False, "unsupported check"


# --------------------------------------------------------------------------------------------- config

KNOWN_KEYS = {
    "name", "listen", "allow_remote", "allowed_hosts", "tokens", "trust_identity_header", "allowed_logins", "interval",
    "this_host", "hosts", "checks", "thresholds", "cards_dir", "services", "pending_dir", "actions",
    "action_timeout", "chat_command", "chat_timeout", "state_dir", "sources", "homepage",
}


def _strip_comments(obj):
    if isinstance(obj, dict):
        return {k: _strip_comments(v) for k, v in obj.items() if not str(k).startswith("_")}
    if isinstance(obj, list):
        return [_strip_comments(v) for v in obj]
    return obj


def _argv(value, key):
    if value is None:
        return None
    if not isinstance(value, list) or not value or not all(isinstance(x, str) and x for x in value):
        raise ConfigError("%s must be a non-empty list of strings (argv, no shell)" % key)
    return list(value)


class Config:
    def __init__(self, raw, env=None):
        env = os.environ if env is None else env
        if not isinstance(raw, dict):
            raise ConfigError("config must be a JSON object")
        raw = _strip_comments(raw)
        for key in raw:
            if key not in KNOWN_KEYS:
                log("config: unknown key %r ignored" % key)

        self.name = str(raw.get("name") or socket.gethostname())
        self.host, self.port = parse_listen(raw.get("listen", "127.0.0.1:8791"))
        self.allow_remote = bool(raw.get("allow_remote", False))
        # Host header allowlist: blocks DNS rebinding (a web page that renames itself to 127.0.0.1).
        hosts = raw.get("allowed_hosts", DEFAULT_ALLOWED_HOSTS)
        if not isinstance(hosts, list) or not all(isinstance(h, str) and h for h in hosts):
            raise ConfigError("allowed_hosts must be a list of host names (\"*.ts.net\" allowed)")
        self.allowed_hosts = [h.lower() for h in hosts]

        tokens = raw.get("tokens") or []
        if not isinstance(tokens, list) or not all(isinstance(t, str) for t in tokens):
            raise ConfigError("tokens must be a list of strings")
        tokens += [t for t in env.get("HOMELAB_TOKENS", "").split(",")]
        self.tokens = [t.strip() for t in tokens if t.strip()]
        for t in self.tokens:
            if len(t) < 16:
                log("config: warning: a token is shorter than 16 characters")
        self.identity_header = raw.get("trust_identity_header") or None
        if self.identity_header is not None and not isinstance(self.identity_header, str):
            raise ConfigError("trust_identity_header must be a header name")
        logins = raw.get("allowed_logins") or []
        if not isinstance(logins, list) or not all(isinstance(x, str) for x in logins):
            raise ConfigError("allowed_logins must be a list of strings")
        self.allowed_logins = [x.strip().lower() for x in logins if x.strip()]
        if not self.tokens and not self.identity_header:
            raise ConfigError("no auth configured: set tokens (or HOMELAB_TOKENS) and/or trust_identity_header")

        self.interval = float(raw.get("interval", 60))
        if self.interval < 1:
            raise ConfigError("interval must be at least 1 second")

        th = raw.get("thresholds") or {}
        self.disk_warning = float(th.get("disk_warning", 90))
        self.disk_problem = float(th.get("disk_problem", 95))
        self.temp_warning = float(th.get("temp_warning", 80))

        me = raw.get("this_host") or {}
        if not isinstance(me, dict):
            raise ConfigError("this_host must be an object")
        disks = me.get("disks", ["/"])
        if not isinstance(disks, list) or not all(isinstance(d, str) for d in disks):
            raise ConfigError("this_host.disks must be a list of mount points")
        self.this_host = {
            "id": str(me.get("id") or socket.gethostname().split(".")[0]),
            "name": me.get("name"),
            "kind": str(me.get("kind") or "server"),
            "url": me.get("url"),
            "disks": disks,
            "docker": bool(me.get("docker", False)),
            "updates": bool(me.get("updates", False)),
            "updates_interval": float(me.get("updates_interval", 6 * 3600)),
        }

        self.hosts = []
        ids = {self.this_host["id"]}
        for h in raw.get("hosts") or []:
            if not isinstance(h, dict) or not isinstance(h.get("id"), str) or not h.get("id"):
                raise ConfigError("every host needs an id")
            if h["id"] in ids:
                raise ConfigError("duplicate host id %r" % h["id"])
            ids.add(h["id"])
            if not h.get("check"):
                raise ConfigError("host %r needs a check (tcp://host:22, ping://host or https://...)" % h["id"])
            validate_target(h["check"])
            self.hosts.append({
                "id": h["id"], "name": h.get("name"), "kind": h.get("kind"), "url": h.get("url"),
                "check": h["check"], "sleeps": bool(h.get("sleeps", False)),
                "timeout": float(h.get("timeout", 5)), "insecure": bool(h.get("insecure", False)),
            })

        self.checks = []
        names = set()
        for c in raw.get("checks") or []:
            if not isinstance(c, dict) or not isinstance(c.get("name"), str) or not c.get("name"):
                raise ConfigError("every check needs a name")
            if c["name"] in names:
                raise ConfigError("duplicate check name %r" % c["name"])
            names.add(c["name"])
            validate_target(c.get("url"))
            expect = c.get("expect", 200)
            expect = expect if isinstance(expect, list) else [expect]
            if not all(isinstance(e, int) for e in expect):
                raise ConfigError("check %r: expect must be a status code or a list of them" % c["name"])
            sev = c.get("severity", "problem")
            if sev not in SEVERITIES:
                raise ConfigError("check %r: severity must be problem or warning" % c["name"])
            self.checks.append({
                "name": c["name"], "url": c["url"], "host": c.get("host"), "expect": expect, "severity": sev,
                "timeout": float(c.get("timeout", 5)), "insecure": bool(c.get("insecure", False)),
            })

        self.cards_dir = raw.get("cards_dir") or None
        self.services = []
        for s in raw.get("services") or []:
            if not isinstance(s, dict) or not isinstance(s.get("name"), str) or not isinstance(s.get("url"), str):
                raise ConfigError("every service needs name and url")
            self.services.append({k: v for k, v in s.items() if k in ("name", "url", "group", "icon", "description")})

        self.pending_dir = raw.get("pending_dir") or None
        actions = raw.get("actions") or {}
        if not isinstance(actions, dict):
            raise ConfigError("actions must be an object: name -> argv list")
        self.actions = {name: _argv(cmd, "actions.%s" % name) for name, cmd in actions.items()}
        if self.actions and not self.pending_dir:
            raise ConfigError("actions need pending_dir")
        self.action_timeout = float(raw.get("action_timeout", 110))

        self.chat_command = _argv(raw.get("chat_command"), "chat_command")
        self.chat_timeout = float(raw.get("chat_timeout", 120))
        self.state_dir = os.path.expanduser(raw.get("state_dir") or "~/.local/state/homelab-companion")

        self.button_secret = env.get("HOMELAB_BUTTON_SECRET", "").encode() or secrets.token_bytes(32)

        # Homelab Bridge sources (docs/REFERENCE_SERVER.md#sources). Without the keys `sources` and `homepage` nothing
        # below runs and the sources package is never imported.
        self.sources = []
        raw_sources = raw.get("sources") or []
        source_env = env
        if raw.get("homepage") is not None:
            # Import from Homepage (docs/SERVER-SETUP.md#import-from-homepage): its services.yaml adds launcher
            # entries and sources. Needs PyYAML; without it the start stops with a message that says so.
            from sources import _homepage  # noqa: E402
            if not isinstance(raw_sources, list):
                raise ConfigError("sources must be a list of objects")
            taken = [s.get("name") for s in raw_sources if isinstance(s, dict) and isinstance(s.get("name"), str)]
            try:
                imported = _homepage.load(raw["homepage"], env, taken, self.services, log)
            except _homepage.ImportFailed as exc:
                raise ConfigError(str(exc))
            self.services += imported.services
            raw_sources = list(raw_sources) + imported.sources
            if imported.env:
                source_env = dict(env)
                source_env.update(imported.env)
        if raw_sources:
            import sources as bridge_sources  # noqa: E402 - optional, next to this file
            try:
                self.sources = bridge_sources.parse(raw_sources, source_env)
            except ValueError as exc:
                raise ConfigError(str(exc))
            SOURCE_SECRET_ENV.update(bridge_sources.env_names(self.sources))
            if self.identity_header and not self.allowed_logins:
                # Without sources an empty list still lets every login in (as it always did); with them the server
                # holds other services' data and actions, so it names its users.
                raise ConfigError("allowed_logins is empty: with sources, list the logins that may use this server "
                                  "(your Tailscale login, e.g. you@example.com), or drop trust_identity_header and "
                                  "use tokens")

    @classmethod
    def load(cls, path, env=None):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except (OSError, ValueError) as exc:
            raise ConfigError("cannot read %s: %s" % (path, exc))
        cfg = cls(raw, env)
        try:
            if raw.get("tokens") and os.stat(path).st_mode & 0o004:
                log("config: warning: %s holds tokens and is world-readable (chmod 600 it)" % path)
        except OSError:
            pass
        return cfg


# --------------------------------------------------------------------------------------------- auth

class Auth:
    """Bearer tokens and/or an identity header from a reverse proxy on loopback."""

    def __init__(self, tokens=(), identity_header=None, allowed_logins=()):
        self.tokens = [t.encode() for t in tokens]
        self.identity_header = identity_header
        self.allowed_logins = [x.lower() for x in allowed_logins]

    @property
    def mode(self):
        if self.identity_header:
            return "identity"
        return "token" if self.tokens else "none"

    def _token_ok(self, given):
        ok = False
        for t in self.tokens:  # no early exit: same time for every token
            ok |= hmac.compare_digest(given.encode(), t)
        return ok

    def check(self, headers, peer):
        """Return None when allowed, else (status, message)."""
        if not self.tokens and not self.identity_header:
            return None
        if self.identity_header and is_loopback(peer):
            login = (headers.get(self.identity_header) or "").strip().lower()
            if login and (not self.allowed_logins or login in self.allowed_logins):
                return None
            denied_login = bool(login)
        else:
            denied_login = False
        auth = headers.get("Authorization") or ""
        if auth:
            scheme, _, given = auth.partition(" ")
            if scheme.lower() == "bearer" and self.tokens and self._token_ok(given.strip()):
                return None
            return 403, "forbidden"
        if denied_login:
            # The login isn't a secret, and it is the one thing needed to fix allowed_logins.
            log("refused login %r: not in allowed_logins" % login[:120])
            return 403, "login not allowed"
        return 401, "unauthorized"


# --------------------------------------------------------------------------------------------- health

class Collector:
    """Collects host data and runs checks in a background thread. /state reads the last snapshot."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.since = {}
        self.updates_cache = (0.0, None)
        self.runs = 0
        self.snapshot = {"checked": None, "problems": [], "hosts": self._initial_hosts()}
        self.thread = None

    def _initial_hosts(self):
        hosts = [self._base(self.cfg.this_host)]
        hosts += [self._base(h) for h in self.cfg.hosts]
        return hosts

    @staticmethod
    def _base(h):
        out = {"id": h["id"], "name": h.get("name") or h["id"]}
        if h.get("kind"):
            out["kind"] = h["kind"]
        if h.get("url"):
            out["url"] = h["url"]
        return out

    def start(self):
        self.thread = threading.Thread(target=self._loop, name="collector", daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()

    def _loop(self):
        while not self.stop_event.is_set():
            try:
                self.run_once()
            except Exception:  # noqa: BLE001
                log("collector error:\n" + traceback.format_exc())
            self.stop_event.wait(self.cfg.interval)

    def get(self):
        with self.lock:
            return self.snapshot

    # one round ------------------------------------------------------------------------------
    def run_once(self):
        problems = []
        hosts = [self._local(problems)]
        cfg = self.cfg
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
            hf = [(h, ex.submit(probe, h["check"], h["timeout"], None, h["insecure"])) for h in cfg.hosts]
            cf = [(c, ex.submit(probe, c["url"], c["timeout"], c["expect"], c["insecure"])) for c in cfg.checks]
            for h, fut in hf:
                ok, detail = fut.result()
                host = self._base(h)
                host.update({"reachable": ok, "checked": now_iso(), "flags": []})
                if not ok and h["sleeps"] and detail.startswith(RESOLVE_FAILED):
                    host["flags"].append("asleep")
                    problems.append({"id": "host-%s-dns" % h["id"], "host": h["id"], "severity": "warning",
                                     "text": "%s: %s on this server, so it can't tell asleep from gone. "
                                             "Use its 100.x address in the check." % (host["name"], detail)})
                elif not ok and h["sleeps"]:
                    host["flags"].append("asleep")
                elif not ok:
                    problems.append({"id": "host-%s" % h["id"], "host": h["id"], "severity": "problem",
                                     "text": "%s: not reachable (%s)" % (host["name"], detail)})
                hosts.append(host)
            for c, fut in cf:
                ok, detail = fut.result()
                if not ok:
                    p = {"id": "check-%s" % c["name"], "severity": c["severity"],
                         "text": "%s: %s" % (c["name"], detail)}
                    if c["host"]:
                        p["host"] = c["host"]
                    problems.append(p)
        stamp = now_iso()
        since = {}
        for p in problems:
            since[p["id"]] = self.since.get(p["id"], stamp)
            p["since"] = since[p["id"]]
        self.since = since
        with self.lock:
            self.snapshot = {"checked": stamp, "problems": problems, "hosts": hosts}
            self.runs += 1

    def _local(self, problems):
        me = self.cfg.this_host
        hid = me["id"]
        host = self._base(me)
        host.update({"reachable": True, "checked": now_iso(), "flags": []})
        try:
            host["load"] = round(os.getloadavg()[0], 2)
        except (OSError, AttributeError):
            pass
        if os.cpu_count():
            host["cpu_count"] = os.cpu_count()
        mem = self._mem_pct()
        if mem is not None:
            host["mem_pct"] = mem
        temp = self._temp()
        if temp is not None:
            host["temp"] = temp
            if temp >= self.cfg.temp_warning:
                problems.append({"id": "temp-%s" % hid, "host": hid, "severity": "warning",
                                 "text": "%s: temperature %.0f °C" % (host["name"], temp)})
        disks = {}
        for mount in me["disks"]:
            # An encrypted volume that isn't unlocked yet is an empty folder on the root disk: its usage would
            # look real but be the root's. Anything but "/" must be a mount point.
            if mount != "/" and os.path.isdir(mount) and not os.path.ismount(mount):
                problems.append({"id": "disk-%s-%s" % (hid, mount), "host": hid, "severity": "warning",
                                 "text": "%s: %s is not mounted (locked or not unlocked yet?)" % (host["name"], mount)})
                continue
            try:
                du = shutil.disk_usage(mount)
            except OSError:
                problems.append({"id": "disk-%s-%s" % (hid, mount), "host": hid, "severity": "warning",
                                 "text": "%s: disk %s not found" % (host["name"], mount)})
                continue
            pct = int(round(du.used * 100.0 / max(1, du.used + du.free)))
            disks[mount] = pct
            sev = "problem" if pct >= self.cfg.disk_problem else "warning" if pct >= self.cfg.disk_warning else None
            if sev:
                problems.append({"id": "disk-%s-%s" % (hid, mount), "host": hid, "severity": sev,
                                 "text": "%s: disk %s at %d%%" % (host["name"], mount, pct)})
        if disks:
            host["disks"] = disks
        if me["docker"]:
            self._docker(host, problems)
        updates = {}
        if os.path.exists("/proc"):
            updates["reboot_required"] = os.path.exists("/var/run/reboot-required")
        if me["updates"]:
            n = self._upgradable()
            if n is not None:
                updates["upgradable"] = n
        if updates:
            host["updates"] = updates
        return host

    @staticmethod
    def _mem_pct():
        try:
            info = {}
            with open("/proc/meminfo", "r") as fh:
                for line in fh:
                    key, _, rest = line.partition(":")
                    info[key] = int(rest.split()[0])
            total, avail = info["MemTotal"], info.get("MemAvailable", info.get("MemFree"))
            return max(0, min(100, int(round((total - avail) * 100.0 / total))))
        except (OSError, KeyError, ValueError, IndexError, ZeroDivisionError):
            return None

    @staticmethod
    def _temp():
        best = None
        for path in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
            try:
                with open(path, "r") as fh:
                    val = int(fh.read().strip()) / 1000.0
            except (OSError, ValueError):
                continue
            if -40 < val < 150 and (best is None or val > best):
                best = val
        return round(best, 1) if best is not None else None

    def _docker(self, host, problems):
        hid = host["id"]
        try:
            res = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}"],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as exc:
            problems.append({"id": "docker-%s" % hid, "host": hid, "severity": "warning",
                             "text": "%s: docker ps failed (%s)" % (host["name"], short_error(exc))})
            return
        if res.returncode != 0:
            problems.append({"id": "docker-%s" % hid, "host": hid, "severity": "warning",
                             "text": "%s: docker ps failed (exit %d)" % (host["name"], res.returncode)})
            return
        up = total = 0
        for line in res.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            name, state, status = parts[0], parts[1].lower(), parts[2].lower()
            total += 1
            if state == "running":
                up += 1
            if "unhealthy" in status or state == "restarting":
                problems.append({"id": "container-%s-%s" % (hid, name), "host": hid, "severity": "problem",
                                 "text": "%s: container %s is %s" % (
                                     host["name"], name, "unhealthy" if "unhealthy" in status else state)})
        host["containers"] = {"up": up, "total": total}

    def _upgradable(self):
        stamp, value = self.updates_cache
        if value is not None and time.time() - stamp < self.cfg.this_host["updates_interval"]:
            return value
        if not shutil.which("apt"):
            return None
        try:
            res = subprocess.run(["apt", "list", "--upgradable"], stdin=subprocess.DEVNULL, capture_output=True,
                                 text=True, timeout=60, env=child_env({"LANG": "C"}))
        except (OSError, subprocess.TimeoutExpired):
            return value
        count = sum(1 for line in res.stdout.splitlines() if "/" in line and "[upgradable" in line)
        self.updates_cache = (time.time(), count)
        return count


# --------------------------------------------------------------------------------------------- cards

def load_cards(cards_dir):
    cards = []
    if not cards_dir or not os.path.isdir(cards_dir):
        return cards
    for path in sorted(glob.glob(os.path.join(cards_dir, "*.json")))[:MAX_CARDS]:
        try:
            card = read_json_file(path)
        except (OSError, ValueError) as exc:
            warn_once(path, "cards: skipped %s (%s)" % (os.path.basename(path), short_error(exc)))
            continue
        if not isinstance(card, dict) or not isinstance(card.get("id"), str) or not card["id"]:
            warn_once(path, "cards: skipped %s (needs an object with a string id)" % os.path.basename(path))
            continue
        if "items" in card:
            if isinstance(card["items"], list):
                card["items"] = [i for i in card["items"] if isinstance(i, dict)]
            else:
                del card["items"]
        if "updated" not in card:
            try:
                card["updated"] = datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone().isoformat(
                    timespec="seconds")
            except OSError:
                pass
        cards.append(card)
    return cards


# --------------------------------------------------------------------------------------------- actions

class Actions:
    """Pending actions from files, HMAC-signed buttons, and whitelisted argv commands."""

    def __init__(self, pending_dir, commands, secret, timeout=110.0):
        self.pending_dir = pending_dir
        self.commands = commands or {}
        self.secret = secret
        self.timeout = timeout
        self.lock = threading.Lock()
        self.running = set()

    @staticmethod
    def digest(data):
        """What the user saw: a button only works for exactly this action, arg and creation time.
        A new pending file that reuses an id gets new buttons, and old ones stop working."""
        seen = {k: data.get(k) for k in ("action", "arg", "created")}
        return hashlib.sha256(json.dumps(seen, sort_keys=True).encode()).hexdigest()

    def sign(self, verb, pid, data):
        msg = "%s:%s:%s" % (verb, pid, self.digest(data))
        return hmac.new(self.secret, msg.encode(), hashlib.sha256).hexdigest()[:16]

    def button(self, verb, pid, data):
        return "HOMELAB_%s_%s_%s" % (verb, pid, self.sign(verb, pid, data))

    def _scan(self):
        """Return {id: (path, data)}."""
        found = {}
        if not self.pending_dir or not os.path.isdir(self.pending_dir):
            return found
        for path in sorted(glob.glob(os.path.join(self.pending_dir, "*.json")))[:MAX_PENDING]:
            try:
                data = read_json_file(path)
            except (OSError, ValueError) as exc:
                warn_once(path, "pending: skipped %s (%s)" % (os.path.basename(path), short_error(exc)))
                continue
            if not isinstance(data, dict):
                continue
            pid = str(data.get("id") or os.path.splitext(os.path.basename(path))[0])
            if not PENDING_ID_RE.fullmatch(pid) or pid in found:
                warn_once(path, "pending: skipped %s (id must be 1-32 of A-Z a-z 0-9 -, unique)" %
                          os.path.basename(path))
                continue
            data["id"] = pid
            if "created" not in data:
                try:
                    data["created"] = datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone() \
                        .isoformat(timespec="seconds")
                except OSError:
                    pass
            found[pid] = (path, data)
        return found

    def _runnable(self, data):
        arg = data.get("arg") or ""
        return data.get("action") in self.commands and isinstance(arg, str) and (arg == "" or ARG_RE.fullmatch(arg))

    def pending(self):
        out = []
        for pid, (_, data) in self._scan().items():
            item = {k: data[k] for k in ("id", "job", "action", "arg", "reason", "created") if k in data}
            buttons = {}
            if self._runnable(data):
                buttons["approve"] = self.button("APPROVE", pid, data)
                if data.get("offer_always"):
                    buttons["always"] = self.button("ALWAYS", pid, data)
            buttons["deny"] = self.button("DENY", pid, data)
            item["buttons"] = buttons
            out.append(item)
        out.sort(key=lambda p: str(p.get("created", "")))
        return out

    @staticmethod
    def build_argv(template, arg):
        words = arg.split(" ") if arg else []
        argv = []
        for item in template:
            if item == "{arg}":
                argv.extend(words)
            else:
                argv.append(item)
        return argv

    def press(self, action):
        m = BUTTON_RE.fullmatch(action or "")
        if not m:
            return 403, {"error": "unknown button"}
        verb, pid, sig = m.groups()
        entry = self._scan().get(pid)
        if not entry:
            return 403, {"error": "unknown or expired action"}
        path, data = entry
        if not hmac.compare_digest(sig, self.sign(verb, pid, data)):
            return 403, {"error": "forged or outdated button"}
        if verb == "DENY":
            self._remove(path)
            log("action %s denied" % pid)
            return 200, {"text": "denied %s" % pid}
        if verb == "ALWAYS" and not data.get("offer_always"):
            return 403, {"error": "always is not offered for this action"}
        name = data.get("action")
        template = self.commands.get(name)
        if template is None:
            return 403, {"error": "action %r is not configured" % name}
        arg = data.get("arg") or ""
        if not isinstance(arg, str) or (arg and not ARG_RE.fullmatch(arg)):
            return 400, {"error": "bad arg", "text": "refused %s: the arg is not allowed" % pid}
        # Claim the pending file under the lock: whoever renames it first runs the command, an
        # overlapping press (double tap, app plus notification button) finds it gone.
        claimed = path + ".running"
        with self.lock:
            if pid in self.running:
                return 200, {"text": "%s is already running" % pid}
            try:
                os.rename(path, claimed)
            except OSError:
                return 403, {"error": "unknown or expired action"}
            self.running.add(pid)
        path = claimed
        try:
            argv = self.build_argv(template, arg)
            env = child_env({"HOMELAB_PENDING_ID": pid, "HOMELAB_ACTION": name, "HOMELAB_ARG": arg})
            try:
                res = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, timeout=self.timeout, env=env)
                out = res.stdout.decode("utf-8", "replace").strip()
                result = "exit %d" % res.returncode
            except subprocess.TimeoutExpired:
                out, result = "", "timed out after %d s" % self.timeout
            except OSError as exc:
                out, result = "", "could not start (%s)" % short_error(exc)
            log("action %s %s: %s" % (pid, name, result))
        finally:
            self._remove(path)
            with self.lock:
                self.running.discard(pid)
        if len(out) > 2000:
            out = out[:2000] + "…"
        label = "approved" if verb == "APPROVE" else "approved (always)"
        text = "%s %s: %s %s → %s" % (label, pid, name, arg, result)
        return 200, {"text": text + ("\n" + out if out else "")}

    @staticmethod
    def _remove(path):
        try:
            os.remove(path)
        except OSError:
            pass


# --------------------------------------------------------------------------------------------- chat

class Chat:
    """Chat history in a JSONL file; each message runs chat_command with the text on stdin."""

    def __init__(self, command, state_dir, timeout=120.0):
        self.command = command
        self.timeout = timeout
        self.lock = threading.Lock()
        self.busy = False
        self.messages = []
        self.last_id = 0
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        self.path = os.path.join(state_dir, "messages.jsonl")
        self.lines_on_disk = 0
        self._load()

    def _load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                for line in fh:
                    self.lines_on_disk += 1
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(msg, dict) and isinstance(msg.get("id"), int):
                        self.messages.append(msg)
        except OSError:
            pass
        self.messages = self.messages[-KEEP_MESSAGES:]
        if self.messages:
            self.last_id = max(m["id"] for m in self.messages)

    def _append(self, msg):
        """Caller holds the lock."""
        self.messages.append(msg)
        self.messages = self.messages[-KEEP_MESSAGES:]
        if self.lines_on_disk >= 2 * KEEP_MESSAGES:
            tmp = self.path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                for m in self.messages:
                    fh.write(json.dumps(m, ensure_ascii=False) + "\n")
            os.replace(tmp, self.path)
            self.lines_on_disk = len(self.messages)
        else:
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(msg, ensure_ascii=False) + "\n")
            self.lines_on_disk += 1

    def _new(self, sender, text, job="", status=""):
        self.last_id = max(time.time_ns(), self.last_id + 1)
        return {"id": self.last_id, "ts": now_iso(), "from": sender, "job": job, "status": status, "text": text}

    def post(self, text):
        with self.lock:
            if self.busy:
                return 429, {"error": "busy, try again later"}
            msg = self._new("me", text)
            self._append(msg)
            self.busy = True
        threading.Thread(target=self._run, args=(text,), name="chat", daemon=True).start()
        return 200, {"ok": True, "id": msg["id"]}

    def _run(self, text):
        try:
            status = "OK"
            try:
                res = subprocess.run(self.command, input=text.encode("utf-8"), stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, timeout=self.timeout, env=child_env())
                reply = res.stdout.decode("utf-8", "replace").strip() or "(no output)"
                if res.returncode != 0:
                    status = "ERROR"
                    reply = "%s\n(exit %d)" % (reply, res.returncode)
            except subprocess.TimeoutExpired:
                status, reply = "ERROR", "No answer within %d s." % self.timeout
            except OSError as exc:
                status, reply = "ERROR", "chat_command could not start (%s)" % short_error(exc)
            if len(reply) > 20000:
                reply = reply[:20000] + "…"
            with self.lock:
                self._append(self._new("agent", reply, job="chat", status=status))
        except Exception as exc:  # never leave busy stuck: every later POST would be 429
            log("chat: could not run or store the reply (%s)" % short_error(exc))
        finally:
            with self.lock:
                self.busy = False

    def page(self, after):
        with self.lock:
            msgs = [m for m in self.messages if m["id"] > after][-PAGE_MESSAGES:]
            return {"messages": msgs, "busy": ["chat"] if self.busy else []}

    def last(self):
        with self.lock:
            return self.messages[-1] if self.messages else None


# --------------------------------------------------------------------------------------------- apps

def _after(query):
    try:
        return int((query.get("after") or ["0"])[0])
    except ValueError:
        raise BadRequest("after must be an integer")


def _text(body):
    text = body.get("text")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        raise BadRequest("text must be 1-%d characters" % MAX_TEXT)
    return text


class BadRequest(Exception):
    pass


class RealApp:
    def __init__(self, cfg):
        self.cfg = cfg
        self.auth = Auth(cfg.tokens, cfg.identity_header, cfg.allowed_logins)
        self.allowed_hosts = cfg.allowed_hosts
        self.collector = Collector(cfg)
        self.actions = Actions(cfg.pending_dir, cfg.actions, cfg.button_secret, cfg.action_timeout) \
            if cfg.pending_dir else None
        self.chat = Chat(cfg.chat_command, cfg.state_dir, cfg.chat_timeout) if cfg.chat_command else None
        self.sources = None
        if cfg.sources:
            import sources as bridge_sources  # noqa: E402
            self.sources = bridge_sources.Runner(cfg.sources, logf=lambda msg: log(msg))
        self.routes = {
            "info": {"GET": self.info},
            "state": {"GET": self.state},
            "button": {"POST": self.button},
        }
        if self.chat:
            self.routes["messages"] = {"GET": self.messages, "POST": self.post_message}
        if cfg.services or self.sources:
            self.routes["services"] = {"GET": self.services}
        # Source actions (feature run-actions): only when a source's config lists items under `actions`.
        if self.sources and self.sources.actions:
            acts = self.sources.actions
            self.routes["actions"] = {"GET": lambda q, b: (200, acts.listing())}
            for name in acts.names():
                self.routes["actions/" + name] = {"POST": lambda q, b, name=name: acts.run(name, b)}

    def start(self):
        self.collector.start()
        if self.sources:
            self.sources.start()

    def stop(self):
        self.collector.stop()
        if self.sources:
            self.sources.stop()

    def control(self, query):
        return None

    def features(self):
        f = ["status", "hosts"]
        extra = self.sources.merged() if self.sources else None
        if self.actions:
            f.append("actions")
        if self.sources and self.sources.actions:
            f.append("run-actions")
        if self.chat:
            f.append("chat")
        if self.cfg.cards_dir or (extra and extra["cards"]):
            f.append("cards")
        if self.cfg.services or (extra and extra["services"]):
            f.append("services")
        return f

    def info(self, query, body):
        out = {"api": 1, "name": self.cfg.name, "server": SERVER_NAME, "version": VERSION,
               "features": self.features(), "auth": self.auth.mode}
        if self.sources:   # only with a `sources` key; without it /info stays as it was (NoSourcesGolden)
            out["sources"] = self.sources.status()
        return 200, out

    def state(self, query, body):
        snap = self.collector.get()
        problems = snap["problems"]
        hosts = snap["hosts"]
        extra = self.sources.merged() if self.sources else None
        if extra:
            problems = problems + extra["problems"]
            hosts = hosts + extra["hosts"]
        if snap["checked"] is None:
            status = "unknown"
        elif any(p.get("severity") == "problem" for p in problems):
            status = "problem"
        elif problems:
            status = "warning"
        else:
            status = "ok"
        out = {"time": now_iso(), "status": status}
        if snap["checked"]:
            out["checked"] = snap["checked"]
        out["problems"] = problems
        out["hosts"] = hosts
        out["pending"] = self.actions.pending() if self.actions else []
        out["cards"] = load_cards(self.cfg.cards_dir)
        if extra:
            out["cards"] += extra["cards"]
        out["busy"] = ["chat"] if self.chat and self.chat.busy else []
        last = self.chat.last() if self.chat else None
        if last:
            out["last_message"] = last
        return 200, out

    def button(self, query, body):
        action = body.get("action")
        if not isinstance(action, str):
            raise BadRequest("action must be a string")
        if not self.actions:
            return 403, {"error": "this server has no actions"}
        return self.actions.press(action)

    def messages(self, query, body):
        return 200, self.chat.page(_after(query))

    def post_message(self, query, body):
        return self.chat.post(_text(body))

    def services(self, query, body):
        if self.sources:
            return 200, {"services": self.cfg.services + self.sources.merged()["services"]}
        return 200, {"services": self.cfg.services}


class Binary:
    """A non-JSON answer (a picture): `_send` writes it as it is."""

    def __init__(self, ctype, data):
        self.ctype, self.data = ctype, data


POSTER_RE = re.compile(r"^poster/(w154|w342)/([A-Za-z0-9]{10,40})\.(png|jpg)$")


def grey_png(seed, width=80, height=120):
    """A small grey 2:3 PNG for the fixture posters (the same seed gives the same picture)."""
    tone = 28 + sum(seed.encode()) % 24
    rows = b"".join(b"\x00" + bytes(min(tone + y * 26 // height + (7 if (x + y) // 8 % 2 == 0 else 0), 255)
                                    for x in range(width)) for y in range(height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class FixtureApp:
    """Serves the app's fixture JSON files. A mock: binds 127.0.0.1 only."""

    VERBS = {"APPROVE": "approved", "ALWAYS": "approved (always)", "DENY": "denied"}

    def __init__(self, fixtures_dir, state_file="state-problem.json", token=None, echo_delay=1.0):
        self.dir = fixtures_dir
        self.auth = Auth([token] if token else [])
        self.echo_delay = echo_delay
        self.lock = threading.Lock()
        self.info_doc = self._load("info.json")
        self.services_doc = self._load("services.json", optional=True)
        self.messages_doc = self._load("messages.json", optional=True)
        self.state_name = None
        self.state_doc = None
        self.set_state(state_file)
        self.waiting = 0
        self.messages = list(self.messages_doc.get("messages", [])) if isinstance(self.messages_doc, dict) else []
        self.routes = {
            "info": {"GET": lambda q, b: (200, self.info_doc)},
            "state": {"GET": self.state},
            "button": {"POST": self.button},
        }
        if self.messages_doc is not None:
            self.routes["messages"] = {"GET": self.get_messages, "POST": self.post_message}
        if self.services_doc is not None:
            self.routes["services"] = {"GET": lambda q, b: (200, self.services_doc)}
        # Documents (feature "documents") and shares (feature "share"): kept in memory, nothing is filed anywhere.
        self.documents = []     # {"id", "title", "bytes", "time"} per accepted PDF, newest last
        self.shares = []        # {"id", "route", "url", "title", "time", "ad_id"?}
        self._results = {}      # id -> (code, reply): a repeated id gets the first answer
        self._recent = {"documents": [], "share": []}
        self.raw_routes = {"documents"}
        self.routes["documents"] = {"POST": self.post_document}
        self.routes["share"] = {"POST": self.post_share}
        # Search (feature "search"): search.json is the whole catalogue; the query filters its titles.
        self.search_doc = self._load("search.json", optional=True)
        if self.search_doc is not None:
            self.routes["search"] = {"GET": self.search}
        # Deals (feature "deals"): deals.json is served as it is. Without the file the route is missing and /deals
        # answers 404, which is how a server says "no deals here" (the app hides the feature).
        self.deals_doc = self._load("deals.json", optional=True)
        if self.deals_doc is not None:
            self.routes["deals"] = {"GET": lambda q, b: (200, self.deals_doc)}
        # Actions the app may start (feature run-actions): actions.json, one POST route per listed name.
        self.actions_doc = self._load("actions.json", optional=True)
        if isinstance(self.actions_doc, dict):
            self.routes["actions"] = {"GET": lambda q, b: (200, self.actions_doc)}
            for a in self.actions_doc.get("actions") or []:
                if isinstance(a, dict) and re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", str(a.get("name", ""))):
                    self.routes["actions/" + a["name"]] = {"POST": lambda q, b, a=a: self.run_action(a, b)}

    def _load(self, name, optional=False):
        path = os.path.join(self.dir, name)
        if optional and not os.path.exists(path):
            return None
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    def set_state(self, name):
        if not re.match(r"^[A-Za-z0-9_.-]+\.json$", name or "") or name.startswith("."):
            raise BadRequest("state must be a file name like state-ok.json")
        if not os.path.isfile(os.path.join(self.dir, name)):
            raise BadRequest("no such fixture: %s" % name)
        doc = self._load(name)
        with self.lock:
            self.state_name, self.state_doc = name, doc

    def start(self):
        pass

    def stop(self):
        pass

    def control(self, query):
        if "reset" in query:
            with self.lock:
                self.messages = list(self.messages_doc.get("messages", [])) if self.messages_doc else []
                self.documents, self.shares, self._results = [], [], {}
                self._recent = {"documents": [], "share": []}
        if "state" in query:
            self.set_state(query["state"][0])
        return 200, {"ok": True, "state": self.state_name}

    def search(self, query, body):
        q = " ".join((query.get("q") or [""])[0].split())
        if not 2 <= len(q) <= 100 or any(ord(c) < 32 for c in q):
            raise BadRequest("q must be 2 to 100 characters")
        cards = []
        for card in self.search_doc.get("cards") or []:
            items = [i for i in card.get("items") or [] if q.lower() in str(i.get("title", "")).lower()]
            if items:
                cards.append(dict(card, items=items))
        return 200, {"query": q, "cards": cards}

    def poster(self, path):
        """GET /api/v1/poster/<size>/<file>: a generated grey picture, only for the paths the fixtures name."""
        m = POSTER_RE.match(path)
        if not m or m.group(2) + "." + m.group(3) not in self._poster_files():
            return 404, {"error": "not found"}
        return 200, Binary("image/png" if m.group(3) == "png" else "image/jpeg", grey_png(m.group(2)))

    def _poster_files(self):
        """File names the search answers name: nothing else is served (the real server does the same)."""
        files = set()
        for card in (self.search_doc or {}).get("cards") or []:
            for item in card.get("items") or []:
                if isinstance(item.get("image"), str):
                    files.add(item["image"].rsplit("/", 1)[-1])
        return files

    def state(self, query, body):
        with self.lock:
            doc = self.state_doc
            if self.waiting and isinstance(doc, dict):
                doc = dict(doc, busy=["chat"])
        return 200, doc

    def button(self, query, body):
        action = body.get("action")
        if not isinstance(action, str):
            raise BadRequest("action must be a string")
        with self.lock:
            doc = self.state_doc
        valid = set()
        if isinstance(doc, dict) and isinstance(doc.get("pending"), list):
            for p in doc["pending"]:
                if isinstance(p, dict) and isinstance(p.get("buttons"), dict):
                    valid.update(v for v in p["buttons"].values() if isinstance(v, str))
        m = BUTTON_RE.fullmatch(action)
        if action not in valid or not m:
            return 403, {"error": "unknown button"}
        return 200, {"text": "%s %s (fixture)" % (self.VERBS[m.group(1)], m.group(2))}

    def run_action(self, spec, body):
        """A mock run: checks the shape the app sends (arg text, payload of text, required fields), runs nothing."""
        # Empty, missing or null all mean "no argument" (openapi.yaml).
        arg, payload = body.get("arg") or "", body.get("payload") or {}
        if not isinstance(arg, str) or not isinstance(payload, dict) or not all(isinstance(v, str) for v in payload.values()):
            raise BadRequest("arg must be text and payload an object of texts")
        if bool(spec.get("arg")) != bool(arg.strip()):
            raise BadRequest("%s needs a choice" % spec.get("label", spec["name"]) if spec.get("arg") else "takes no choice")
        fields = {f.get("name"): f for f in spec.get("fields") or [] if isinstance(f, dict)}
        unknown = sorted(set(payload) - set(fields))
        if unknown:
            raise BadRequest("unknown payload field '%s'" % unknown[0])
        missing = [n for n, f in fields.items() if f.get("required") and not payload.get(n, "").strip()]
        if missing:
            raise BadRequest("payload is missing " + ", ".join(missing))
        text = "Done: %s %s (fixture)" % (spec["name"], arg) if arg else "Done: %s (fixture)" % spec["name"]
        with self.lock:
            shown = " · ".join([arg] + [v for v in payload.values() if v.strip()]).strip(" ·")
            label = spec.get("label", spec["name"])
            self.messages.append({"id": self._next_id(), "ts": now_iso(), "from": "me", "job": "", "status": "",
                                  "text": "%s: %s" % (label, shown) if shown else label})
            self.messages.append({"id": self._next_id(), "ts": now_iso(), "from": "agent", "job": "action",
                                  "status": "OK", "text": text})
        return 200, {"ok": True, "text": text}

    def _quota(self, kind, limit):
        """True (and counted) while fewer than `limit` requests of this kind came in the last hour."""
        now = time.time()
        recent = [t for t in self._recent[kind] if now - t < 3600]
        self._recent[kind] = recent
        if len(recent) >= limit:
            return False
        recent.append(now)
        return True

    def post_document(self, query, body):
        """POST /documents: the raw PDF (Content-Length checked by the handler, the bytes are in body["bytes"])."""
        headers, data = body["headers"], body["bytes"]
        doc_id = (headers.get("X-Homelab-Id") or "").strip()
        if not SHARE_ID_RE.fullmatch(doc_id):
            raise BadRequest("X-Homelab-Id must be a UUID")
        if not data.startswith(b"%PDF-"):
            raise BadRequest("not a PDF")
        title = urllib.parse.unquote(headers.get("X-Homelab-Title") or "", errors="replace")
        title = " ".join("".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in title).split())[:MAX_PDF_TITLE]
        with self.lock:
            if doc_id in self._results:
                return self._results[doc_id]
            if not self._quota("documents", UPLOADS_PER_HOUR):
                return 429, {"error": "too many uploads, try again later"}
            self.documents.append({"id": doc_id, "title": title, "bytes": len(data), "time": now_iso()})
            reply = (202, {"ok": True, "id": doc_id,
                           "text": "Sent to Paperless (fixture, nothing was filed). The result will be in the chat."})
            self._results[doc_id] = reply
            return reply

    def post_share(self, query, body):
        """POST /share: {id, kind: "url", url, title?}. The server decides the route; it never fetches the link."""
        share_id = body.get("id")
        if not isinstance(share_id, str) or not SHARE_ID_RE.fullmatch(share_id):
            raise BadRequest("id must be a UUID")
        if body.get("kind") != "url":
            raise BadRequest("kind must be url")
        url = body.get("url")
        if not isinstance(url, str) or len(url) > MAX_SHARE_URL:
            raise BadRequest("url must be text of at most %d characters" % MAX_SHARE_URL)
        title = body.get("title")
        if title is not None and not isinstance(title, str):
            raise BadRequest("title must be text")
        title = " ".join("".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in (title or "")).split())[:MAX_SHARE_TITLE]
        parts = urllib.parse.urlsplit(url)
        host = (parts.hostname or "").lower()
        if parts.scheme not in ("http", "https") or not host:
            raise BadRequest("only http and https links are taken")
        if parts.username or parts.password:
            raise BadRequest("links with a user name or password are refused")
        route, ad_id = "read-later", None
        if host in ("willhaben.at", "www.willhaben.at") and parts.path.startswith("/iad/"):
            m = WILLHABEN_PATH_RE.search(parts.path)
            ids = urllib.parse.parse_qs(parts.query).get("adId", [])
            if m:
                ad_id = m.group(1)
            elif ids and re.fullmatch(r"\d{6,12}", ids[0]):
                ad_id = ids[0]
            if ad_id:
                route = "willhaben"
        with self.lock:
            if share_id in self._results:
                return self._results[share_id]
            if not self._quota("share", SHARES_PER_HOUR):
                return 429, {"error": "too many shares, try again later"}
            entry = {"id": share_id, "route": route, "url": url, "title": title, "time": now_iso()}
            if ad_id:
                entry["ad_id"] = ad_id
            self.shares.append(entry)
            text = ("Price check for willhaben ad %s started (fixture, nothing ran)." % ad_id if ad_id
                    else "Saved to your read-later list (fixture).")
            reply = (200, {"ok": True, "id": share_id, "route": route, "text": text})
            self._results[share_id] = reply
            return reply

    def _next_id(self):
        last = max([m.get("id", 0) for m in self.messages if isinstance(m.get("id"), int)] or [0])
        return max(time.time_ns(), last + 1)

    def get_messages(self, query, body):
        after = _after(query)
        with self.lock:
            msgs = [m for m in self.messages if isinstance(m.get("id"), int) and m["id"] > after][-PAGE_MESSAGES:]
            return 200, {"messages": msgs, "busy": ["chat"] if self.waiting else []}

    def post_message(self, query, body):
        text = _text(body)
        with self.lock:
            msg = {"id": self._next_id(), "ts": now_iso(), "from": "me", "job": "", "status": "", "text": text}
            self.messages.append(msg)
            self.waiting += 1
        timer = threading.Timer(self.echo_delay, self._echo, args=(text,))
        timer.daemon = True
        timer.start()
        return 200, {"ok": True, "id": msg["id"]}

    def _echo(self, text):
        with self.lock:
            self.messages.append({"id": self._next_id(), "ts": now_iso(), "from": "agent", "job": "chat",
                                  "status": "OK", "text": "echo: " + text})
            self.waiting -= 1


# --------------------------------------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    timeout = 30   # a slow or silent client can't hold a thread forever
    server_version = SERVER_NAME
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_request(self, code="-", size="-"):
        # Path only: no query, no headers, no body (tokens and message text never reach the log).
        path = urllib.parse.urlsplit(self.path).path
        log("%s %s %s %s" % (self.client_address[0], self.command, path[:200], code))

    def log_message(self, fmt, *args):  # errors from http.server itself
        log("%s %s" % (self.client_address[0], (fmt % args)[:200]))

    def _send(self, code, obj):
        ctype = "application/json; charset=utf-8"
        if isinstance(obj, Binary):
            data, ctype = obj.data, obj.ctype
        else:
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")

    def _handle(self, method):
        app = self.server.app
        try:
            code, obj = self._route(app, method)
        except BadRequest as exc:
            code, obj = 400, {"error": str(exc)}
        except Exception:  # noqa: BLE001
            log("error handling %s:\n%s" % (method, traceback.format_exc()))
            code, obj = 500, {"error": "internal error"}
        if code >= 400 and method == "POST" and not getattr(self, "_body_read", True):
            self.close_connection = True  # unread body: don't reuse the connection
        self._send(code, obj)

    def _route(self, app, method):
        self._body_read = True
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        path = url.path
        if path == "/__control" and isinstance(app, FixtureApp) and method == "GET":
            return app.control(query)
        if not path.startswith(API_PREFIX):
            return 404, {"error": "not found"}
        if self.headers.get("Origin"):
            return 403, {"error": "browser requests are not allowed"}
        allowed_hosts = getattr(app, "allowed_hosts", None)
        if allowed_hosts is not None and not host_allowed(self.headers.get("Host"), allowed_hosts):
            log("refused Host %r: not in allowed_hosts" % (self.headers.get("Host") or "")[:120])
            return 403, {"error": "host not allowed (allowed_hosts in the config)"}
        denied = app.auth.check(self.headers, self.client_address[0])
        if denied:
            return denied[0], {"error": denied[1]}
        if method == "GET" and path.startswith(API_PREFIX + "poster/") and hasattr(app, "poster"):
            return app.poster(path[len(API_PREFIX):])
        route = app.routes.get(path[len(API_PREFIX):].rstrip("/"))
        if route is None:
            return 404, {"error": "not found"}
        fn = route.get(method)
        if fn is None:
            return 405, {"error": "method not allowed"}
        body = {}
        if self.headers.get("Transfer-Encoding"):
            # Chunked bodies aren't supported; reading them as empty would let the rest be parsed as a request.
            self.close_connection = True
            return 411, {"error": "send a Content-Length, not Transfer-Encoding"}
        if method == "POST" and path[len(API_PREFIX):].rstrip("/") in getattr(app, "raw_routes", ()):
            return self._raw_upload(fn)
        if method == "POST":
            self._body_read = False
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                return 415, {"error": "send application/json"}
            try:
                length = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                return 400, {"error": "bad Content-Length"}
            if length > MAX_BODY:
                return 413, {"error": "body larger than %d bytes" % MAX_BODY}
            raw = self.rfile.read(length) if length > 0 else b""
            self._body_read = True
            try:
                body = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return 400, {"error": "invalid JSON"}
            if not isinstance(body, dict):
                return 400, {"error": "body must be a JSON object"}
        return fn(query, body)


    def _raw_upload(self, fn):
        """A raw application/pdf body (POST /documents): type and Content-Length are checked before any byte is read."""
        self._body_read = False
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/pdf":
            return 415, {"error": "send application/pdf"}
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            return 411, {"error": "send a Content-Length"}
        try:
            length = int(raw_length)
        except ValueError:
            return 400, {"error": "bad Content-Length"}
        if length < 0:
            return 400, {"error": "bad Content-Length"}
        if length > MAX_UPLOAD:
            return 413, {"error": "file larger than %d MB" % (MAX_UPLOAD // (1024 * 1024))}
        data = bytearray()
        while len(data) < length:
            chunk = self.rfile.read(min(65536, length - len(data)))
            if not chunk:
                self.close_connection = True
                return 400, {"error": "body shorter than Content-Length"}
            data += chunk
        self._body_read = True
        return fn({}, {"bytes": bytes(data), "headers": self.headers})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, app):
        if ":" in addr[0]:
            self.address_family = socket.AF_INET6
        self.app = app
        super().__init__(addr, Handler)

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionError, socket.timeout)):
            return  # client went away (or a tcp:// probe just connected and closed)
        log("error from %s:\n%s" % (client_address[0], traceback.format_exc()))


def build_server(app, host, port, allow_remote=False):
    if not allow_remote and not is_loopback(host):
        raise ConfigError("refusing to listen on %s: use 127.0.0.1 behind tailscale serve, "
                          "or set \"allow_remote\": true" % host)
    return Server((host, port), app)


def serve(httpd):
    def stop(signum, frame):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    httpd.app.start()
    host, port = httpd.server_address[:2]
    log("listening on http://%s:%d (%s)" % (host if ":" not in host else "[%s]" % host, port,
                                            httpd.app.__class__.__name__))
    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        httpd.app.stop()
        httpd.server_close()
        log("stopped")


USERSPACE_RISK = ("in Tailscale's userspace mode tailscaled hands tailnet connections to this network namespace's "
                  "127.0.0.1 ports, so every device in your tailnet could reach this server on its port directly, "
                  "past `tailscale serve`, and send any login header it likes. Run the sidecar with "
                  "TS_USERSPACE=false (server/compose.yaml does), see docs/SERVER-SETUP.md#docker")


def _has_tailscale_interface(net_dev="/proc/net/dev"):
    """A tailscale0 (kernel mode) interface in this process's network namespace."""
    try:
        with open(net_dev, "r", encoding="utf-8", errors="replace") as fh:
            names = [line.split(":", 1)[0].strip() for line in fh if ":" in line]
    except OSError:
        return None
    return any(n.startswith("tailscale") for n in names)


def check_tailscale_mode(cfg, env, wait=60.0, step=2.0, net_dev="/proc/net/dev"):
    """The bridge image (HOMELAB_BRIDGE_IMAGE=1) behind a Tailscale sidecar with a trusted Tailscale-User-Login: refuse
    to start with TS_USERSPACE=true unless HOMELAB_ALLOW_USERSPACE=1 (USERSPACE_RISK), and warn loudly when no
    tailscale0 interface shows up in the shared namespace within `wait` seconds. Returns the watching thread or None;
    ConfigError to refuse."""
    header = (cfg.identity_header or "").lower()
    if env.get("HOMELAB_BRIDGE_IMAGE") != "1" or not header.startswith("tailscale-"):
        return None
    if env.get("TS_USERSPACE", "").strip().lower() in ("1", "true", "yes", "on"):
        if env.get("HOMELAB_ALLOW_USERSPACE") != "1":
            raise ConfigError("TS_USERSPACE=true with trust_identity_header: refused, " + USERSPACE_RISK +
                              ". HOMELAB_ALLOW_USERSPACE=1 starts it anyway (only with a tailnet ACL that allows "
                              "nothing but port 443 to this machine)")
        log("WARNING: TS_USERSPACE=true and HOMELAB_ALLOW_USERSPACE=1: " + USERSPACE_RISK)
        return None

    def watch():
        deadline = time.monotonic() + wait
        while True:
            found = _has_tailscale_interface(net_dev)
            if found or found is None:
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(step)
        log("WARNING: no tailscale0 interface in this network namespace %d s after the start. If the Tailscale "
            "sidecar runs in userspace mode (TS_USERSPACE=true), this server is open to your whole tailnet: %s"
            % (int(wait), USERSPACE_RISK))

    thread = threading.Thread(target=watch, name="tailscale-mode", daemon=True)
    thread.start()
    return thread


def main(argv=None):
    ap = argparse.ArgumentParser(description="Homelab Companion API v1 reference server.")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--config", help="real mode: path to config.json")
    mode.add_argument("--fixtures", help="fixture mode: directory with info.json, state-*.json, ...")
    ap.add_argument("--port", type=int, help="port (fixture mode default 8791; overrides listen in real mode)")
    ap.add_argument("--state", default="state-problem.json", help="fixture mode: state file to serve")
    ap.add_argument("--token", help="fixture mode: require this bearer token")
    ap.add_argument("--echo-delay", type=float, default=1.0, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    try:
        if args.config:
            cfg = Config.load(args.config)
            check_tailscale_mode(cfg, os.environ)
            app = RealApp(cfg)
            httpd = build_server(app, cfg.host, cfg.port if args.port is None else args.port, cfg.allow_remote)
        else:
            app = FixtureApp(args.fixtures, args.state, args.token, args.echo_delay)
            httpd = build_server(app, "127.0.0.1", 8791 if args.port is None else args.port)
    except (ConfigError, BadRequest, OSError, ValueError) as exc:
        log("error: %s" % exc)
        return 2
    serve(httpd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
