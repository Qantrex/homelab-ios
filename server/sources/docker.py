"""Docker: the containers of one Docker host, read through a socket proxy (never the raw socket).

Upstream: the Docker Engine API, tested against the shapes of Docker Engine 29 (API 1.52, which adds `Health` to
the list) and older engines that only have the health in the `Status` text (recordings/docker/). Behind a socket
proxy that allows GET /containers/json only (wollomatic/socket-proxy with -allowGET=/containers/json; not
tecnativa's CONTAINERS=1, which also serves every container's env, logs and files; docs/REFERENCE_SERVER.md#docker):
    GET <url>/containers/json?all=1
    POST <url>/containers/<name>/restart?t=10      only for containers listed under actions.restart

Config:
    {"name": "Docker", "type": "docker", "url": "http://socket-proxy:2375",
     "host": "nas", "host_name": "NAS", "ignore": ["backup-job"], "actions": {"restart": ["sonarr", "gluetun"]}}

    host        the host id (default: the source name in lower case); `host_name` the shown name, `kind` (server)
    ignore      containers that never become problems (one-shot jobs)
    actions     opt-in: {"restart": [container names]}. Only these get Restart in the app (restart-container)

What it gives: one host with `containers` {up, total} and every container in `container_list` (state, health).
Problems: unhealthy, restarting or dead containers; an exited container with a non-zero exit code is a warning.
"""

import re

from . import SourceError, as_dict, as_list, as_text, now_iso

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
STATES = ("running", "exited", "restarting", "paused", "created", "removing", "dead")
HEALTH = ("healthy", "unhealthy", "starting")
EXIT_RE = re.compile(r"^exited \((-?\d+)\)")
RESTART_WAIT = 10      # seconds Docker waits for a container to stop before it kills it
ACTION_TIMEOUT = 45    # a restart answers when the container is up again

ACTIONS = {
    "restart-container": {"label": "Restart a container", "icon": "arrow.clockwise", "destructive": True,
                          "hint": "Only containers on the source's restart list.", "part": "Container"},
}


def host_id(cfg):
    if cfg.get("host"):
        return cfg["host"]
    return re.sub(r"[^a-z0-9_.-]+", "-", cfg["name"].lower()).strip("-._") or "docker"


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required (the socket proxy, e.g. http://socket-proxy:2375)")
    host = cfg.get("host")
    if host is not None and (not isinstance(host, str) or not NAME_RE.fullmatch(host)):
        raise ValueError("host must be an id of A-Z a-z 0-9 _ . -")
    for key in ("host_name", "kind"):
        if cfg.get(key) is not None and not isinstance(cfg[key], str):
            raise ValueError("%s must be text" % key)
    ignore = cfg.get("ignore", [])
    if not isinstance(ignore, list) or not all(isinstance(n, str) for n in ignore):
        raise ValueError("ignore must be a list of container names")
    actions = cfg.get("actions")
    if actions is not None:
        if not isinstance(actions, dict) or set(actions) - {"restart"}:
            raise ValueError('actions must be {"restart": [container names]}')
        names = actions.get("restart", [])
        if not isinstance(names, list) or not all(isinstance(n, str) and NAME_RE.fullmatch(n) for n in names):
            raise ValueError("actions.restart must be a list of container names (A-Z a-z 0-9 _ . -)")


def allowed(cfg):
    """The containers the config lets the app restart."""
    hid = host_id(cfg)
    shown = cfg.get("host_name") or hid
    return [{"action": "restart-container", "host": hid, "host_label": shown, "item": n, "label": n}
            for n in as_dict(cfg.get("actions")).get("restart", [])]


def act(cfg, fetch, action, host, item):
    """Restart one listed container (POST /containers/<name>/restart). The bridge only calls it for listed items."""
    if action != "restart-container" or not NAME_RE.fullmatch(item):
        raise SourceError("not allowed")
    fetch("/containers/%s/restart?t=%d" % (item, RESTART_WAIT), method="POST", body=b"",
          timeout=max(float(cfg.get("timeout") or 0), ACTION_TIMEOUT))
    return "Restarted %s on %s." % (item, cfg.get("host_name") or host)


def _name(c):
    """The container's name: the first of Names without its "/" (the others are legacy links)."""
    for n in as_list(c.get("Names")):
        n = as_text(n).lstrip("/")
        if n and "/" not in n:
            return n
    return ""


def _health(c, status):
    h = as_dict(c.get("Health")).get("Status")   # API 1.52+
    if h in HEALTH:
        return h
    if h == "none":
        return None
    for word in ("unhealthy", "healthy"):        # older engines: "Up 3 hours (unhealthy)"
        if "(%s)" % word in status:
            return word
    if "(health: starting)" in status:
        return "starting"
    return None


def collect(cfg, fetch):
    data = fetch.json("/containers/json?all=1")
    if not isinstance(data, list):
        raise SourceError("answer is not a container list")
    hid = host_id(cfg)
    shown = cfg.get("host_name") or hid
    ignore = set(cfg.get("ignore", []))
    containers, problems, seen = [], [], set()
    for c in data:
        c = as_dict(c)
        name = _name(c)
        if not name or name in seen:
            continue
        seen.add(name)
        state = as_text(c.get("State")).lower()
        status = as_text(c.get("Status")).lower()
        if state not in STATES:
            state = "running" if status.startswith("up ") else ""
        health = _health(c, status)
        entry = {"name": name}
        if state:
            entry["state"] = state
        entry["health"] = health
        containers.append(entry)
        if name in ignore:
            continue
        what, severity = None, "problem"
        if health == "unhealthy":
            what = "is unhealthy"
        elif state in ("restarting", "dead"):
            what = "is %s" % state
        elif state == "exited":
            m = EXIT_RE.match(status)
            if m and m.group(1) != "0":
                what, severity = "exited (%s)" % m.group(1), "warning"
        if what:
            problems.append({"id": "container-%s" % name, "host": hid, "severity": severity,
                             "text": "%s: %s %s" % (shown, name, what)})
    containers.sort(key=lambda e: e["name"].lower())
    host = {"id": hid, "name": shown, "kind": cfg.get("kind") or "server", "reachable": True, "checked": now_iso(),
            "containers": {"up": sum(1 for e in containers if e.get("state") == "running"), "total": len(containers)},
            "container_list": containers}
    return {"problems": problems, "hosts": [host]}
