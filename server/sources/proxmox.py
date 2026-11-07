"""Proxmox VE: every node as a host with its last 24 h, its VMs and LXC containers as the host's container list.

Upstream: the Proxmox VE API with an API token (header `Authorization: PVEAPIToken=<user>@<realm>!<id>=<secret>`),
tested against the shapes of Proxmox VE 9.0 (recordings/proxmox/; the day of rrddata is one point a minute there and
one every 30 minutes on PVE 8, both work). Read-only with the PVEAuditor role, or a role with just Sys.Audit and
VM.Audit (docs/REFERENCE_SERVER.md#proxmox):
    GET <url>/api2/json/nodes
    GET <url>/api2/json/nodes/<node>/status                      Sys.Audit
    GET <url>/api2/json/nodes/<node>/rrddata?timeframe=day&cf=AVERAGE   Sys.Audit
    GET <url>/api2/json/nodes/<node>/qemu, .../lxc               VM.Audit (lists only the guests the token may see)
    only for guests listed under actions (VM.PowerMgmt on /vms/<vmid>):
    GET <url>/api2/json/cluster/resources?type=vm                where the guest runs now
    POST <url>/api2/json/nodes/<node>/<qemu|lxc>/<vmid>/status/start | shutdown

Config:
    {"name": "Proxmox", "type": "proxmox", "url": "https://192.0.2.20:8006", "token_id": "monitor@pve!bridge",
     "key_env": "PVE_TOKEN", "ca_file": "/etc/homelab/pve-ca.pem", "expect_running": [101],
     "actions": {"start": [101, {"vmid": 102, "label": "Home Assistant"}], "stop": [101]}}

    url              https:// (http:// only to 127.0.0.1 or localhost, e.g. an SSH tunnel)
    token_id         the token's name, user@realm!id (not secret); key_env names the env variable with its secret
    ca_file          the cluster's CA (/etc/pve/pve-root-ca.pem), or insecure: true (logged as a warning)
    ui_url           the web UI link on each node (default: url)
    expect_running   VMIDs that are a problem when they are stopped
    disk_warning, disk_problem   percent of a node's root disk (90, 95)
    actions          opt-in: {"start": [VMIDs], "stop": [VMIDs]}; stop is a clean shutdown (ACPI or the CT's init)

What it gives: one host per node (reachable, load, cores, memory, root disk, history with load, mem_pct and disk_pct
in 5-minute steps, at most 288 points), its guests as `container_list` (running, or stopped as exited; templates
skipped). Problems: an offline node, a full root disk, a stopped guest from expect_running, a node whose details the
token can't read (a warning).
"""

import datetime
import re

from . import SourceError, as_dict, as_list, as_text, now_iso

API = "/api2/json"
NODE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")
TOKEN_ID_RE = re.compile(r"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+![A-Za-z][A-Za-z0-9._-]*$")
LOOPBACK_HTTP = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(/|$)", re.I)
DAY = 86400
MIN_STEP = 300          # 24 h in at most 288 points
MAX_POINTS = DAY // MIN_STEP

ACTIONS = {
    "guest-start": {"label": "Start a VM or container", "icon": "play", "part": "Guest",
                    "hint": "Only guests on the source's start list."},
    "guest-stop": {"label": "Shut down a VM or container", "icon": "stop", "destructive": True, "part": "Guest",
                   "hint": "A clean shutdown, like Shutdown in Proxmox. Only guests on the source's stop list."},
}
_VERB = {"guest-start": ("start", "Starting"), "guest-stop": ("shutdown", "Shutting down")}


