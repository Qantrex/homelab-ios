"""qBittorrent: the running downloads as a Lab card (progress, speed, time left), torrents in error and a lost
connection as warnings. WebUI API v2; recordings (recordings/qbittorrent/) have the shapes of qBittorrent 5.1 / 5.2
(WebUI API v2.11 to v2.14, the "WebUI API (qBittorrent 5.0)" wiki page).

Upstream (read-only):
    with an API key (qBittorrent 5.2 and newer): header Authorization: Bearer <key>, no login
    else: POST /api/v2/auth/login (form username, password; Referer: the url) -> "Ok." and a session cookie
          (SID=..., or QBT_SID_<port>=... in newer versions), sent back as a Cookie header; logout after the run
    GET /api/v2/transfer/info                  -> {"dl_info_speed", "up_info_speed", "connection_status"}
    GET /api/v2/torrents/info?filter=downloading
    GET /api/v2/torrents/info?filter=errored
    POST /api/v2/auth/logout                   (only after a login)

Config:
    {"name": "qBittorrent", "type": "qbittorrent", "url": "http://192.0.2.20:8080", "key_env": "QBIT_API_KEY",
     "limit": 10}
    older versions: "username": "monitor", "password_env": "QBIT_PASSWORD" in place of key_env

key_env: an API key (Preferences > WebUI > API key). `limit`: rows in the card, soonest done first.
"""

from . import SourceError, as_dict, as_list, as_text

ETA_NONE = 8640000   # qBittorrent's "infinite" eta
STATES = {"downloading": "Downloading", "forcedDL": "Downloading", "metaDL": "Getting metadata",
          "forcedMetaDL": "Getting metadata", "stalledDL": "Stalled", "queuedDL": "Queued", "checkingDL": "Checking",
          "allocating": "Allocating", "moving": "Moving", "pausedDL": "Paused", "stoppedDL": "Stopped",
          "error": "Error", "missingFiles": "Files missing"}
SAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required")
    if not cfg.get("key_env") and not (isinstance(cfg.get("username"), str) and cfg.get("password_env")):
        raise ValueError("key_env (an API key) or username and password_env are required")
    limit = cfg.get("limit", 10)
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise ValueError("limit must be a whole number from 1 to 50")


def form(fields):
    """application/x-www-form-urlencoded, by hand (no urllib in a source)."""
    def enc(text):
        return "".join(c if c in SAFE else "".join("%%%02X" % b for b in c.encode("utf-8")) for c in text)
    return "&".join("%s=%s" % (enc(k), enc(v)) for k, v in fields).encode("ascii")


def _login(cfg, fetch):
    """Headers for the other requests, and whether to log out afterwards."""
    if cfg.get("key_env"):
        return {"Authorization": "Bearer " + fetch.secret()}, False
    reply = fetch("/api/v2/auth/login", method="POST", ok=None,
                  headers={"Content-Type": "application/x-www-form-urlencoded", "Referer": fetch.url("/")},
                  body=form([("username", cfg["username"]), ("password", fetch.secret("password_env"))]))
    if reply.status == 403:
        raise SourceError("403 (this address is banned after failed logins)")
    if not 200 <= reply.status < 300:
        raise SourceError(str(reply.status))
    if reply.text.strip() != "Ok.":
        raise SourceError("login failed (check username and password)")
    cookie = as_text(reply.headers.get("set-cookie")).split(";")[0].strip()
    if "=" not in cookie:
        raise SourceError("login gave no session cookie")
    return {"Cookie": cookie, "Referer": fetch.url("/")}, True


def speed(n):
    """Bytes per second as "2.1 MB/s"."""
    if not isinstance(n, (int, float)) or isinstance(n, bool) or n <= 0:
        return ""
    for size, unit in ((1e9, "GB/s"), (1e6, "MB/s")):
        if n >= size:
            return "%.1f %s" % (n / size, unit)
    return "%d kB/s" % (n // 1e3) if n >= 1e3 else "%d B/s" % n


def eta(seconds):
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not 0 < seconds < ETA_NONE:
        return ""
    m = int(seconds // 60)
    if m < 1:
        return "< 1 min"
    if m < 60:
        return "%d min" % m
    h = m // 60
    return "%d h %d min" % (h, m % 60) if h < 24 else "%d d %d h" % (h // 24, h % 24)


def collect(cfg, fetch):
    headers, logout = _login(cfg, fetch)
    try:
        transfer = as_dict(fetch.json("/api/v2/transfer/info", headers=headers))
        running = as_list(fetch.json("/api/v2/torrents/info?filter=downloading", headers=headers))
        errored = as_list(fetch.json("/api/v2/torrents/info?filter=errored", headers=headers))
    finally:
        if logout:
            try:
                fetch("/api/v2/auth/logout", method="POST", headers=headers, body=b"", ok=None)
            except SourceError:
                pass
    name = cfg["name"]
    problems, rows, seen, downloading = [], [], set(), 0
    for i, t in enumerate(errored + running):
        t = as_dict(t)
        title, key = as_text(t.get("name")), as_text(t.get("hash"))
        if not title or not key or key in seen:
            continue
        seen.add(key)
        downloading += 1 if i >= len(errored) else 0
        state = as_text(t.get("state"))
        words = STATES.get(state, state or "Unknown")
        if state in ("error", "missingFiles"):
            problems.append({"id": "torrent-%s" % key[:16], "severity": "warning",
                             "text": "%s: %s: %s" % (name, title, words.lower())})
        item = {"title": title, "subtitle": " · ".join(x for x in (words, speed(t.get("dlspeed"))) if x)}
        p = t.get("progress")
        if isinstance(p, (int, float)) and not isinstance(p, bool):
            item["progress"] = round(min(1.0, max(0.0, p)), 3)
        left = eta(t.get("eta"))
        if left:
            item["value"] = left
        if state in ("error", "missingFiles"):
            item["tint"] = "red"
        rows.append((0 if item.get("tint") else 1, t.get("eta") if left else ETA_NONE, item))
    rows.sort(key=lambda r: (r[0], r[1]))
    items = [r[2] for r in rows[:cfg.get("limit", 10)]]
    if as_text(transfer.get("connection_status")) == "disconnected":
        problems.append({"id": "connection", "severity": "warning", "text": "%s: no connection" % name})
    down, up = speed(transfer.get("dl_info_speed")), speed(transfer.get("up_info_speed"))
    line = " · ".join(x for x in ("%d downloading" % downloading if downloading else "Nothing downloading",
                                  "down %s" % down if down else "", "up %s" % up if up else "") if x)
    return {"problems": problems,
            "cards": [{"id": "downloads", "title": name, "icon": "arrow.down.circle", "style": "list",
                       "place": "lab", "subtitle": line, "items": items}]}
