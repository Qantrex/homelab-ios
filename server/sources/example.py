"""Example source: the template for new sources (docs/BRIDGE.md). It reads a made-up status API, so it also shows
the whole contract in one small file. Copy it to server/sources/<type>.py and change the three marked parts.

Upstream (made up; tested against server/recordings/example/*.json):
    GET <url>/api/status   header X-Api-Key: <the key>
    {"hosts": [{"id": "pve1", "name": "pve1", "up": true, "load": 0.4}],
     "monitors": [{"id": 3, "name": "Jellyfin", "up": false, "msg": "timeout", "url": "http://..."}]}

Config:
    {"name": "Lab", "type": "example", "url": "http://192.0.2.10:8080", "key_env": "LAB_KEY"}

What it gives: each host as a host, each monitor that is down as a problem, one list card with every monitor, and a
service per monitor that has a url.
"""

from . import as_dict, as_list, as_text


def check(cfg):
    """(1) Config checks at start. Raise ValueError with a short text."""
    if not cfg.get("url"):
        raise ValueError("url is required")
    if not cfg.get("key_env"):
        raise ValueError("key_env is required (the env variable with the API key)")


def collect(cfg, fetch):
    """(2) Read the upstream. Only through fetch; the key only through fetch.secret()."""
    data = as_dict(fetch.json("/api/status", headers={"X-Api-Key": fetch.secret()}))

    # (3) Map it, leniently: odd fields are skipped, never a crash. Ids are this source's own; the bridge adds
    # "<name>:" in front.
    hosts = []
    for h in as_list(data.get("hosts")):
        h = as_dict(h)
        hid = as_text(h.get("id"))
        if not hid:
            continue
        host = {"id": hid, "name": as_text(h.get("name"), hid), "kind": "server"}
        if isinstance(h.get("up"), bool):
            host["reachable"] = h["up"]
        if isinstance(h.get("load"), (int, float)) and not isinstance(h.get("load"), bool):
            host["load"] = h["load"]
        hosts.append(host)

    problems, items, services = [], [], []
    for m in as_list(data.get("monitors")):
        m = as_dict(m)
        name = as_text(m.get("name"))
        if not name:
            continue
        up = m.get("up") is True
        items.append({"title": name, "value": "up" if up else "down", "tint": "green" if up else "red"})
        if not up:
            why = as_text(m.get("msg"))
            problems.append({"id": "monitor-%s" % as_text(m.get("id"), name), "severity": "problem",
                             "text": "%s: down%s" % (name, " (%s)" % why if why else "")})
        url = as_text(m.get("url"))
        if url.startswith(("http://", "https://")):
            services.append({"name": name, "url": url, "icon": "globe"})

    cards = [{"id": "monitors", "title": cfg["name"], "icon": "waveform.path.ecg", "style": "list", "place": "lab",
              "items": items}] if items else []
    return {"problems": problems, "hosts": hosts, "cards": cards, "services": services}
