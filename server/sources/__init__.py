"""Sources of the Homelab Bridge (stdlib only, Python 3.9+).

A source reads one upstream API (Uptime Kuma, Docker, Proxmox, ...) and adds problems, hosts, cards and services to
the reference server's answers. Sources are optional: without a `sources` key in the config this package is never
imported. How to write one: docs/BRIDGE.md. The config keys: docs/REFERENCE_SERVER.md#sources.

A source is a module `server/sources/<type>.py` (a dash in the type is an underscore in the file name) with

    def collect(cfg, fetch):
        '''cfg: this source's config (a dict, defaults filled). fetch: a Fetch, the only way out.'''
        data = fetch.json("/api/status", headers={"X-Api-Key": fetch.secret()})
        return {"problems": [...], "hosts": [...], "cards": [...], "services": [...]}   # every key optional

    def check(cfg):                    # optional: raise ValueError("...") for a bad config, checked at start
        ...

The Runner here runs every source on its own `every`, each run in its own thread, and merges the last result of each
into /state and /services (`merged()`). Rules it enforces, whatever the module returns:
  - ids get the prefix "<source name>:"; a problem's `host` too (dropped unless the source sent that host)
  - a failing, crashing or hanging source is exactly one warning problem "<name>: <short error>", nothing else
  - no actions: `action` on cards and items and `restartable` on containers are removed (bridge actions come later,
    off by default, per item)
  - the card ids `today` and `departures` are refused (the app gives those ids a meaning)
  - secrets: config names env variables (`key_env`, any `*_env`), never the key itself; their values are replaced by
    "***" in everything the source returns and in every error; fields named like a secret are dropped
  - at most 100 problems, 100 hosts, 50 cards and 100 services per source; history series at most 288 points
"""

import copy
import http.client
import datetime
import hashlib
import importlib
import json
import os
import re
import socket
import ssl
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_EVERY = 60.0
DEFAULT_TIMEOUT = 10.0
MAX_FETCH = 8 * 1024 * 1024
MAX_PROBLEMS = 100
MAX_HOSTS = 100
MAX_CARDS = 50
MAX_SERVICES = 100
MAX_HISTORY = 288
MAX_ERROR = 120
MIN_SCRUB = 4   # secrets shorter than this can't be told apart from ordinary text; the config check warns

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$")
TYPE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
# A key in the config that would hold a secret itself. Secrets go in env variables, named with `key_env` (or `*_env`).
SECRET_CONFIG_KEY = re.compile(r"(?i)(^|_)(key|api_?key|apikey|token|password|passwd|pass|secret)$")
# Fields never sent to the app (the same list scripts/check-live-api flags).
SECRET_FIELD = re.compile(r"(?i)^(token|secret|password|passwd|api_?key|access_?token|auth_?token|client_secret)$")
SECRET_QUERY = re.compile(r"(?i)(^|[&;])[^=&;]*(key|token|password|passwd|secret|auth)[^=&;]*=")
RESERVED_CARD_IDS = ("today", "departures")
RESERVED_ENV = ("HOMELAB_TOKENS", "HOMELAB_BUTTON_SECRET")
SEVERITIES = ("problem", "warning")
COMMON_KEYS = ("name", "type", "url", "every", "timeout", "insecure", "ca_file")

_URL_RE = re.compile(r"[a-z][a-z0-9+.-]*://\S+", re.I)
_NO_PROXY = urllib.request.ProxyHandler({})

# Types registered by code instead of a file (tests). type -> module-like object with collect().
_TYPES = {}


class SourceError(Exception):
    """A failure with a short text for the warning ("401", "timeout", "KUMA_KEY is not set")."""


# --------------------------------------------------------------------------------------------- small helpers

def as_list(value):
    """Upstream JSON read leniently: a list, else []."""
    return value if isinstance(value, list) else []


def as_dict(value):
    """Upstream JSON read leniently: a dict, else {}."""
    return value if isinstance(value, dict) else {}


