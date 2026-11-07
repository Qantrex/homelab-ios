"""JSON feed: one URL that answers a subset of the Companion API's /state, read as leniently as the app reads it.

For your own script or service that can serve JSON over HTTP, or another Companion server (a second reference
server: url `.../api/v1/state`, key_env with its token). A script on the bridge's own machine writes card files into
`cards_dir` instead (push, no HTTP needed): docs/REFERENCE_SERVER.md#json-feed.

Upstream (tested against server/recordings/json/*.json, the shape of server/openapi.yaml `State`):
    GET <url>   optional header Authorization: Bearer <key>   (or key_header: <key>)
    {"problems": [...], "hosts": [...], "cards": [...], "services": [...]}
Every list is optional; other keys (`status`, `time`, `pending`, ...) are ignored. The bridge's status follows the
problems, and it keeps its own `since` per problem id.

Config:
    {"name": "Backups", "type": "json", "url": "http://192.0.2.20:8080/homelab.json"}
    optional: "key_env": "FEED_KEY" (sent as a bearer token), "key_header": "X-Api-Key" (send the key raw in this
    header instead)

Read like the app reads /state (Sources/HomelabKit/Lenient.swift, Models.swift): numbers in strings count, a plain
string is a problem's text, "yes"/"1" are true, an entry without its id (or a problem without text) is skipped,
fields of the wrong type are dropped, unknown fields too. Not taken: `pending` (actions), card and item `action`,
container `restartable` (the bridge is read-only) and item `image` (the app loads pictures only from the server it
talks to).
"""

import math
import re

from . import SourceError, as_dict, as_list

HEADER_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")

