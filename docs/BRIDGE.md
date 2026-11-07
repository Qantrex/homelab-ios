# Homelab Bridge: adding a source

The Homelab Bridge is the [reference server](REFERENCE_SERVER.md) with `sources`: small modules that read another
service's API and add problems, hosts, cards and services to its answers. This page is the recipe for writing one.
What users configure: [REFERENCE_SERVER.md → Sources](REFERENCE_SERVER.md#sources). Why it is built this way:
[plans/MODULAR.md](plans/MODULAR.md) (decisions D1, D5, D6). Running it in Docker with a Tailscale sidecar:
[SERVER-SETUP.md → Docker](SERVER-SETUP.md#docker).

## The contract

A source is one file, `server/sources/<type>.py`. A `-` in the type is a `_` in the file name (`uptime-kuma` →
`uptime_kuma.py`). The server finds it by that name; there is no list to edit.

```python
"""Uptime Kuma: down monitors as problems, one card. Tested against Uptime Kuma 2.5.9 (recordings/uptime-kuma/).

Config: {"name": "Kuma", "type": "uptime-kuma", "url": "http://192.0.2.10:3001", "slug": "home"}
"""

from . import as_dict, as_list, as_text


def check(cfg):                      # optional, runs at start
    if not cfg.get("slug"):
        raise ValueError("slug is required")


def collect(cfg, fetch):            # required, runs every `every` seconds
    data = as_dict(fetch.json("/api/status-page/heartbeat/%s" % cfg["slug"]))
    problems = [...]
    return {"problems": problems, "hosts": [], "cards": [], "services": []}
```

`cfg` is the source's own config object, with `name`, `type`, `every`, `timeout` and `insecure` filled in. `fetch` is
the only way out:

| Call | What it does |
|---|---|
| `fetch(path, method="GET", headers=None, body=None, ok=range(200, 300), timeout=None)` | A `Reply` (`status`, `headers` with lower-case names, `body` bytes, `text`, `json()`). A path is joined to `cfg["url"]`; a full `http(s)://` URL is used as it is. `body` as a dict or list is sent as JSON. A status outside `ok` raises `SourceError("401")`; `ok=None` takes any |
| `fetch.json(path, **kw)` | `fetch(path, **kw).json()`. Not JSON raises `SourceError("answer is not JSON")` |
| `fetch.secret(key="key_env")` | The value of the env variable that `cfg[key]` names. Missing: `SourceError("PVE_TOKEN is not set")` |

Every request has a timeout (`timeout`, and the whole run at most `every`), at most 8 MB, no redirects, no cookies
(send a session id as a header) and no proxy from the environment. TLS uses the system CAs, `ca_file`, or no checks
with `insecure: true`.

`collect` returns a dict with any of these lists. The items are the Companion API's objects (`Problem`, `Host`,
`Card`, `Service` in [`server/openapi.yaml`](../server/openapi.yaml)), with the source's **own** ids:

| Key | Item | The bridge then |
|---|---|---|
| `problems` | `{id, text, severity, host}` or a plain string | prefixes `id` and `host` with `<name>:`; no `id`: one from the text; `severity` defaults to `problem`, unknown values become `warning`; `host` is dropped unless this source sent that host |
| `hosts` | `{id, name, kind, reachable, load, ..., history, container_list}` | prefixes `id`, `name` defaults to the raw id; history series keep their newest 288 points; `restartable` is removed |
| `cards` | `{id, title, style, place, items, ...}` | prefixes `id`; refuses `today` and `departures`; removes `action` on the card and its items; `updated` defaults to the time of the run |
| `services` | `{name, url, group, icon, description}` | `group` defaults to the source's name |

Anything that is not a dict with the needed fields is skipped (and logged). Duplicates keep the first. At most 100
problems, 100 hosts, 50 cards and 100 services. Fields named like a secret (`token`, `password`, `api_key`, ...) are
dropped at any depth, and the values of the source's env variables become `***` wherever they appear.

When `collect` raises (a `SourceError` from `fetch`, or any bug), or returns something that is not a JSON object,
the source becomes exactly **one warning** `<name>: <short error>` (id `<name>:source`) and nothing else. Raise
`SourceError("short text")` yourself for a known failure ("slug not found"). Never put a URL or a key in the text;
URLs are cut out anyway.

## Actions (optional, off by default)

A source may offer actions that change something upstream (Docker restart, Proxmox start and stop: owner decision 6
in [plans/MODULAR.md](plans/MODULAR.md)). They exist only for the items the user lists under `actions` in the
source's config; without that key the module is read-only like any other. A module that offers actions has three
more names:

```python
ACTIONS = {"restart-container": {"label": "Restart a container", "icon": "arrow.clockwise", "destructive": True,
                                 "hint": "...", "part": "Container"}}

def allowed(cfg):                   # from the config only, never from the upstream
    return [{"action": "restart-container", "host": "nas", "item": "sonarr", "label": "sonarr"}]

def act(cfg, fetch, action, host, item):   # one press; the bridge calls it only for an allowed item
    fetch("/containers/%s/restart" % item, method="POST", body=b"")
    return "Restarted sonarr on nas."
```

`sources.SourceActions` turns them into the app's run-actions: `GET /actions` lists each action with one argument
variant per source and host, `POST /actions/<name>` runs one. The argument is `<source>:<host>:<item>` with a host
(the app's container Restart sends `<host id>:<container>`, and host ids are prefixed) or `<source>:<item>`, at most
64 characters (checked at start). The bridge only looks it up in the list from `allowed`; it is never parsed, so
the argv rule `ARG_RE` (no `:`) doesn't apply. It also refuses any payload, takes at most 30 presses an hour and one
press per item at a time. `restartable: true` is set on exactly the containers `allowed` lists for
`restart-container`. A `SourceError` or a crash in `act` is `{"ok": false, "text": "<source>: <item> failed (403)"}`.
`item` and `host` match `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`, so they are safe in a URL path; check them in `act`
anyway. Document the upstream permission each action needs, and keep it to exactly those items.

## Rules for a source module

- Stdlib only. Import the helpers from `.` (`as_list`, `as_dict`, `as_text`, `SourceError`), nothing from
  `reference_server`.
- Talk to the upstream only through `fetch`; read keys only with `fetch.secret()`. No `os.environ`, `subprocess`,
  `urllib`, `socket` or `open(` (a test greps for them).
- Read-only. Never call an endpoint that changes something upstream (Pi-hole's logout after login is fine), except
  in `act` for an item the config lists (see [Actions](#actions-optional-off-by-default)).
- Lenient: every upstream field may be missing or have another type. Use `as_list`, `as_dict`, `as_text`; skip what
  doesn't fit. The odd recording must never crash the source.
- Ids from the upstream's stable ids (monitor id, VM id), not from list positions, so `since` stays put.
- The module's docstring says what it reads, its config keys and the upstream version the recordings come from.
  Check the API paths against the upstream's current docs before you write the code.

## Adding a source, step by step

1. **Copy the template.** `cp server/sources/example.py server/sources/<module>.py`. Change its docstring, `check`
   and `collect`.
2. **Recordings.** `server/recordings/<type>/normal.json` (a typical answer) and `odd.json` (unknown fields, wrong
   types, junk entries, empty lists). More cases are welcome (`down.json`, `auth-failed.json`). The format is in
   [`server/fake_upstream.py`](../server/fake_upstream.py): `{"_about": "...", "routes": {"GET /path": {"status",
   "json" or "body", "headers", "delay", "pad"}}}`. Made up or scrubbed: no real hosts, keys, slugs, names, media
   titles or IPs; use `192.0.2.x`, `nas.tail1234.ts.net`, names like "Kuma" or "pve1".
3. **Tests.** A new file `server/test_source_<module>.py` (one per source, so parallel work doesn't collide) with at
   least: the normal recording gives the expected problems, hosts and cards (ids already prefixed); the odd recording
   gives no error; a failed login or a 401 gives the one warning; the key goes out the way the upstream wants it
   (`FakeUpstream.requests` has the headers). Use `FakeUpstream`, `sources.parse` and `sources.Runner` like
   `ExampleSource` in [`server/test_sources.py`](../server/test_sources.py). `SourceModuleRules` there checks every
   module by itself (docstring, no env, the two recordings).
4. **Registry.** One `[[feature]]` in `features.toml`, area `Server`, `status = "partial"`, `depends_on =
   ["server-sources"]`, its module, recordings and test file in `sources`, the test classes in `tests`, `not_needed =
   { device_tests = "server side; the app sees ordinary Companion data" }`. Then `scripts/features render`.
5. **Docs.** A row in the sources table of [SERVER-SETUP.md](SERVER-SETUP.md) (when it exists) with the config keys and
   what the key needs (read-only token, role).
6. **Check.** `python3 -m unittest -v server/test_*.py`, `scripts/features`, `scripts/lint`, and
   [try it](#try-it) with `scripts/check-live-api`.

## Try it

The fake upstream replays a recording on `127.0.0.1`; the sample config points the `example` source at it:

```bash
python3 server/fake_upstream.py server/recordings/example/normal.json --port 8795 &
HOMELAB_TOKENS=a-local-test-token-123 LAB_KEY=any-made-up-key \
  python3 server/reference_server.py --config server/examples/sources-example.json --port 8793 &
scripts/check-live-api --token a-local-test-token-123 http://127.0.0.1:8793
curl -s -H 'Authorization: Bearer a-local-test-token-123' http://127.0.0.1:8793/api/v1/state
```

`/state` then has the problem `Lab:monitor-3`, the hosts `Lab:pve1` and `Lab:backup` and the card `Lab:monitors`.
For your own source, copy the config, change `type` and `url`, and replay your recording.

## How it runs

`Config` parses `sources` with `sources.parse` (unknown types, bad names and keys in the config stop the server at
start). `RealApp` starts a `sources.Runner`: every 0.25 s it starts each source that is due and not still running,
in its own daemon thread. A run that takes longer than `every + timeout` shows as `<name>: timeout` until it ends.
`/state` and `/services` add `Runner.merged()`, the last result of every source, after the server's own problems,
hosts and cards; the status is the worst of all problems. `/info` lists `cards` and `services` when a source sends
any, and `sources`: `Runner.status()`, per source `state` (`ok`, `failing`, `never`), `error`, `checked`, `last_ok`
and `insecure` ([API.md → Source status](API.md#source-status-sources-in-info); tests in
`server/test_source_status.py`).

The `homepage` key is a pre-processor, not a source type: at start `Config` hands it to
`sources/_homepage.py` (the leading `_` keeps it out of the types), which reads Homepage's `services.yaml` with
PyYAML and returns launcher entries and source configs; they are added to the config's own `services` and
`sources` before `sources.parse` checks them, so imported sources follow every rule above. A Homepage widget
becomes a source through the `WIDGETS` table there: when you add a source that Homepage has a widget for, add a
translator (widget fields to your config keys; keys only through `ctx.secret()`), a row in
[SERVER-SETUP.md → Import from Homepage](SERVER-SETUP.md#import-from-homepage) and a case in
`server/test_homepage_import.py`.
