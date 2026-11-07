"""AdGuard Home: the `dns` card (queries and blocked in the stats period, protection on or off), the top blocked
domains, and a warning while protection is off or the DNS server is not running. Recordings (recordings/adguard/)
have the shapes of AdGuard Home v0.107.80 (openapi/openapi.yaml in the AdGuardHome repo, API 0.107).

Upstream (HTTP basic auth on every request):
    GET  /control/status   -> {"protection_enabled": true, "protection_disabled_duration": 0, "running": true, ...}
    GET  /control/stats    -> {"num_dns_queries": 23410, "num_blocked_filtering": 4300, "time_units": "hours",
                               "top_blocked_domains": [{"ads.example.net": 812}], ...}
    POST /control/protection {"enabled": false, "duration": 300000}   only the opt-in action `dns-pause`

Config:
    {"name": "AdGuard", "type": "adguard", "url": "http://192.0.2.54:3000", "username": "monitor",
     "password_env": "ADGUARD_PASSWORD", "top": 5, "actions": {"pause": [5, 15, 30]}}

username and password_env: an AdGuard Home user (AdGuard has no read-only users or API keys, so the password can
change settings: keep it in the env file only). Without username no auth is sent. `top`: how many blocked domains
(0: no `dns-top` card). `actions`: off unless set; `{"pause": [minutes, ...]}` as for pihole.
"""

import base64

from . import as_dict, as_text
from ._dns import ACTIONS, allowed, check_actions, minutes, number, pause_seconds, result, top_pairs  # noqa: F401


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required")
    if cfg.get("username") is not None and (not isinstance(cfg["username"], str) or not cfg.get("password_env")):
        raise ValueError("username needs password_env (the env variable with the password)")
    top = cfg.get("top", 5)
    if isinstance(top, bool) or not isinstance(top, int) or not 0 <= top <= 20:
        raise ValueError("top must be a whole number from 0 to 20")
    check_actions(cfg)


def _headers(cfg, fetch):
    if not cfg.get("username"):
        return {}
    pair = ("%s:%s" % (cfg["username"], fetch.secret("password_env"))).encode("utf-8")
    return {"Authorization": "Basic " + base64.b64encode(pair).decode("ascii")}


def collect(cfg, fetch):
    h = _headers(cfg, fetch)
    status = as_dict(fetch.json("/control/status", headers=h))
    stats = as_dict(fetch.json("/control/stats", headers=h))
    top = cfg.get("top", 5)
    enabled = status.get("protection_enabled")
    pause_ms = number(status.get("protection_disabled_duration"))
    state = "on" if enabled is True else ("off" if enabled is False else "unknown")
    days = len(stats.get("dns_queries")) if isinstance(stats.get("dns_queries"), list) else 0
    window = "24 h" if as_text(stats.get("time_units")) == "hours" else ("%d days" % days if days > 1 else None)
    out = result(cfg, number(stats.get("num_dns_queries")), number(stats.get("num_blocked_filtering")), None, state,
                 timer=pause_ms / 1000.0 if pause_ms and pause_ms > 0 else None, window=window,
                 top=top_pairs(stats.get("top_blocked_domains"), top, single=True) if top else ())
    if status.get("running") is False:
        out["problems"].append({"id": "running", "severity": "warning",
                                "text": "%s: the DNS server is not running" % cfg["name"]})
    return out


def act(cfg, fetch, action, host, item):
    """`dns-pause` with a listed item: minutes ("5") or "on" (resume). The bridge only calls it for listed items."""
    seconds = pause_seconds(action, item)
    body = {"enabled": True} if seconds is None else {"enabled": False, "duration": seconds * 1000}
    fetch("/control/protection", method="POST", headers=_headers(cfg, fetch), body=body)
    return "%s: protection is on again" % cfg["name"] if seconds is None else \
        "%s: protection paused for %s" % (cfg["name"], minutes(seconds))