HOST_TEXT = ("name", "kind", "checked")
CARD_TEXT = ("title", "subtitle", "icon", "tint", "place", "style", "updated", "text", "date")
ITEM_TEXT = ("title", "subtitle", "value", "icon", "tint", "due")
SERVICE_TEXT = ("group", "icon", "description")
HISTORY_SERIES = ("load", "mem_pct", "temp", "disk_pct")
CONTAINER_STATES = ("running", "exited", "restarting", "paused", "created", "removing", "dead")
TRUE = ("true", "yes", "1", "on")
FALSE = ("false", "no", "0", "off")


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required (the feed's full URL)")
    header = cfg.get("key_header")
    if header is not None:
        if not isinstance(header, str) or not HEADER_RE.fullmatch(header):
            raise ValueError("key_header must be a header name (letters, digits, -)")
        if not cfg.get("key_env"):
            raise ValueError("key_header needs key_env (the env variable with the key)")


# --------------------------------------------------------------------------------------------- lenient scalars

def text(value):
    """A non-empty string: strings trimmed, numbers as text, anything else None (the app's `text`)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            return None
        return str(int(value)) if value == int(value) and abs(value) < 1e15 else str(value)
    if isinstance(value, str):
        value = value.strip()
        return value or None
    return None


def number(value):
    """A finite number: numbers, and strings that hold one; else None (the app's `double`)."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value if math.isfinite(value) else None
    if isinstance(value, str):
        try:
            n = float(value.strip())
        except ValueError:
            return None
        return (int(n) if n == int(n) and abs(n) < 1e15 else n) if math.isfinite(n) else None
    return None


def integer(value, low=None, high=None):
    n = number(value)
    if n is None:
        return None
    n = int(round(n))
    if low is not None:
        n = max(low, n)
    if high is not None:
        n = min(high, n)
    return n


def boolean(value):
    """true/false, 1/0, "yes"/"no", "on"/"off"; else None (the app's `bool`)."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return True if value == 1 else False if value == 0 else None
    if isinstance(value, str):
        v = value.strip().lower()
        return True if v in TRUE else False if v in FALSE else None
    return None


def web_url(value):
    v = text(value)
    return v if v and re.match(r"^https?://[^\s/]", v, re.I) else None


def texts(value):
    """A list of strings; one string counts as a list of one."""
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    return [t for t in (text(v) for v in as_list(value)) if t]


def copy_text(src, keys, out):
    for k in keys:
        v = text(src.get(k))
        if v is not None:
            out[k] = v
    return out


# --------------------------------------------------------------------------------------------- the four lists

def read_problem(p):
    if isinstance(p, str):
        return {"text": p.strip()} if p.strip() else None
    p = as_dict(p)
    t = text(p.get("text"))
    if not t:
        return None
    out = {"text": t, "severity": "warning" if (text(p.get("severity")) or "").lower() == "warning" else "problem"}
    for k in ("id", "host"):
        v = text(p.get(k))
        if v:
            out[k] = v
    return out


def read_history(h):
    h = as_dict(h)
    out = {}
    step = integer(h.get("step"))
    if step and step > 0:
        out["step"] = step
    end = text(h.get("end"))
    if end:
        out["end"] = end
    for k in HISTORY_SERIES:
        if isinstance(h.get(k), list):
            out[k] = [number(v) for v in h[k]]
    return out if any(k in out for k in HISTORY_SERIES) else None


def read_container(c):
    c = as_dict(c)
    name = text(c.get("name"))
    if not name:
        return None
    out = {"name": name}
    state = (text(c.get("state")) or "").lower()
    if state in CONTAINER_STATES:
        out["state"] = state
    if "health" in c:
        health = (text(c.get("health")) or "").lower()
        out["health"] = health if health in ("healthy", "unhealthy", "starting") else None
    restarts = integer(c.get("restarts"), low=0)
    if restarts is not None:
        out["restarts"] = restarts
    return out


def read_host(h):
    h = as_dict(h)
    hid = text(h.get("id"))
    if not hid:
        return None
    out = copy_text(h, HOST_TEXT, {"id": hid})
    reachable = boolean(h.get("reachable"))
    if reachable is not None:
        out["reachable"] = reachable
    for k in ("load", "temp"):
        n = number(h.get(k))
        if n is not None:
            out[k] = n
    cpu = integer(h.get("cpu_count"))
    if cpu and cpu > 0:
        out["cpu_count"] = cpu
    mem = integer(h.get("mem_pct"), 0, 100)
    if mem is not None:
        out["mem_pct"] = mem
    disks = {}
    for mount, pct in as_dict(h.get("disks")).items():
        pct = integer(pct, 0, 100)
        if pct is not None:
            disks[mount] = pct
    if disks:
        out["disks"] = disks
    containers = as_dict(h.get("containers"))
    sub = {k: integer(containers.get(k), low=0) for k in ("up", "total")}
    if any(v is not None for v in sub.values()):
        out["containers"] = {k: v for k, v in sub.items() if v is not None}
    updates = as_dict(h.get("updates"))
    sub = {"upgradable": integer(updates.get("upgradable"), low=0), "reboot_required": boolean(updates.get("reboot_required"))}
    if any(v is not None for v in sub.values()):
        out["updates"] = {k: v for k, v in sub.items() if v is not None}
    backup = copy_text(as_dict(h.get("backup")), ("last", "result"), {})
    if backup:
        out["backup"] = backup
    flags = texts(h.get("flags"))
    if flags:
        out["flags"] = flags
    url = web_url(h.get("url"))
    if url:
        out["url"] = url
    history = read_history(h.get("history"))
    if history:
        out["history"] = history
    containers = [c for c in (read_container(c) for c in as_list(h.get("container_list"))) if c]
    if containers:
        out["container_list"] = containers
    return out


def read_item(i):
    i = as_dict(i)
    out = copy_text(i, ITEM_TEXT, {})
    url = web_url(i.get("url"))
    if url:
        out["url"] = url
    progress = number(i.get("progress"))
    if progress is not None:
        out["progress"] = min(1, max(0, progress))
    for k in ("done", "cancelled"):
        b = boolean(i.get(k))
        if b is not None:
            out[k] = b
    return out or None


def read_card(c):
    c = as_dict(c)
    cid = text(c.get("id"))
    if not cid:
        return None
    out = copy_text(c, CARD_TEXT, {"id": cid})
    if "items" in c:
        out["items"] = [i for i in (read_item(i) for i in as_list(c.get("items"))) if i]
    return out


def read_service(s):
    s = as_dict(s)
    name, url = text(s.get("name")), web_url(s.get("url"))
    if not name or not url:
        return None
    return copy_text(s, SERVICE_TEXT, {"name": name, "url": url})


def collect(cfg, fetch):
    headers = {}
    if cfg.get("key_env"):
        key = fetch.secret()
        header = cfg.get("key_header")
        headers = {header: key} if header else {"Authorization": "Bearer " + key}
    data = fetch.json(cfg["url"], headers=headers)
    if not isinstance(data, dict):
        raise SourceError("feed is not a JSON object")
    out = {}
    for key, read in (("problems", read_problem), ("hosts", read_host), ("cards", read_card),
                      ("services", read_service)):
        out[key] = [x for x in (read(x) for x in as_list(data.get(key))) if x]
    return out