def _vmid(value):
    """A VMID from the config: an int 100-999999999 (or such a string), else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    return value if isinstance(value, int) and 100 <= value <= 999999999 else None


def check(cfg):
    url = cfg.get("url")
    if not url:
        raise ValueError("url is required (https://<node>:8006)")
    if not url.lower().startswith("https://") and not LOOPBACK_HTTP.match(url):
        raise ValueError("url must be https:// (the token would travel in the clear)")
    if not isinstance(cfg.get("token_id"), str) or not TOKEN_ID_RE.fullmatch(cfg["token_id"]):
        raise ValueError("token_id must be the token's name, user@realm!id (e.g. monitor@pve!bridge)")
    if not cfg.get("key_env"):
        raise ValueError("key_env is required (the env variable with the token's secret)")
    ui = cfg.get("ui_url")
    if ui is not None and (not isinstance(ui, str) or not re.match(r"^https?://[^\s@]+$", ui)):
        raise ValueError("ui_url must be an http(s):// URL")
    expect = cfg.get("expect_running", [])
    if not isinstance(expect, list) or any(_vmid(v) is None for v in expect):
        raise ValueError("expect_running must be a list of VMIDs")
    for key in ("disk_warning", "disk_problem"):
        v = cfg.get(key)
        if v is not None and (isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 < v <= 100):
            raise ValueError("%s must be a percentage" % key)
    actions = cfg.get("actions")
    if actions is not None:
        if not isinstance(actions, dict) or set(actions) - {"start", "stop"}:
            raise ValueError('actions must be {"start": [VMIDs], "stop": [VMIDs]}')
        for verb, items in actions.items():
            if not isinstance(items, list):
                raise ValueError("actions.%s must be a list of VMIDs" % verb)
            for v in items:
                vmid = _vmid(as_dict(v).get("vmid") if isinstance(v, dict) else v)
                if vmid is None or (isinstance(v, dict) and not isinstance(v.get("label", ""), str)):
                    raise ValueError("actions.%s: %r is not a VMID (or {\"vmid\": 101, \"label\": \"...\"})"
                                     % (verb, v))


def allowed(cfg):
    out = []
    for verb, action in (("start", "guest-start"), ("stop", "guest-stop")):
        for v in as_dict(cfg.get("actions")).get(verb, []):
            vmid = str(_vmid(v.get("vmid") if isinstance(v, dict) else v))
            label = as_text(v.get("label")) if isinstance(v, dict) else ""
            out.append({"action": action, "item": vmid, "label": "%s (%s)" % (label, vmid) if label else vmid})
    return out


def _headers(cfg, fetch):
    return {"Authorization": "PVEAPIToken=%s=%s" % (cfg["token_id"], fetch.secret())}


def _data(fetch, path, headers):
    return as_dict(fetch.json(API + path, headers=headers)).get("data")


def act(cfg, fetch, action, host, item):
    """Start or shut down one listed guest, on the node it runs on now. The bridge only calls it for listed items."""
    if action not in _VERB or not item.isdigit():
        raise SourceError("not allowed")
    headers = _headers(cfg, fetch)
    where = None
    for r in as_list(_data(fetch, "/cluster/resources?type=vm", headers)):
        r = as_dict(r)
        if as_text(r.get("vmid")) == item and r.get("type") in ("qemu", "lxc") \
                and NODE_RE.fullmatch(as_text(r.get("node"))):
            where = r
            break
    if where is None:
        raise SourceError("guest %s not found" % item)
    verb, doing = _VERB[action]
    fetch("%s/nodes/%s/%s/%s/status/%s" % (API, where["node"], where["type"], item, verb), method="POST", body=b"",
          headers=headers)
    name = as_text(where.get("name"))
    return "%s %s on %s." % (doing, "%s (%s)" % (name, item) if name else item, where["node"])


def _num(value):
    """A number from the API (numbers, sometimes numeric strings), else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _pct(used, total):
    used, total = _num(used), _num(total)
    if used is None or not total or total <= 0:
        return None
    return max(0, min(100, int(round(used * 100.0 / total))))


