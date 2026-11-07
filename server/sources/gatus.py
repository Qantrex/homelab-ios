"""Gatus: failing endpoints as problems, plus one summary card.

Reads Gatus' read-only API, the call its own dashboard makes:

    GET <url>/api/v1/endpoints/statuses?pageSize=3
    [{"name", "group", "key", "results": [{"status", "hostname", "duration" (ns), "conditionResults":
      [{"condition": "[STATUS] (502) == 200", "success": false}], "errors", "success", "timestamp"}]}]

Results come oldest first; the last one counts. External endpoints are in the same list. `pageSize` is the number of
results per endpoint (every endpoint is always listed).
Tested against the code of Gatus v5.38.0 (api/endpoint_status.go, config/endpoint/status.go and result.go) and the
answer of its public demo; the recordings in server/recordings/gatus/ are made up in that shape.

Config:
    {"name": "Gatus", "type": "gatus", "url": "http://192.0.2.10:8080"}
    optional: "slow_ms": 2000          an endpoint that passes but took longer than this is a warning (off by default)
              "user": "bridge", "password_env": "GATUS_PASSWORD"
                                       only when Gatus has `security.basic`: HTTP Basic with that user and the plain
                                       password (Gatus keeps only its bcrypt hash). OIDC can't be used by the bridge.

What it gives:
    problems  failing endpoint: problem "api: down ([STATUS] (502) == 200)", the first failed condition;
              failing only on [RESPONSE_TIME]: warning "api: slow ([RESPONSE_TIME] (812) < 500)"; failing only on
              [CERTIFICATE_EXPIRATION] or [DOMAIN_EXPIRATION]: warning "api: certificate expires soon (...)" or
              "domain expires soon (...)";
              passing but slower than slow_ms: warning "api: slow (2300 ms)"
    cards     one list card in Lab, "11 of 12 up", a row per endpoint with its group and response time
The error texts (`errors`) are not shown: they hold the endpoint's URL.
"""

import base64

from . import as_dict, as_list, as_text

RESULTS = 3
SOFT = {"[RESPONSE_TIME]": "slow", "[CERTIFICATE_EXPIRATION]": "certificate expires soon",
        "[DOMAIN_EXPIRATION]": "domain expires soon"}


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def check(cfg):
    if not cfg.get("url"):
        raise ValueError("url is required (the Gatus address, e.g. http://192.0.2.10:8080)")
    if "slow_ms" in cfg and (_number(cfg["slow_ms"]) is None or cfg["slow_ms"] < 0):
        raise ValueError("slow_ms must be a number, at least 0")
    if bool(cfg.get("user")) != bool(cfg.get("password_env")):
        raise ValueError("user and password_env go together (Gatus security.basic)")
    if "user" in cfg and (not isinstance(cfg["user"], str) or ":" in cfg["user"]):
        raise ValueError("user must be text without ':'")


def _headers(cfg, fetch):
    if not cfg.get("user"):
        return {}
    pair = "%s:%s" % (cfg["user"], fetch.secret("password_env"))
    return {"Authorization": "Basic " + base64.b64encode(pair.encode("utf-8")).decode("ascii")}


def _verdict(result):
    """(severity or None, short reason) of one result."""
    if result.get("success") is True:
        return None, ""
    failed = [as_text(as_dict(c).get("condition")).strip() for c in as_list(result.get("conditionResults"))
              if as_dict(c).get("success") is False]
    failed = [c for c in failed if c]
    soft = [next((w for k, w in SOFT.items() if c.startswith(k)), None) for c in failed]
    if failed and all(soft) and not as_list(result.get("errors")):
        return "warning", "%s (%s)" % (soft[0], failed[0][:80])
    return "problem", ("down (%s)" % failed[0][:80]) if failed else "down"


def collect(cfg, fetch):
    data = fetch.json("/api/v1/endpoints/statuses?pageSize=%d" % RESULTS, headers=_headers(cfg, fetch))
    slow_ms = _number(cfg.get("slow_ms")) or 0
    problems, items, seen = [], [], set()
    counts = {"up": 0, "all": 0}
    for ep in as_list(data):
        ep = as_dict(ep)
        name, group = as_text(ep.get("name")).strip(), as_text(ep.get("group")).strip()
        key = as_text(ep.get("key")).strip() or ("%s_%s" % (group, name) if name else "")
        if not name or key in seen:
            continue
        seen.add(key)
        counts["all"] += 1
        results = [as_dict(r) for r in as_list(ep.get("results")) if isinstance(as_dict(r).get("success"), bool)]
        last = results[-1] if results else None
        pid = "endpoint-%s" % key
        item = {"title": name}
        ms = None
        if last is None:
            item.update(value="no data", tint="gray")
        else:
            ns = _number(last.get("duration"))
            ms = ns / 1e6 if ns is not None and ns > 0 else None   # external endpoints: 0
            severity, why = _verdict(last)
            if severity == "problem":
                item.update(value="down", tint="red")
                problems.append({"id": pid, "severity": "problem", "text": "%s: %s" % (name, why)})
            elif severity == "warning":
                counts["up"] += 1
                item.update(value=why.split()[0], tint="orange")
                problems.append({"id": pid, "severity": "warning", "text": "%s: %s" % (name, why)})
            elif slow_ms and ms is not None and ms > slow_ms:
                counts["up"] += 1
                item.update(value="slow", tint="orange")
                problems.append({"id": pid, "severity": "warning", "text": "%s: slow (%d ms)" % (name, round(ms))})
            else:
                counts["up"] += 1
                item.update(value="up", tint="green")
        parts = [group] if group else []
        if ms is not None and item["value"] != "down":
            parts.append("%d ms" % round(ms))
        if parts:
            item["subtitle"] = " · ".join(parts)
        items.append(item)

    cards = [{"id": "monitors", "title": cfg["name"], "subtitle": "%d of %d up" % (counts["up"], counts["all"]),
              "icon": "waveform.path.ecg", "style": "list", "place": "lab", "items": items}] if items else []
    return {"problems": problems, "cards": cards}