def as_text(value, default=""):
    """A string for display: str as it is, numbers as text, anything else the default."""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    return default


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def short_error(exc):
    """A short text for an exception, without URLs."""
    if isinstance(exc, SourceError):
        text = str(exc)
    elif isinstance(exc, urllib.error.HTTPError):
        text = str(exc.code)
    elif isinstance(exc, urllib.error.URLError):
        reason = exc.reason
        text = short_error(reason) if isinstance(reason, BaseException) else str(reason)
    elif isinstance(exc, (socket.timeout, TimeoutError)):
        text = "timeout"
    elif isinstance(exc, ConnectionRefusedError):
        text = "connection refused"
    elif isinstance(exc, socket.gaierror):
        text = "name not found"
    elif isinstance(exc, ssl.SSLCertVerificationError):
        text = "TLS certificate not trusted (set ca_file, or insecure: true)"
    elif isinstance(exc, ssl.SSLError):
        text = "TLS error: %s" % (getattr(exc, "reason", None) or exc)
    else:
        detail = str(exc)
        text = "%s: %s" % (exc.__class__.__name__, detail) if detail else exc.__class__.__name__
    return text


def scrub(text, secrets):
    """Secrets become ***, URLs <url>, one line, at most MAX_ERROR characters."""
    text = str(text)
    for s in secrets:
        if len(s) >= MIN_SCRUB:
            text = text.replace(s, "***")
    text = _URL_RE.sub("<url>", text)
    text = " ".join(text.split())
    return text[:MAX_ERROR] or "error"


# --------------------------------------------------------------------------------------------- config

def module_name(kind):
    return kind.replace("-", "_")


def known_types():
    here = os.path.dirname(os.path.abspath(__file__))
    found = set(_TYPES)
    for fn in os.listdir(here):
        if fn.endswith(".py") and not fn.startswith("_"):
            found.add(fn[:-3].replace("_", "-"))
    return sorted(found)


def load_type(kind):
    """The module of a source type, or ValueError."""
    if kind in _TYPES:
        return _TYPES[kind]
    if not isinstance(kind, str) or not TYPE_RE.fullmatch(kind):
        raise ValueError("type must be lower-case letters, digits and -, got %r" % (kind,))
    here = os.path.dirname(os.path.abspath(__file__))
    if not os.path.isfile(os.path.join(here, module_name(kind) + ".py")):
        raise ValueError("unknown type %r (known: %s)" % (kind, ", ".join(known_types()) or "none"))
    mod = importlib.import_module("." + module_name(kind), __name__)
    if not callable(getattr(mod, "collect", None)):
        raise ValueError("type %r has no collect(cfg, fetch)" % kind)
    return mod


def register(kind, module):
    """Register a source type from code (tests). module needs collect(cfg, fetch); check(cfg) is optional."""
    _TYPES[kind] = module


def _strip_comments(obj):
    if isinstance(obj, dict):
        return {k: _strip_comments(v) for k, v in obj.items() if not str(k).startswith("_")}
    if isinstance(obj, list):
        return [_strip_comments(v) for v in obj]
    return obj


def _number(value, key, minimum):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < minimum:
        raise ValueError("%s must be a number of seconds, at least %g" % (key, minimum))
    return float(value)


