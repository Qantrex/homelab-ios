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
  - no actions by default: `action` on cards and items and `restartable` on containers are removed. A source type
    may offer actions (docker: restart, proxmox: start and stop, pihole and adguard: pause). They exist only for the
    items its config lists under `actions`; SourceActions serves them as the app's run-actions (GET /actions,
    POST /actions/<name>). An item's `action` stays only when its name and arg are on that list
  - exception: the `rss` source's card `news` keeps its id (the app's News tile looks for exactly that); one rss source
  - the card ids `today` and `departures` are refused (the app gives those ids a meaning)
  - secrets: config names env variables (`key_env`, any `*_env`), never the key itself; their values (stripped; one
    with a control character stops the start) are replaced by "***" in everything the source returns and in every
    error, also escaped, %-encoded and in base64; fields named like a secret are dropped. A key sent over plain
    http:// to a host that is not loopback is a warning in the source's status (`plain_http`)
  - texts from upstream (problems, card and item titles, values) get no URLs (`<url>`) and no `key=value` pairs
    with a secret-named key, at most 200 characters (a card's `text` 1000); a link with a user or password, or a key
    in its query, is dropped
  - at most 100 problems, 100 hosts, 50 cards and 100 services per source, 200 items per card and 200 containers per
    host; history series at most 288 points
"""

import base64
import copy
import datetime
import functools
import hashlib
import http.client
import ipaddress
import importlib
import importlib.util
import json
import os
import re
import socket
import ssl
import sys
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
MAX_ITEMS = 200        # per card
MAX_CONTAINERS = 200   # per host
MAX_TEXT = 200         # a problem's text; a card's or an item's title, subtitle, value
MAX_LONG_TEXT = 1000   # a card's `text` (style text)
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
# Source actions (opt-in per item): what an item or host id in an action's argument may look like, the app's limit
# on an argument, how many presses an hour the bridge takes in all, and how long one press may take.
ITEM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
ACTION_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
RESTART = "restart-container"   # the action the app's container list uses, with "<host id>:<container>"
MAX_ARG = 64
ACTIONS_PER_HOUR = 30
ACTION_TIMEOUT = 60.0

_URL_RE = re.compile(r"[a-z][a-z0-9+.-]*://\S+", re.I)
# `apikey=abc` or `token: abc` in an upstream's text (an *arr health message that quotes an indexer's address).
_SECRET_PAIR_RE = re.compile(r"(?i)\b([\w.-]*(?:key|token|password|passwd|secret|auth)[\w.-]*)(\s*[=:]\s*)"
                             r"([^\s&;,'\"()<>\[\]{}]+)")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
BAD_REQUEST = "invalid request (a key or the URL holds a character that is not allowed)"
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
    """A short text for an exception, without URLs. Of a ValueError or an http.client error only its class name: they
    quote what they refuse ("Invalid header value b'<key>\\n'"), and that may be a key."""
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
    elif isinstance(exc, (ValueError, http.client.HTTPException)):
        text = exc.__class__.__name__
    else:
        detail = str(exc)
        text = "%s: %s" % (exc.__class__.__name__, detail) if detail else exc.__class__.__name__
    return text


def _b64_cores(raw):
    """The parts of base64 that depend only on `raw`, wherever it sits in the encoded bytes (all 3 alignments; Basic
    auth encodes "user:password")."""
    out = []
    for k in range(3):
        enc = base64.b64encode(b"\0" * k + raw).decode("ascii")
        core = enc[-(-8 * k // 6):8 * (k + len(raw)) // 6]
        out += [core, core.replace("+", "-").replace("/", "_")]
    return [c for c in out if len(c) >= 8]


@functools.lru_cache(maxsize=64)
def secret_forms(secrets):
    """Every form a text may hold the secrets (a tuple) in: as they are, repr- and JSON-escaped, %-encoded, base64.
    Longest first, so a longer form is replaced before a shorter one inside it."""
    forms = set()
    for s in secrets:
        if not isinstance(s, str) or len(s) < MIN_SCRUB:
            continue
        raw = s.encode("utf-8")
        forms.update({s, repr(s)[1:-1], repr(raw)[2:-1], ascii(s)[1:-1], json.dumps(s)[1:-1],
                      s.encode("unicode_escape").decode("ascii"),
                      urllib.parse.quote(s, safe=""), urllib.parse.quote_plus(s, safe=""),
                      urllib.parse.quote(s), urllib.parse.quote_plus(s)})
        forms.update(_b64_cores(raw))
    return tuple(sorted((f for f in forms if len(f) >= MIN_SCRUB), key=len, reverse=True))


def hide_secrets(text, secrets):
    """`text` with every form of every secret (secret_forms) replaced by ***."""
    for f in secret_forms(tuple(secrets)):
        if f in text:
            text = text.replace(f, "***")
    return text


def scrub(text, secrets):
    """Secrets (in every form) become ***, URLs <url>, one line, at most MAX_ERROR characters."""
    text = hide_secrets(str(text), secrets)
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
    path = os.path.join(here, module_name(kind) + ".py")
    if not os.path.isfile(path):
        raise ValueError("unknown type %r (known: %s)" % (kind, ", ".join(known_types()) or "none"))
    mod = _import_source(module_name(kind), path)
    if not callable(getattr(mod, "collect", None)):
        raise ValueError("type %r has no collect(cfg, fetch)" % kind)
    return mod


_IMPORT_LOCK = threading.Lock()


def _import_source(mod_name, path):
    """Import server/sources/<mod_name>.py as `sources.<mod_name>` without setting it as an attribute of this package:
    importlib.import_module would, and a type named like a module imported here (`json`) would then replace it."""
    full = "%s.%s" % (__name__, mod_name)
    with _IMPORT_LOCK:
        mod = sys.modules.get(full)
        if mod is None:
            spec = importlib.util.spec_from_file_location(full, path)
            mod = importlib.util.module_from_spec(spec)
            sys.modules[full] = mod
            try:
                spec.loader.exec_module(mod)
            except BaseException:
                del sys.modules[full]
                raise
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
            value = env.get(var, "")
            value = value.strip() if isinstance(value, str) else ""
            if _CONTROL_RE.search(value):
                # Only the variable's name, never its value.
                raise ValueError("%s.%s: the env variable %s holds a line break or another control character inside "
                                 "the key. Write the key on one line (in an env file: %s=the key)"
                                 % (where, key, var, var))
            values[var] = value
        check = getattr(module, "check", None)
        if callable(check):
            try:
                check(copy.deepcopy(cfg))
            except ValueError as exc:
                raise ValueError("%s: %s" % (where, exc))
        try:
            allowed = _allowed(name, module, cfg)
        except ValueError as exc:
            raise ValueError("%s: %s" % (where, exc))
        specs.append({"name": name, "type": item["type"], "every": cfg["every"], "timeout": cfg["timeout"],
                      "cfg": cfg, "module": module, "env": values, "actions": allowed,
                      "plain_http": bool(values) and _plain_http(url)})
    if sum(1 for s in specs if s["type"] == "rss") > 1:
        raise ValueError("sources: only one rss source (the News module; list all feeds in it)")
    return specs


def is_loopback_host(host):
    """localhost, 127.0.0.0/8 or ::1."""
    host = (host or "").strip("[]").lower()
    if host == "localhost" or host.endswith(".localhost"):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _plain_http(url):
    """An http:// url to a host that is not loopback: a key sent there crosses the network in clear text."""
    if not isinstance(url, str):
        return False
    u = urllib.parse.urlsplit(url)
    return u.scheme.lower() == "http" and not is_loopback_host(u.hostname)


def link_ok(url):
    """A link the app may show: no user or password in it, and no key in its query."""
    if not isinstance(url, str) or not url:
        return False
    try:
        u = urllib.parse.urlsplit(url)
        return not (u.username is not None or u.password is not None or "@" in u.netloc
                    or SECRET_QUERY.search(u.query))
    except ValueError:
        return False


# What would be Markdown in the app's inline renderer: a backslash, `<` before a letter, `/`, `!` or `?` (autolink, HTML), `*`, a backtick, `~`, the `]`
# of `](`, an entity (`&#58;`, `&amp;`) and an `_` that is not inside a word. A lone `[`, `]`, `>` or `&` is plain text.
_MD_SPECIAL = re.compile(r"([\\*`~]|<(?=[A-Za-z/!?])|\](?=[(\[])|&(?=#?\w+;)|(?<![A-Za-z0-9])_|_(?![A-Za-z0-9]))")


def plain_text(text, limit=MAX_TEXT):
    """An upstream's text without secrets: URLs become <url>, `key=value` with a secret-named key `key=***`, at most
    `limit` characters. Still raw text: safe_text() makes it safe for the app's Markdown renderer."""
    text = _URL_RE.sub("<url>", text)
    text = _SECRET_PAIR_RE.sub(lambda m: m.group(1) + m.group(2) + "***", text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def safe_text(text, limit=MAX_TEXT):
    """plain_text() for the app: the app shows text as Markdown, so a backslash, [ ] < > & * _ ` ~ gets a backslash
    in front (CommonMark shows it as the plain character). That removes links (`[a](b)`, also with `&#58;` or
    `\\` forms in the address), autolinks, raw HTML, entities, emphasis and code; ordinary text ("C&C", "2/10",
    "[STATUS] (502)") stays as it is. Call it once on a string: a second call would escape the escapes."""
    text = _MD_SPECIAL.sub(r"\\\1", plain_text(text, limit))
    if len(text) > limit:
        text = text[:limit - 1]
        text = text[:-1] if (len(text) - len(text.rstrip("\\"))) % 2 else text
        text += "…"
    return text


def _allowed(name, module, cfg):
    """What a source's config allows it to do: [{"action", "host", "item", "label", "host_label", "arg"}], checked.

    Empty without an `actions` key. The module's allowed(cfg) lists them from the config only (never from the
    upstream); its ACTIONS describes each action name. The argument the app sends is "<name>:<host>:<item>" with a host
    (the app's container Restart builds "<host id>:<container>", and host ids are prefixed) or "<name>:<item>". The
    bridge only looks it up in this list and never parses it, so ARG_RE (for argv commands) doesn't apply."""
    if cfg.get("actions") is None:
        return []
    meta = getattr(module, "ACTIONS", None)
    if not callable(getattr(module, "allowed", None)) or not callable(getattr(module, "act", None)) \
            or not isinstance(meta, dict):
        raise ValueError("type %r has no actions" % cfg["type"])
    out, args = [], set()
    for a in module.allowed(copy.deepcopy(cfg)):
        action, host, item = a.get("action"), a.get("host"), a.get("item")
        if action not in meta or not isinstance(action, str) or not ACTION_NAME_RE.fullmatch(action):
            raise ValueError("unknown action %r" % (action,))
        if not isinstance(item, str) or not ITEM_RE.fullmatch(item):
            raise ValueError("actions: %r is not a valid name (A-Z a-z 0-9 _ . -)" % (item,))
        if host is not None and (not isinstance(host, str) or not ITEM_RE.fullmatch(host)):
            raise ValueError("actions: host %r is not a valid id" % (host,))
        arg = "%s:%s:%s" % (name, host, item) if host is not None else "%s:%s" % (name, item)
        if len(arg) > MAX_ARG:
            raise ValueError("actions: %r is longer than %d characters, so the app can't send it (use a shorter "
                             "source name or host)" % (arg, MAX_ARG))
        if (action, arg) in args:
            continue
        args.add((action, arg))
        out.append({"action": action, "host": host, "item": item, "arg": arg,
                    "label": as_text(a.get("label")) or item,
                    "host_label": as_text(a.get("host_label")) or host or ""})
    return out


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
        except ValueError:
            # http.client: "Invalid header value b'<key>\n'", an invalid URL. Its text may quote the key.
            raise SourceError(BAD_REQUEST)
        except (urllib.error.URLError, http.client.HTTPException, OSError) as exc:
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
    """Drop secret-named fields at any depth; secret values (in every form, secret_forms) in any string become ***."""
    if isinstance(obj, dict):
        return {_clean(k, secrets): _clean(v, secrets) for k, v in obj.items() if not SECRET_FIELD.match(str(k))}
    if isinstance(obj, list):
        return [_clean(v, secrets) for v in obj]
    if isinstance(obj, str):
        return hide_secrets(obj, secrets)
    return obj


def _safe_fields(obj, keys, markdown=()):
    """The text fields `keys` of a dict, in place: safe_text() for the ones in `markdown` (the app renders those as
    Markdown), plain_text() for the rest (the app shows them as plain text, where an escape would show as a
    backslash). A card's `text` may be longer."""
    for k in keys:
        if isinstance(obj.get(k), str):
            limit = MAX_LONG_TEXT if k == "text" else MAX_TEXT
            obj[k] = safe_text(obj[k], limit) if k in markdown else plain_text(obj[k], limit)


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


def _no_actions(card, allowed=frozenset()):
    """Remove every action, except an item's `action` whose (name, arg) is on the source's list (`allowed`); it keeps
    only name, label and arg."""
    card.pop("action", None)
    for item in card.get("items", []):
        act = item.pop("action", None)
        if isinstance(act, dict) and (act.get("name"), act.get("arg")) in allowed:
            item["action"] = {k: act[k] for k in ("name", "label", "arg") if isinstance(act.get(k), str)}
    return card


def normalize(name, result, secrets=(), checked=None, logf=lambda m: None, restartable=frozenset(),
              item_actions=frozenset()):
    """A source's raw result → {"problems", "hosts", "cards", "services"} as the app may see it (rules in the
    module docstring). `restartable`: the (host id, container name) pairs on the source's restart list; only those
    get `restartable: true`. `item_actions`: the (action, arg) pairs on the source's actions list; only those stay
    as an item's button. Raises SourceError when the result is not a JSON object."""
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
        raw_id = h["id"]
        h.setdefault("name", raw_id)
        h["id"] = prefix + raw_id
        hist = h.get("history")
        if isinstance(hist, dict):
            for k, v in hist.items():
                if isinstance(v, list) and len(v) > MAX_HISTORY:
                    hist[k] = v[-MAX_HISTORY:]
        if isinstance(h.get("container_list"), list):
            h["container_list"] = [c for c in h["container_list"] if isinstance(c, dict)][:MAX_CONTAINERS]
            for c in h["container_list"]:
                c.pop("restartable", None)
                if (raw_id, c.get("name")) in restartable:
                    c["restartable"] = True
        hosts.append(h)
    host_ids = {h["id"] for h in hosts}

    problems, seen = [], set()
    for p in as_list(result.get("problems")):
        if isinstance(p, str):
            p = {"text": p}
        if not isinstance(p, dict) or not isinstance(p.get("text"), str) or not p["text"].strip():
            logf("source %s: skipped a problem without text" % name)
            continue
        text = plain_text(p["text"])   # problems are plain text in the app
        raw_id = p.get("id") if isinstance(p.get("id"), str) and p.get("id") else \
            hashlib.sha256(text.encode("utf-8")).hexdigest()[:10]
        pid = prefix + raw_id
        if pid in seen:
            continue
        seen.add(pid)
        out = {"id": pid, "severity": p.get("severity") if p.get("severity") in SEVERITIES else
               ("problem" if p.get("severity") is None else "warning"), "text": text}
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
        # Markdown in the app: a card's `text`, and for a `text` card without one its item titles (joined).
        _safe_fields(c, ("title", "subtitle", "text"), markdown=("text",))
        item_markdown = ("title",) if c.get("style") == "text" else ()
        if "items" in c:
            if isinstance(c["items"], list):
                c["items"] = [i for i in c["items"] if isinstance(i, dict)][:MAX_ITEMS]
                for i in c["items"]:
                    _safe_fields(i, ("title", "subtitle", "value"), markdown=item_markdown)
                    if "url" in i and not link_ok(i["url"]):
                        logf("source %s: dropped an item's link (a user, password or key in it)" % name)
                        del i["url"]
            else:
                del c["items"]
        if checked and "updated" not in c:
            c["updated"] = checked
        cards.append(_no_actions(c, item_actions))

    services = []
    for s in _pick(result.get("services"), MAX_SERVICES,
                   lambda x: isinstance(x, dict) and isinstance(x.get("name"), str) and x["name"]
                   and isinstance(x.get("url"), str) and link_ok(x["url"]), "service", name, logf):
        s = {k: v for k, v in s.items() if k in ("name", "url", "group", "icon", "description")}
        _safe_fields(s, ("description",))
        s.setdefault("group", name)
        services.append(s)
    return {"problems": problems, "hosts": hosts, "cards": cards, "services": services}


# --------------------------------------------------------------------------------------------- runner

class _State:
    def __init__(self):
        self.result = None       # normalized contribution of the last good run
        self.error = None        # short text of the last failed run
        self.checked = None      # ISO time of the last finished run
        self.last_ok = None      # ISO time of the last good run (kept while the source fails)
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
        self.actions = SourceActions(specs, self.secrets, logf, after=self.read_soon)
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
            if s.get("plain_http"):
                logf("source %s: warning: its key goes over plain http:// to a host that is not loopback; use https://"
                     % s["name"])

    def read_soon(self, name):
        """Read this source again at the next tick (after an action changed something upstream)."""
        with self.lock:
            if name in self.states:
                self.states[name].next_due = 0.0

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
        return hide_secrets(text, self.secrets)

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
            restartable = {(a["host"], a["item"]) for a in spec.get("actions", ()) if a["action"] == RESTART}
            listed = {(a["action"], a["arg"]) for a in spec.get("actions", ())}
            result = normalize(name, raw, self.secrets, now_iso(), self.log, restartable, listed)
            if spec["type"] == "rss":   # the News module's card keeps the exact id the app looks for
                for c in result["cards"]:
                    if c["id"] == name + ":news":
                        c["id"] = "news"
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
                st.result, st.error, st.logged, st.last_ok = result, None, None, stamp
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
        """Per source, in config order: what /info lists under `sources` (MODULAR.md M1.2; Diagnostics in the app, M2.4).

        {"name", "type", "state": "ok" | "failing" | "never", "error" (only while failing: the warning's short,
        scrubbed text), "checked" (the last finished run), "last_ok" (the last good run, kept while failing),
        "insecure" (only when true: TLS certificates are not checked; clients show it as a warning), "plain_http" (only
        when true: its key goes over plain http:// to a host that is not loopback; a warning too)}. "never": no run
        has finished yet. A run that hangs past `every + timeout` is "failing" with "timeout", the first one too."""
        rows = []
        now = time.monotonic()
        with self.lock:
            for spec in self.specs:
                st = self.states[spec["name"]]
                stuck = st.running_since is not None and now - st.running_since > spec["every"] + spec["timeout"]
                error = "timeout" if stuck else st.error
                row = {"name": spec["name"], "type": spec["type"],
                       "state": "failing" if error else ("never" if st.checked is None else "ok")}
                if error:
                    row["error"] = error
                if st.checked:
                    row["checked"] = st.checked
                if st.last_ok:
                    row["last_ok"] = st.last_ok
                if spec["cfg"].get("insecure"):
                    row["insecure"] = True
                if spec.get("plain_http"):
                    row["plain_http"] = True
                rows.append(row)
        return rows


# --------------------------------------------------------------------------------------------- actions

class SourceActions:
    """Actions of sources, off by default and per item: only what a source's config lists under `actions` (docker:
    restart, proxmox: start and stop). Served as the app's run-actions: listing() is GET /actions, run() is
    POST /actions/<name>. The app asks first (a red confirm for destructive ones); the server checks again here:
    the argument must be exactly one on the list (it is looked up, never parsed or put into a URL), no payload, at
    most ACTIONS_PER_HOUR presses an hour in all, one press per item at a time. Errors never hold a key or a URL."""

    def __init__(self, specs, secrets=(), logf=lambda m: None, per_hour=ACTIONS_PER_HOUR, after=None):
        self.secrets = secrets
        self.log = logf
        self.after = after  # after(source name), called after a press that worked (the Runner reads it again)
        self.per_hour = per_hour
        self.table = {}     # (action, arg) -> (spec, entry)
        self.meta = {}      # action -> its ACTIONS entry (from the first source type that offers it)
        self.lock = threading.Lock()
        self.recent = []    # monotonic times of the presses in the last hour
        self.running = set()
        for spec in specs:
            for a in spec.get("actions", ()):
                self.table[(a["action"], a["arg"])] = (spec, a)
                self.meta.setdefault(a["action"], dict(spec["module"].ACTIONS[a["action"]]))

    def __bool__(self):
        return bool(self.table)

    def names(self):
        return list(self.meta)

    def listing(self):
        """{"actions": [ActionSpec]}: one per action name, one arg variant per source and host with the items as a
        choice. A variant builds exactly the arguments on the list, nothing else."""
        out = []
        for action, meta in self.meta.items():
            groups = {}
            for (name, _), (spec, a) in self.table.items():
                if name == action:
                    groups.setdefault((spec["name"], a["host"]), []).append(a)
            variants = []
            for (source, host), entries in groups.items():
                items = {"kind": "choice", "label": as_text(meta.get("part"), "Item"),
                         "options": [{"value": a["item"], "label": a["label"]} for a in entries]}
                if host is None:
                    variants.append({"label": source, "parts": [{"kind": "literal", "text": source + ":"}, items]})
                else:
                    shown = entries[0]["host_label"]
                    variants.append({"label": "%s · %s" % (source, shown) if shown != source else source,
                                     "parts": [{"kind": "choice", "label": "Host",
                                                "options": [{"value": "%s:%s" % (source, host), "label": shown}]},
                                               {"kind": "literal", "text": ":"}, items]})
            item = {"name": action, "label": as_text(meta.get("label"), action), "fields": [], "arg": variants}
            for key in ("icon", "hint"):
                if as_text(meta.get(key)):
                    item[key] = meta[key]
            if meta.get("destructive") is True:
                item["destructive"] = True
            out.append(item)
        return {"actions": out}

    def run(self, action, body):
        """POST /actions/<action> with {arg, payload}: (status, answer)."""
        if action not in self.meta:
            return 404, {"error": "not an action the app may start"}
        arg, payload = body.get("arg") or "", body.get("payload") or {}
        if not isinstance(arg, str) or not isinstance(payload, dict):
            return 400, {"error": "arg must be text and payload an object"}
        if payload:
            return 400, {"error": "%s takes no fields" % action}
        entry = self.table.get((action, arg))
        if entry is None:
            return 400, {"error": "not on this server's %s list" % action}
        spec, a = entry
        key = (action, arg)
        with self.lock:
            now = time.monotonic()
            self.recent = [t for t in self.recent if now - t < 3600]
            if len(self.recent) >= self.per_hour:
                return 429, {"error": "more than %d actions in the last hour" % self.per_hour}
            if key in self.running:
                return 429, {"error": "%s is still running" % a["label"]}
            self.recent.append(now)
            self.running.add(key)
        try:
            fetch = Fetch(spec["cfg"], spec["env"], deadline=time.monotonic() + ACTION_TIMEOUT)
            text = spec["module"].act(copy.deepcopy(spec["cfg"]), fetch, action, a["host"], a["item"])
            ok, text = True, as_text(text) or "Done."
        except SourceError as exc:
            ok, text = False, "%s: %s failed (%s)" % (spec["name"], a["label"], exc)
        except Exception as exc:  # noqa: BLE001 - a bug in a module is a failed press, not a dead server
            ok, text = False, "%s: %s failed (%s)" % (spec["name"], a["label"], short_error(exc))
            trace = hide_secrets(traceback.format_exc(), self.secrets)
            self.log("source %s: action %s crashed:\n%s" % (spec["name"], action, trace))
        finally:
            with self.lock:
                self.running.discard(key)
        text = scrub(text, self.secrets)
        self.log("source %s: %s %s: %s" % (spec["name"], action, arg, "ok" if ok else text))
        if ok and self.after:
            self.after(spec["name"])
        return 200, {"ok": ok, "text": text}
