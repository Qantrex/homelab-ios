"""Pi-hole v6: the `dns` card (queries and blocked in the last 24 h, blocking on or off), the top blocked domains, and
a warning while blocking is off. Recordings (recordings/pihole/) have the shapes of Pi-hole FTL v6.8 (API docs:
https://docs.pi-hole.net/api/ and the FTL OpenAPI specs). v5 and older (`admin/api.php`) are not supported.

Upstream:
    POST   /api/auth {"password": <app password>}   -> {"session": {"valid": true, "sid": "...", "validity": 1800}}
    GET    /api/stats/summary                       header X-FTL-SID: <sid>
    GET    /api/dns/blocking                        -> {"blocking": "enabled", "timer": null}
    GET    /api/stats/top_domains?blocked=true&count=N
    DELETE /api/auth                                logout after every run: Pi-hole allows only a few sessions
    POST   /api/dns/blocking {"blocking": false, "timer": 300}   only the opt-in action `pause`

Config:
    {"name": "Pi-hole", "type": "pihole", "url": "http://192.0.2.53", "key_env": "PIHOLE_APP_PASSWORD",
     "top": 5, "actions": ["pause"]}

key_env names the variable with an **app password** (Settings > Web interface / API > Configure app password), not
the login password. Without key_env the Pi-hole must have no password. `top`: how many blocked domains (0: no
`dns-top` card). `actions`: off unless listed; `["pause"]` puts a "Pause 5 min" (or "Resume") button on the
Blocking row and offers 5, 15 or 30 minutes and "Resume" under Actions.
"""

from . import SourceError, as_dict, as_list, as_text
from ._dns import PAUSE, minutes, number, pause_spec, result, top_pairs

STATES = {"enabled": "on", "disabled": "off", "failed": "failed"}


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required")
    top = cfg.get("top", 5)
    if isinstance(top, bool) or not isinstance(top, int) or not 0 <= top <= 20:
        raise ValueError("top must be a whole number from 0 to 20")


def actions(cfg):
    return {"pause": pause_spec(cfg)}


def _login(cfg, fetch):
    """The session id, or None for a Pi-hole without a password."""
    if not cfg.get("key_env"):
        return None
    reply = fetch("/api/auth", method="POST", body={"password": fetch.secret()}, ok=None)
    if reply.status == 401:
        raise SourceError("401 (check the app password)")
    if reply.status == 429:
        raise SourceError("429 (too many logins or sessions)")
    if not 200 <= reply.status < 300:
        raise SourceError(str(reply.status))
    session = as_dict(as_dict(reply.json()).get("session"))
    if session.get("valid") is not True:
        raise SourceError("login refused: %s" % (as_text(session.get("message")) or "no valid session"))
    sid = session.get("sid")
    return sid if isinstance(sid, str) and sid else None


def _session(cfg, fetch, work):
    """Log in, run work(headers), always log out."""
    sid = _login(cfg, fetch)
    headers = {"X-FTL-SID": sid} if sid else {}
    try:
        return work(headers)
    finally:
        if sid:
            try:
                fetch("/api/auth", method="DELETE", headers=headers, ok=None)
            except SourceError:
                pass   # the session runs out by itself


def collect(cfg, fetch):
    top = cfg.get("top", 5)

    def work(h):
        summary = as_dict(fetch.json("/api/stats/summary", headers=h))
        blocking = as_dict(fetch.json("/api/dns/blocking", headers=h))
        domains = as_dict(fetch.json("/api/stats/top_domains?blocked=true&count=%d" % top, headers=h)) if top else {}
        return summary, blocking, domains

    summary, blocking, domains = _session(cfg, fetch, work)
    q = as_dict(summary.get("queries"))
    state = STATES.get(as_text(blocking.get("blocking")), "unknown")
    timer = number(blocking.get("timer"))
    return result(cfg, number(q.get("total")), number(q.get("blocked")), number(q.get("percent_blocked")), state,
                  timer=timer if timer and timer > 0 else None, window="24 h",
                  top=top_pairs(as_list(domains.get("domains")), top))


def act(cfg, fetch, name, arg):
    """`pause`: arg "5", "15", "30" (minutes) or "on"."""
    seconds = PAUSE[arg]
    body = {"blocking": True, "timer": None} if seconds is None else {"blocking": False, "timer": seconds}
    _session(cfg, fetch, lambda h: fetch("/api/dns/blocking", method="POST", headers=h, body=body))
    return "%s: blocking is on again" % cfg["name"] if seconds is None else \
        "%s: blocking paused for %s" % (cfg["name"], minutes(seconds))