def history(rows):
    """rrddata rows → HostHistory: the last 24 h in steps of at least 5 minutes (averaged), at most 288 points, null
    for a slot without data; None when there is nothing to show."""
    points = []
    for r in as_list(rows):
        r = as_dict(r)
        t = _num(r.get("time"))
        if t is not None and 0 < t < 1e11:
            points.append((int(t), r))
    if not points:
        return None
    points.sort(key=lambda p: p[0])
    times = sorted({t for t, _ in points})
    gaps = [b - a for a, b in zip(times, times[1:]) if b > a]
    step = max(MIN_STEP, min(gaps) if gaps else MIN_STEP)
    end = times[-1]
    count = min(MAX_POINTS, DAY // step)
    first = end - count * step     # slot k holds the points in (first + k*step, first + (k+1)*step]
    series = {"load": lambda r: _num(r.get("loadavg")),
              "mem_pct": lambda r: _pct(r.get("memused"), r.get("memtotal")),
              "disk_pct": lambda r: _pct(r.get("rootused"), r.get("roottotal"))}
    sums = {k: [[0.0, 0] for _ in range(count)] for k in series}
    for t, r in points:
        if t <= first:
            continue
        slot = min(count - 1, (t - first - 1) // step)
        for k, get in series.items():
            v = get(r)
            if v is not None:
                sums[k][slot][0] += v
                sums[k][slot][1] += 1
    out = {"step": int(step),
           "end": datetime.datetime.fromtimestamp(end).astimezone().isoformat(timespec="seconds")}
    for k in series:
        values = [round(s / n, 2) if n else None for s, n in sums[k]]
        if k != "load":
            values = [int(round(v)) if v is not None else None for v in values]
        if any(v is not None for v in values):
            out[k] = values
    return out if len(out) > 2 else None


def _guests(fetch, node, headers):
    """The node's VMs and containers as Container items, by VMID: [(vmid, entry, running)]."""
    found = []
    for kind in ("qemu", "lxc"):
        for g in as_list(_data(fetch, "/nodes/%s/%s" % (node, kind), headers)):
            g = as_dict(g)
            vmid = _vmid(g.get("vmid"))
            if vmid is None or g.get("template") in (1, True, "1"):
                continue
            status = as_text(g.get("status"))
            name = as_text(g.get("name")) or ("VM %d" % vmid if kind == "qemu" else "CT %d" % vmid)
            entry = {"name": name, "health": None}
            if status in ("running", "stopped"):
                entry["state"] = "running" if status == "running" else "exited"
            found.append((vmid, entry, status == "running"))
    found.sort(key=lambda f: f[0])
    return found


def collect(cfg, fetch):
    headers = _headers(cfg, fetch)
    nodes = _data(fetch, "/nodes", headers)
    if not isinstance(nodes, list):
        raise SourceError("answer has no node list")
    warn_at, bad_at = cfg.get("disk_warning", 90), cfg.get("disk_problem", 95)
    expect = {_vmid(v) for v in cfg.get("expect_running", [])}
    hosts, problems, seen = [], [], set()
    for n in sorted((as_dict(n) for n in nodes), key=lambda n: as_text(n.get("node"))):
        node = as_text(n.get("node"))
        if not NODE_RE.fullmatch(node) or node in seen:
            continue
        seen.add(node)
        status = as_text(n.get("status"))
        host = {"id": node, "name": node, "kind": "server", "checked": now_iso(), "url": cfg.get("ui_url") or cfg["url"]}
        if status in ("online", "offline"):
            host["reachable"] = status == "online"
        if _num(n.get("maxcpu")):
            host["cpu_count"] = int(_num(n["maxcpu"]))
        mem = _pct(n.get("mem"), n.get("maxmem"))
        if mem is not None:
            host["mem_pct"] = mem
        hosts.append(host)
        if status != "online":
            problems.append({"id": "node-%s" % node, "host": node, "severity": "problem" if status == "offline"
                             else "warning", "text": "%s: %s" % (node, "offline" if status == "offline"
                                                                 else "status unknown")})
            continue
        unread = []
        try:
            st = as_dict(_data(fetch, "/nodes/%s/status" % node, headers))
            load = as_list(st.get("loadavg"))
            if load and _num(load[0]) is not None:
                host["load"] = round(_num(load[0]), 2)
            cpus = _num(as_dict(st.get("cpuinfo")).get("cpus"))
            if cpus:
                host["cpu_count"] = int(cpus)
            mem = as_dict(st.get("memory"))
            if _pct(mem.get("used"), mem.get("total")) is not None:
                host["mem_pct"] = _pct(mem.get("used"), mem.get("total"))
            root = as_dict(st.get("rootfs"))
            disk = _pct(root.get("used"), root.get("total"))
            if disk is not None:
                host["disks"] = {"/": disk}
                if disk >= warn_at:
                    problems.append({"id": "disk-%s" % node, "host": node,
                                     "severity": "problem" if disk >= bad_at else "warning",
                                     "text": "%s: root disk at %d%%" % (node, disk)})
        except SourceError as exc:
            unread.append("status %s" % exc)
        try:
            hist = history(_data(fetch, "/nodes/%s/rrddata?timeframe=day&cf=AVERAGE" % node, headers))
            if hist:
                host["history"] = hist
        except SourceError as exc:
            unread.append("history %s" % exc)
        try:
            guests = _guests(fetch, node, headers)
            host["container_list"] = [g[1] for g in guests]
            host["containers"] = {"up": sum(1 for g in guests if g[2]), "total": len(guests)}
            for vmid, entry, running in guests:
                if vmid in expect and entry.get("state") == "exited":
                    problems.append({"id": "guest-%d" % vmid, "host": node, "severity": "problem",
                                     "text": "%s: %s (%d) is stopped" % (node, entry["name"], vmid)})
        except SourceError as exc:
            unread.append("guests %s" % exc)
        if unread:
            problems.append({"id": "node-%s-details" % node, "host": node, "severity": "warning",
                             "text": "%s: can't read %s" % (node, ", ".join(unread))})
    return {"problems": problems, "hosts": hosts}