def _check_secret_keys(obj, where):
    """No key in a source's config may hold a secret; recurse into nested objects."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if SECRET_CONFIG_KEY.search(str(k)) and not str(k).endswith("_env"):
                raise ValueError("%s.%s looks like a secret: put it in an env variable and name that variable with "
                                 "key_env (or %s_env)" % (where, k, k))
            _check_secret_keys(v, "%s.%s" % (where, k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _check_secret_keys(v, "%s[%d]" % (where, i))


def parse(raw, env):
    """Check the `sources` list of the config. Returns a list of specs; raises ValueError with a readable text.

    A spec: {"name", "type", "every", "timeout", "cfg" (the dict collect() gets), "module", "env" ({VAR: value} of
    the variables its *_env keys name, and nothing else)}."""
    if not isinstance(raw, list):
        raise ValueError("sources must be a list of objects")
    specs, names = [], set()
    for i, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ValueError("sources[%d] must be an object" % i)
        item = _strip_comments(item)
        name = item.get("name")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise ValueError("sources[%d]: name must be 1-40 of A-Z a-z 0-9 space _ . - (it prefixes the ids), "
                             "got %r" % (i, name))
        if name.lower() in names:
            raise ValueError("sources: duplicate name %r" % name)
        names.add(name.lower())
        where = "sources[%s]" % name
        try:
            module = load_type(item.get("type"))
        except ValueError as exc:
            raise ValueError("%s: %s" % (where, exc))
        _check_secret_keys(item, where)
        cfg = copy.deepcopy(item)
        cfg["every"] = _number(item.get("every", DEFAULT_EVERY), where + ".every", 1)
        cfg["timeout"] = _number(item.get("timeout", DEFAULT_TIMEOUT), where + ".timeout", 0.1)
        if not isinstance(item.get("insecure", False), bool):
            raise ValueError("%s.insecure must be true or false" % where)
        cfg["insecure"] = item.get("insecure", False)
        url = item.get("url")
        if url is not None:
            u = urllib.parse.urlsplit(url) if isinstance(url, str) else None
            if u is None or u.scheme not in ("http", "https") or not u.hostname:
                raise ValueError("%s.url must be an http:// or https:// URL" % where)
            if u.username or u.password:
                raise ValueError("%s.url must not hold a user or password: use key_env" % where)
            if SECRET_QUERY.search(u.query):
                raise ValueError("%s.url must not hold a key in its query: use key_env" % where)
        ca_file = item.get("ca_file")
        if ca_file is not None:
            if not isinstance(ca_file, str) or not os.path.isfile(os.path.expanduser(ca_file)):
                raise ValueError("%s.ca_file must be a readable PEM file" % where)
            cfg["ca_file"] = os.path.expanduser(ca_file)
        values = {}
        for key, var in item.items():
            if not str(key).endswith("_env"):
                continue
            if not isinstance(var, str) or not ENV_NAME_RE.fullmatch(var):
                raise ValueError("%s.%s must name an env variable (A-Z, 0-9, _)" % (where, key))
            if var in RESERVED_ENV:
                raise ValueError("%s.%s: %s is the server's own secret" % (where, key, var))
            values[var] = env.get(var, "")
        check = getattr(module, "check", None)
        if callable(check):
            try:
                check(copy.deepcopy(cfg))
            except ValueError as exc:
                raise ValueError("%s: %s" % (where, exc))
        specs.append({"name": name, "type": item["type"], "every": cfg["every"], "timeout": cfg["timeout"],
                      "cfg": cfg, "module": module, "env": values})
    return specs


def env_names(specs):
    """Every env variable a source reads (the server keeps them from the commands it runs)."""
    return {var for s in specs for var in s["env"]}


# --------------------------------------------------------------------------------------------- fetch

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None   # urllib then raises HTTPError with the 3xx code


class Reply:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers   # lower-case names
        self.body = body

    @property
    def text(self):
        return self.body.decode("utf-8", "replace")

    def json(self):
        try:
            return json.loads(self.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise SourceError("answer is not JSON")


def ssl_context(cfg):
    """TLS for one source: system CAs, or `ca_file`, or no checks at all with `insecure: true`."""
    if cfg.get("insecure"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if cfg.get("ca_file"):
        return ssl.create_default_context(cafile=cfg["ca_file"])
    return ssl.create_default_context()


class Fetch:
    """The only way a source talks to its upstream. GET (or another method) with a timeout, at most 8 MB, no
    redirects, no cookies, no proxy from the environment. Secrets only through secret(), from the env variables the
    config names. A path ("/api/x") is joined to the source's `url`."""

    def __init__(self, cfg, env, deadline=None):
        self.cfg = cfg
        self._env = env
        self.deadline = deadline
        self.limit = MAX_FETCH
        self._opener = urllib.request.build_opener(_NO_PROXY, _NoRedirect(),
                                                   urllib.request.HTTPSHandler(context=ssl_context(cfg)))

    def secret(self, key="key_env"):
        """The value of the env variable that cfg[key] names. SourceError when the config or the env lacks it."""
        var = self.cfg.get(key)
        if not var:
            raise SourceError("%s is missing in the config" % key)
        value = self._env.get(var, "")
        if not value:
            raise SourceError("%s is not set" % var)
        return value

    def url(self, path):
        if re.match(r"^https?://", path, re.I):
            return path
        base = self.cfg.get("url")
        if not base:
            raise SourceError("url is missing in the config")
        if not path.startswith("/"):
            path = "/" + path
        return base.rstrip("/") + path

    def __call__(self, path, method="GET", headers=None, body=None, ok=range(200, 300), timeout=None):
        """A Reply. `body`: bytes, or a dict/list sent as JSON. A status outside `ok` raises SourceError("401");
        ok=None takes any status."""
        timeout = float(timeout or self.cfg.get("timeout") or DEFAULT_TIMEOUT)
        if self.deadline is not None:
            left = self.deadline - time.monotonic()
            if left <= 0:
                raise SourceError("timeout")
            timeout = min(timeout, left)
        h = {"User-Agent": "homelab-bridge/1", "Accept": "application/json"}
        h.update(headers or {})
        data = body
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode("utf-8")
            h.setdefault("Content-Type", "application/json")
        req = urllib.request.Request(self.url(path), data=data, method=method, headers=h)
        try:
            resp = self._opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as exc:
            resp = exc
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as exc:
            raise SourceError(short_error(exc))
        try:
            status = resp.status if hasattr(resp, "status") and resp.status else resp.code
            length = resp.headers.get("Content-Length")
            if length and length.isdigit() and int(length) > self.limit:
                raise SourceError("answer larger than %d MB" % (self.limit // (1024 * 1024)))
            try:
                raw = resp.read(self.limit + 1)
            except (http.client.HTTPException, OSError, ValueError) as exc:
                raise SourceError(short_error(exc))
            if len(raw) > self.limit:
                raise SourceError("answer larger than %d MB" % (self.limit // (1024 * 1024)))
            reply = Reply(status, {k.lower(): v for k, v in resp.headers.items()}, raw)
        finally:
            resp.close()
        if ok is not None and status not in ok:
            raise SourceError(str(status))
        return reply

    def json(self, path, **kw):
        """fetch(path, **kw).json()"""
        return self(path, **kw).json()


# --------------------------------------------------------------------------------------------- merge

def _clean(obj, secrets):
    """Drop secret-named fields at any depth; secret values in any string become ***."""
    if isinstance(obj, dict):
        return {_clean(k, secrets): _clean(v, secrets) for k, v in obj.items() if not SECRET_FIELD.match(str(k))}
    if isinstance(obj, list):
        return [_clean(v, secrets) for v in obj]
    if isinstance(obj, str):
        for s in secrets:
            if len(s) >= MIN_SCRUB and s in obj:
                obj = obj.replace(s, "***")
    return obj


def _pick(items, limit, valid, kind, name, logf):
    out, ids = [], set()
    for item in as_list(items):
        if not valid(item):
            logf("source %s: skipped a %s (%s)" % (name, kind, json.dumps(item, default=str)[:80]))
            continue
        key = item.get("id") if isinstance(item, dict) else None
        if key is not None:
            if key in ids:
                continue
            ids.add(key)
        out.append(item)
        if len(out) >= limit:
            break
    return out


def _no_actions(card):
    card.pop("action", None)
    for item in card.get("items", []):
        item.pop("action", None)
    return card


def normalize(name, result, secrets=(), checked=None, logf=lambda m: None):
    """A source's raw result → {"problems", "hosts", "cards", "services"} as the app may see it (rules in the
    module docstring). Raises SourceError when the result is not a JSON object."""
    if not isinstance(result, dict):
        raise SourceError("collect() returned %s, not a dict" % type(result).__name__)
    try:
        result = json.loads(json.dumps(result, allow_nan=False))
    except (TypeError, ValueError) as exc:
        raise SourceError("result is not JSON (%s)" % exc)
    result = _clean(result, secrets)
    prefix = name + ":"

    def has_id(x):
        return isinstance(x, dict) and isinstance(x.get("id"), str) and x["id"] != ""

    hosts = []
    for h in _pick(result.get("hosts"), MAX_HOSTS, has_id, "host", name, logf):
        h = dict(h)
        h.setdefault("name", h["id"])
        h["id"] = prefix + h["id"]
        hist = h.get("history")
        if isinstance(hist, dict):
            for k, v in hist.items():
                if isinstance(v, list) and len(v) > MAX_HISTORY:
                    hist[k] = v[-MAX_HISTORY:]
        if isinstance(h.get("container_list"), list):
            h["container_list"] = [c for c in h["container_list"] if isinstance(c, dict)]
            for c in h["container_list"]:
                c.pop("restartable", None)
        hosts.append(h)
    host_ids = {h["id"] for h in hosts}

    problems, seen = [], set()
    for p in as_list(result.get("problems")):
        if isinstance(p, str):
            p = {"text": p}
        if not isinstance(p, dict) or not isinstance(p.get("text"), str) or not p["text"].strip():
            logf("source %s: skipped a problem without text" % name)
            continue
        raw_id = p.get("id") if isinstance(p.get("id"), str) and p.get("id") else \
            hashlib.sha256(p["text"].encode("utf-8")).hexdigest()[:10]
        pid = prefix + raw_id
        if pid in seen:
            continue
        seen.add(pid)
        out = {"id": pid, "severity": p.get("severity") if p.get("severity") in SEVERITIES else
               ("problem" if p.get("severity") is None else "warning"), "text": p["text"]}
        if isinstance(p.get("host"), str) and prefix + p["host"] in host_ids:
            out["host"] = prefix + p["host"]
        problems.append(out)
        if len(problems) >= MAX_PROBLEMS:
            break

    cards = []
    for c in _pick(result.get("cards"), MAX_CARDS, has_id, "card", name, logf):
        if c["id"] in RESERVED_CARD_IDS:
            logf("source %s: card id %r is reserved, skipped" % (name, c["id"]))
            continue
        c = dict(c)
        c["id"] = prefix + c["id"]
        if "items" in c:
            if isinstance(c["items"], list):
                c["items"] = [i for i in c["items"] if isinstance(i, dict)]
            else:
                del c["items"]
        if checked and "updated" not in c:
            c["updated"] = checked
        cards.append(_no_actions(c))

    services = []
    for s in _pick(result.get("services"), MAX_SERVICES,
                   lambda x: isinstance(x, dict) and isinstance(x.get("name"), str) and x["name"]
                   and isinstance(x.get("url"), str) and x["url"], "service", name, logf):
        s = {k: v for k, v in s.items() if k in ("name", "url", "group", "icon", "description")}
        s.setdefault("group", name)
        services.append(s)
    return {"problems": problems, "hosts": hosts, "cards": cards, "services": services}


# --------------------------------------------------------------------------------------------- runner

class _State:
    def __init__(self):
        self.result = None       # normalized contribution of the last good run
        self.error = None        # short text of the last failed run
        self.checked = None      # ISO time of the last finished run
        self.running_since = None
        self.next_due = 0.0
        self.since = {}          # problem id -> since
        self.runs = 0
        self.logged = None       # the last error written to the log (each new one is logged once)


class Runner:
    """Runs every source on its own `every`, apart from the host checks. Each run gets its own daemon thread (at most
    one per source at a time, so a hung upstream blocks neither the others, the host checks nor a shutdown). A run
    may take `every` seconds (each request at most `timeout`); one that is still going `timeout` seconds after that
    counts as failed ("timeout") until it ends. merged() is what /state adds."""

    def __init__(self, specs, logf=lambda m: None, tick=0.25):
        self.specs = specs
        self.log = logf
        self.tick_seconds = tick
        self.secrets = sorted({v for s in specs for v in s["env"].values() if v}, key=len, reverse=True)
        self.states = {s["name"]: _State() for s in specs}
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = None
        for s in specs:
            for var, value in s["env"].items():
                if not value:
                    logf("source %s: env %s is not set" % (s["name"], var))
                elif len(value) < MIN_SCRUB:
                    logf("source %s: env %s is shorter than %d characters" % (s["name"], var, MIN_SCRUB))
            if s["cfg"].get("insecure"):
                logf("source %s: warning: insecure: true, TLS certificates are not checked" % s["name"])

    def start(self):
        self.thread = threading.Thread(target=self._loop, name="sources", daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()

    def _loop(self):
        while not self.stop_event.is_set():
            try:
                self.tick()
            except Exception:  # noqa: BLE001
                self.log("sources error:\n" + self._scrub_log(traceback.format_exc()))
            self.stop_event.wait(self.tick_seconds)

    def _scrub_log(self, text):
        for s in self.secrets:
            if len(s) >= MIN_SCRUB:
                text = text.replace(s, "***")
        return text

    def tick(self):
        """Start every source that is due and not running."""
        now = time.monotonic()
        for spec in self.specs:
            st = self.states[spec["name"]]
            with self.lock:
                if st.running_since is not None or now < st.next_due:
                    continue
                st.running_since = now
                st.next_due = now + spec["every"]
            threading.Thread(target=self.run_one, args=(spec, now), name="source " + spec["name"], daemon=True).start()

    def run_one(self, spec, started=None):
        """One run of one source, here and now (tick() starts it in a thread; tests may call it)."""
        name = spec["name"]
        st = self.states[name]
        started = time.monotonic() if started is None else started
        fetch = Fetch(spec["cfg"], spec["env"], deadline=started + spec["every"])
        result, error = None, None
        try:
            raw = spec["module"].collect(copy.deepcopy(spec["cfg"]), fetch)
            result = normalize(name, raw, self.secrets, now_iso(), self.log)
        except SourceError as exc:
            error = scrub(exc, self.secrets)
        except Exception as exc:  # noqa: BLE001 - a crash is one warning, not a dead server
            error = scrub(short_error(exc), self.secrets)
            self.log("source %s crashed:\n%s" % (name, self._scrub_log(traceback.format_exc())))
        stamp = now_iso()
        with self.lock:
            st.running_since = None
            st.checked = stamp
            st.runs += 1
            if error is None:
                st.result, st.error, st.logged = result, None, None
                since = {}
                for p in result["problems"]:
                    since[p["id"]] = st.since.get(p["id"], stamp)
                    p["since"] = since[p["id"]]
                st.since = since
            else:
                st.result, st.error = None, error
                if error != st.logged:
                    self.log("source %s: %s" % (name, error))
                st.logged = error
                pid = name + ":source"
                st.since = {pid: st.since.get(pid, stamp)}

    def _failure(self, name, st, error):
        pid = name + ":source"
        if pid not in st.since:
            st.since = {pid: now_iso()}
        return {"id": pid, "severity": "warning", "text": "%s: %s" % (name, error), "since": st.since[pid]}

    def merged(self):
        """{"problems", "hosts", "cards", "services"}: the last result of every source, in config order."""
        out = {"problems": [], "hosts": [], "cards": [], "services": []}
        now = time.monotonic()
        with self.lock:
            for spec in self.specs:
                name = spec["name"]
                st = self.states[name]
                stuck = st.running_since is not None and now - st.running_since > spec["every"] + spec["timeout"]
                if stuck or st.error is not None:
                    out["problems"].append(self._failure(name, st, "timeout" if stuck else st.error))
                    continue
                if st.result is None:
                    continue   # not run yet
                for k in out:
                    out[k].extend(copy.deepcopy(st.result[k]))
        return out

    def status(self):
        """Per source: name, type, ok, error, checked (and insecure). For /info and Diagnostics (MODULAR.md M1.2)."""
        rows = []
        now = time.monotonic()
        with self.lock:
            for spec in self.specs:
                st = self.states[spec["name"]]
                stuck = st.running_since is not None and now - st.running_since > spec["every"] + spec["timeout"]
                error = "timeout" if stuck else st.error
                row = {"name": spec["name"], "type": spec["type"],
                       "ok": None if st.checked is None and not stuck else error is None}
                if error:
                    row["error"] = error
                if st.checked:
                    row["checked"] = st.checked
                if spec["cfg"].get("insecure"):
                    row["insecure"] = True
                rows.append(row)
        return rows
