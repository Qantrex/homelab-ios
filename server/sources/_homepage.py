"""Import from Homepage (gethomepage.dev): its services.yaml as launcher entries and sources of the Homelab Bridge.

Not a source type (the leading _ keeps it out of the types): a config pre-processor. reference_server.Config calls
load() once at start when the config has a `homepage` key, and adds what it returns to its own `services` and
`sources` before it checks them. Edits to services.yaml need a restart of the bridge. Docs:
docs/SERVER-SETUP.md#import-from-homepage.

    "homepage": {"file": "/homepage/services.yaml"}
    optional: "sources": false     only the launcher, no sources from widgets
              "every": 60          seconds between two reads of each imported source
              "skip": ["Plex", "Media"]   services or groups (their names, any case) to leave out
              "extra": {"Proxmox": {"ca_file": "/certs/pve-root-ca.pem"}}
                                   more keys for the source made from that service's widget (insecure, ca_file,
                                   expect_running, actions, ...); checked like any source's keys, no keys in it

services.yaml (Homepage v1.x): a list of groups, each `{group name: [entries]}`; an entry is `{service name: {href,
icon, description, widget: {type, url, ...}, widgets: [...], ...}}`, or a nested group `{name: [entries]}`.
Homepage replaces `{{HOMEPAGE_VAR_X}}` with the env variable HOMEPAGE_VAR_X and `{{HOMEPAGE_FILE_X}}` with the content
of the file that HOMEPAGE_FILE_X names, in the raw text before it parses the YAML. Here:

  - every service with an http(s) `href` becomes a launcher entry {name, url, group (the innermost group), icon (an
    SF Symbol for well-known Homepage icon names, else none), description}. Placeholders in these fields are
    replaced from the bridge's env; a service whose href would hold a key (a user, a password or a key in the query,
    or a placeholder named like a key) is left out.
  - a widget whose `type` is in WIDGETS (uptimekuma, gatus, proxmox, pihole v6, adguard, sonarr, radarr,
    qbittorrent) becomes a source of that type, never with `actions`. Its keys must be placeholders: the source gets
    the variable's name (`password_env: HOMEPAGE_VAR_GATUS_PASSWORD`), never the value. A key written in
    services.yaml itself stops the start with a ConfigError that says how to move it to the env; the key is never
    printed. A Pi-hole v5 widget is logged as not supported; other widget types as not yet supported.
  - PyYAML reads the file. The Docker image of the Homelab Bridge has it; reference_server.py alone stays stdlib-only
    and, without PyYAML, stops with a message that says what is missing (owner decision 3, docs/plans/MODULAR.md).
"""

import math
import os
import re
import urllib.parse

from . import NAME_RE, SECRET_QUERY, known_types, load_type

MAX_FILE = 1024 * 1024
MAX_SECRET_FILE = 64 * 1024
MAX_ENTRIES = 2000
MAX_DEPTH = 6
MAX_NOTES = 100
OPTION_KEYS = ("file", "sources", "every", "skip", "extra")

# {{HOMEPAGE_VAR_X}} as Homepage writes it (no spaces; Homepage replaces the literal text). Before the YAML is parsed
# each one becomes a marker that YAML reads as plain text in any position ({{...}} unquoted would be a YAML mapping).
PLACEHOLDER = re.compile(r"\{\{(HOMEPAGE_(?:VAR|FILE)_[A-Za-z0-9_]+)\}\}")
MARK_OPEN, MARK_CLOSE = "⦃", "⦄"
MARKER = re.compile(MARK_OPEN + r"(HOMEPAGE_(?:VAR|FILE)_[A-Za-z0-9_]+)" + MARK_CLOSE)
SECRET_NAME = re.compile(r"(?i)(key|token|pass|secret|auth)")

# Homepage icon name (lower case, without extension, mdi-/si-/sh- prefix, -light/-dark and dashes) -> SF Symbol.
ICONS = {}
for _symbol, _names in {
    "house": "homeassistant home homebridge openhab hass",
    "play.rectangle": "jellyfin plex emby kodi youtube jellyseerr overseerr tautulli",
    "tv": "sonarr",
    "film": "radarr",
    "music.note": "lidarr navidrome spotify",
    "book": "readarr calibre calibreweb kavita komga",
    "headphones": "audiobookshelf",
    "magnifyingglass": "prowlarr jackett",
    "arrow.down.circle": "qbittorrent transmission deluge sabnzbd nzbget",
    "shield": "pihole adguard adguardhome",
    "server.rack": "proxmox proxmoxve proxmoxbackupserver esxi unraid",
    "externaldrive": "truenas synology openmediavault nas minio",
    "shippingbox": "docker portainer dockge yacht",
    "waveform.path.ecg": "uptimekuma gatus healthchecks netdata glances scrutiny",
    "chart.xyaxis.line": "grafana prometheus influxdb",
    "network": "router unifi opnsense pfsense openwrt traefik nginxproxymanager caddy tailscale wireguard",
    "cloud": "nextcloud owncloud seafile syncthing",
    "doc.text": "paperless paperlessngx stirlingpdf",
    "photo": "immich photoprism photos",
    "key": "vaultwarden bitwarden authentik authelia keycloak",
    "chevron.left.forwardslash.chevron.right": "gitea forgejo gitlab github codeserver vscode",
    "envelope": "mail mailcow roundcube",
    "video": "frigate scrypted zoneminder camera",
    "fork.knife": "mealie tandoor",
    "printer": "octoprint printer",
    "dot.radiowaves.left.and.right": "freshrss miniflux rss",
}.items():
    for _name in _names.split():
        ICONS[_name] = _symbol


class Unsupported(Exception):
    """Raised by a translator for a widget the bridge can't read (Pi-hole v5): the widget is skipped with this reason
    in the log, nothing guessed. Its text never holds a key."""


class ImportFailed(ValueError):
    """The import can't go on: no PyYAML, an unreadable file, a key written in services.yaml. Its text is shown
    as the reason the server did not start; it never holds a key."""


# --------------------------------------------------------------------------------------------- widget types

def _kuma(widget, ctx):
    return {"type": "uptime-kuma", "url": ctx.public(widget, "url"), "slug": ctx.public(widget, "slug"),
            "services": False}   # Homepage's own entries are the launcher; the monitors' links would repeat them


def _gatus(widget, ctx):
    out = {"type": "gatus", "url": ctx.public(widget, "url")}
    # Homepage's generic proxy sends HTTP Basic when username and password are both set.
    password = ctx.secret(widget, "password")
    user = ctx.public(widget, "username") if widget.get("username") is not None else ""
    if user and password:
        out["user"], out["password_env"] = user, password
    return out


def _proxmox(widget, ctx):
    # Homepage's proxmox widget: username is the API token's id (user@realm!id), password its secret. `node` is not
    # needed: the source reads every node the token can see.
    return {"type": "proxmox", "url": ctx.public(widget, "url"), "token_id": ctx.public(widget, "username"),
            "key_env": ctx.secret(widget, "password")}


def _pihole(widget, ctx):
    # Homepage talks to the v5 API (admin/api.php) unless `version` is 6 or more (`!version || version < 6` in its
    # proxy); the bridge reads only v6. Checked before the key, so a v5 widget's key is never read. In v6 Homepage's
    # `key` is the password or an app password; /api/auth takes both.
    version = ctx.public(widget, "version")
    if ctx.missing:
        return {"type": "pihole"}   # a placeholder in version is not set: skipped with that note, not called v5
    number = 0
    if version not in (None, "", 0):
        try:
            number = float(version) if not isinstance(version, bool) else math.nan
        except (TypeError, ValueError):
            number = math.nan
        if not math.isfinite(number):
            raise Unsupported("its version is not a number; the bridge reads Pi-hole v6 and newer (version: 6)")
    if number < 6:
        raise Unsupported("Pi-hole v5 or older (no version: 6 in the widget); the bridge reads Pi-hole v6 and newer")
    return {"type": "pihole", "url": ctx.public(widget, "url"), "key_env": ctx.secret(widget, "key")}


def _adguard(widget, ctx):
    # Homepage's generic proxy sends HTTP Basic when username and password are both set, as for gatus.
    out = {"type": "adguard", "url": ctx.public(widget, "url")}
    password = ctx.secret(widget, "password")
    user = ctx.public(widget, "username") if widget.get("username") is not None else ""
    if user and password:
        out["username"], out["password_env"] = user, password
    return out


def _arr(kind):
    def translate(widget, ctx):
        # Homepage sends `key` as X-Api-Key, as the bridge does; enableQueue only changes Homepage's own view.
        return {"type": kind, "url": ctx.public(widget, "url"), "key_env": ctx.secret(widget, "key")}
    return translate


def _qbittorrent(widget, ctx):
    # Homepage sends `key` as a Bearer token (qBittorrent 5.2 and newer) and logs in with username and password only
    # when there is no key; the bridge does the same. Every key field written is checked, used or not.
    key = ctx.secret(widget, "key")
    password = ctx.secret(widget, "password")
    out = {"type": "qbittorrent", "url": ctx.public(widget, "url")}
    if key:
        out["key_env"] = key
    elif password and widget.get("username") is not None:
        out["username"], out["password_env"] = ctx.public(widget, "username"), password
    return out


# Homepage widget type -> (bridge source type, translator). A translator returns the source's config without name and
# every; it reads keys only through ctx.secret() and never sets `actions` (pausing an ad blocker stays opt-in by hand
# in the bridge's config). It raises Unsupported for a widget the bridge can't read (Pi-hole v5). Types whose bridge
# source is not in server/sources/ yet are listed as "not yet supported", the same as unknown ones.
WIDGETS = {
    "uptimekuma": ("uptime-kuma", _kuma),
    "gatus": ("gatus", _gatus),
    "proxmox": ("proxmox", _proxmox),
    "pihole": ("pihole", _pihole),
    "adguard": ("adguard", _adguard),
    "sonarr": ("sonarr", _arr("sonarr")),
    "radarr": ("radarr", _arr("radarr")),
    "qbittorrent": ("qbittorrent", _qbittorrent),
}


# --------------------------------------------------------------------------------------------- reading

def read_yaml(path):
    """The parsed services.yaml with every placeholder turned into a marker. ImportFailed with a clear text when
    PyYAML is missing or the file can't be read."""
    try:
        import yaml  # noqa: PLC0415 - optional: only the Docker image has it
    except ImportError:
        raise ImportFailed("homepage: reading %s needs PyYAML, which this Python does not have. The Homelab Bridge "
                           "Docker image has it; otherwise install it (pip install pyyaml, or the python3-yaml "
                           "package) or remove the \"homepage\" key from the config" % os.path.basename(path))
    try:
        with open(path, "rb") as fh:
            raw = fh.read(MAX_FILE + 1)
    except OSError as exc:
        raise ImportFailed("homepage: cannot read %s (%s)" % (path, exc.strerror or exc.__class__.__name__))
    if len(raw) > MAX_FILE:
        raise ImportFailed("homepage: %s is larger than 1 MB" % path)
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise ImportFailed("homepage: %s is not UTF-8" % path)
    text = PLACEHOLDER.sub(lambda m: MARK_OPEN + m.group(1) + MARK_CLOSE, text)
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        where = " (line %d)" % (mark.line + 1) if mark is not None else ""
        # Only the position: the problem text can quote the line, and a line can hold a key.
        raise ImportFailed("homepage: %s is not valid YAML%s" % (os.path.basename(path), where))


def _label(value):
    """A group or service name from YAML: text as it is, numbers as text, anything else None."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (str, int, float)):
        text = " ".join(MARKER.sub(r"\1", str(value)).split())
        return text or None
    return None


def _env_word(text):
    return re.sub(r"[^A-Z0-9]+", "_", text.upper()).strip("_") or "SERVICE"


def icon_for(value):
    """An SF Symbol for a Homepage icon ("sonarr.png", "mdi-sonarr", "si-jellyfin", "https://.../plex.svg"), or None."""
    if not isinstance(value, str) or not value:
        return None
    name = value.rsplit("/", 1)[-1].lower()
    name = re.sub(r"\.(png|svg|webp|jpe?g|ico)$", "", name)
    name = re.sub(r"^(mdi|si|sh)-", "", name)
    name = re.sub(r"-(light|dark)$", "", name)
    return ICONS.get(re.sub(r"[^a-z0-9]", "", name))


class _Context:
    """Reads one widget: public fields with their placeholders filled from the env, keys as variable names."""

    def __init__(self, where, service, env, res):
        self.where = where
        self.service = service
        self.env = env
        self.res = res   # res.env: HOMEPAGE_FILE_X -> the file's content, for the source's *_env
        self.missing = set()

    def file_value(self, var):
        """The content of the file that HOMEPAGE_FILE_X names, without the newline at its end ("" when unreadable:
        the variable then counts as not set, also for the source, never the path as the key)."""
        if var in self.res.env:
            return self.res.env[var]
        path = self.env.get(var, "")
        value = ""
        if path:
            try:
                with open(os.path.expanduser(path), "rb") as fh:
                    value = fh.read(MAX_SECRET_FILE).decode("utf-8", "replace").strip()
            except OSError:
                self.res.notes.append("%s: cannot read the file that %s names" % (self.where, var))
        self.res.env[var] = value
        return value

    def value(self, var):
        return self.file_value(var) if var.startswith("HOMEPAGE_FILE_") else self.env.get(var, "")

    def fill(self, text):
        """A public text with its placeholders filled; a missing variable is remembered (the widget is skipped)."""
        def one(m):
            value = self.value(m.group(1))
            if not value:
                self.missing.add(m.group(1))
            return value
        return MARKER.sub(one, text)

    def public(self, widget, field):
        value = widget.get(field)
        if value is None:
            return None
        if isinstance(value, bool) or not isinstance(value, (str, int, float)):
            return value   # left as it is; the source's check() refuses it
        return self.fill(str(value)).strip()

    def secret(self, widget, field):
        """The env variable name for a key field, or None when the field is not set. A key written in the file
        itself raises ImportFailed; its value is never part of the text."""
        value = widget.get(field)
        if value is None or value == "":
            return None
        if isinstance(value, str):
            m = MARKER.fullmatch(value.strip())
            if m:
                var = m.group(1)
                if var.startswith("HOMEPAGE_FILE_"):
                    self.file_value(var)
                return var
        suggest = "HOMEPAGE_VAR_%s_%s" % (_env_word(self.service), _env_word(field))
        raise ImportFailed(
            "homepage: %s: the widget's %s is written in services.yaml. The bridge reads keys only from env "
            "variables: set %s (for Homepage and the bridge) and write \"{{%s}}\" as the %s in services.yaml "
            "instead, or leave this service out with \"skip\"" % (self.where, field, suggest, suggest, field))


# --------------------------------------------------------------------------------------------- import

class Result:
    def __init__(self):
        self.services = []   # launcher entries, as in the config's `services`
        self.sources = []    # source configs, as in the config's `sources`
        self.env = {}        # HOMEPAGE_FILE_X -> content: the values of file placeholders used as keys
        self.notes = []      # one line per thing not imported, or imported as a source (for the log)


def options(raw):
    """The `homepage` config object, checked. ImportFailed for a bad one."""
    if not isinstance(raw, dict):
        raise ImportFailed("homepage must be an object: {\"file\": \"/path/to/services.yaml\"}")
    opts = {k: v for k, v in raw.items() if not str(k).startswith("_")}
    for k in opts:
        if k not in OPTION_KEYS:
            raise ImportFailed("homepage.%s is not a known key (known: %s)" % (k, ", ".join(OPTION_KEYS)))
    path = opts.get("file")
    if not isinstance(path, str) or not path:
        raise ImportFailed("homepage.file must be the path of Homepage's services.yaml")
    with_sources = opts.get("sources", True)
    if not isinstance(with_sources, bool):
        raise ImportFailed("homepage.sources must be true or false")
    every = opts.get("every", 60)
    if isinstance(every, bool) or not isinstance(every, (int, float)) or every < 1:
        raise ImportFailed("homepage.every must be a number of seconds, at least 1")
    skip = opts.get("skip", [])
    if not isinstance(skip, list) or not all(isinstance(s, str) for s in skip):
        raise ImportFailed("homepage.skip must be a list of service or group names")
    extra = opts.get("extra", {})
    if not isinstance(extra, dict) or not all(isinstance(v, dict) for v in extra.values()):
        raise ImportFailed("homepage.extra must map service names to objects of source keys, e.g. "
                           "{\"Proxmox\": {\"ca_file\": \"/certs/pve-root-ca.pem\"}}")
    for name, keys in extra.items():
        for k in keys:
            if k in ("name", "type"):
                raise ImportFailed("homepage.extra[%s].%s can't be changed" % (name, k))
    return {"file": os.path.expanduser(path), "sources": with_sources, "every": every,
            "skip": {" ".join(s.split()).lower() for s in skip},
            "extra": {" ".join(str(k).split()).lower(): v for k, v in extra.items()}}


def _source_name(service, taken):
    name = re.sub(r"[^A-Za-z0-9 _.-]", "", service)
    name = re.sub(r"^[^A-Za-z0-9]+", "", " ".join(name.split()))[:40].rstrip() or "Homepage"
    base, n = name, 1
    while name.lower() in taken or not NAME_RE.fullmatch(name):
        n += 1
        suffix = " %d" % n
        name = base[:40 - len(suffix)].rstrip() + suffix
    taken.add(name.lower())
    return name


def _secret_var(var):
    """A placeholder variable named like a key (HOMEPAGE_VAR_SONARR_KEY): its value never goes into a reply."""
    return bool(SECRET_NAME.search(re.sub(r"^HOMEPAGE_(VAR|FILE)_", "", var)))


def _url_holds_key(url):
    try:
        u = urllib.parse.urlsplit(url)
        return bool(u.username or u.password or SECRET_QUERY.search(u.query))
    except ValueError:
        return False   # not a URL: the href check or the source's own check refuses it


def convert(data, env, opts, taken_names=(), own_services=()):
    """services.yaml (as read_yaml gives it) -> Result. Lenient: an entry that doesn't fit is skipped with a note."""
    if data is None:
        data = []
    if not isinstance(data, list):
        raise ImportFailed("homepage: services.yaml must be a list of groups (- Group name: [...])")
    res = Result()
    taken = {str(n).lower() for n in taken_names}
    have = {(s.get("name"), s.get("url")) for s in own_services if isinstance(s, dict)}
    available = set(known_types())
    count = [0]
    used_extra = set()

    def skipped(names):
        return any(n.lower() in opts["skip"] for n in names if n)

    def entries(items, groups, depth):
        for item in items if isinstance(items, list) else []:
            count[0] += 1
            if count[0] > MAX_ENTRIES:
                if count[0] == MAX_ENTRIES + 1:
                    res.notes.insert(0, "stopped after %d entries" % MAX_ENTRIES)
                return
            if not isinstance(item, dict) or len(item) != 1:
                res.notes.append("%s: an entry that is not `- Name: ...` skipped" % (" / ".join(groups) or "top"))
                continue
            (key, body), = item.items()
            name = _label(key)
            if name is None:
                res.notes.append("%s: an entry without a name skipped" % " / ".join(groups))
                continue
            if skipped(groups + [name]):
                continue
            if isinstance(body, list):
                if depth >= MAX_DEPTH:
                    res.notes.append("%s: nested too deep, skipped" % " / ".join(groups + [name]))
                else:
                    entries(body, groups + [name], depth + 1)
            elif isinstance(body, dict):
                service(name, body, groups)
            elif body is not None:
                res.notes.append("%s: not a service, skipped" % " / ".join(groups + [name]))

    def service(name, body, groups):
        where = " / ".join(groups + [name])
        group = groups[-1] if groups else None
        ctx = _Context(where, name, env, res)
        href = body.get("href")
        if isinstance(href, str) and href.strip():
            raw_desc = body["description"] if isinstance(body.get("description"), str) else ""
            used = MARKER.findall(href) + MARKER.findall(raw_desc)
            url = ctx.fill(href).strip()
            desc = ctx.fill(raw_desc).strip()
            if any(_secret_var(v) for v in used) or _url_holds_key(url):
                res.notes.append("%s: launcher entry skipped, its address would hold a key" % where)
            elif ctx.missing:
                res.notes.append("%s: launcher entry skipped, %s is not set" % (where, ", ".join(sorted(ctx.missing))))
            elif not re.match(r"^https?://[^/\s]", url, re.I):
                res.notes.append("%s: launcher entry skipped, href is not an http(s) address" % where)
            elif (name, url) not in have:
                entry = {"name": name, "url": url}
                if group:
                    entry["group"] = group
                icon = icon_for(body.get("icon"))
                for widget in _widgets(body) if icon is None else []:
                    icon = icon_for(widget.get("type")) if isinstance(widget, dict) else None
                    if icon:
                        break
                if icon:
                    entry["icon"] = icon
                if desc:
                    entry["description"] = desc
                have.add((name, url))
                res.services.append(entry)
        if not opts["sources"]:
            return
        for widget in _widgets(body):
            widget_source(where, name, widget)

    def widget_source(where, name, widget):
        if not isinstance(widget, dict) or not isinstance(widget.get("type"), str):
            res.notes.append("%s: a widget without a type skipped" % where)
            return
        kind = widget["type"]
        mapping = WIDGETS.get(kind)
        if mapping is None or mapping[0] not in available:
            res.notes.append("%s: widget %s is not yet supported by the Homelab Bridge" % (where, kind[:40]))
            return
        bridge_type, translate = mapping
        ctx = _Context(where, name, env, res)
        try:
            cfg = {k: v for k, v in translate(widget, ctx).items() if v is not None}
        except Unsupported as exc:
            res.notes.append("%s: widget %s is not supported by the Homelab Bridge: %s" % (where, kind, exc))
            return
        extra = opts["extra"].get(name.lower())
        if extra is not None:
            used_extra.add(name.lower())
            cfg.update({k: v for k, v in extra.items() if not str(k).startswith("_")})
        if ctx.missing:
            res.notes.append("%s: widget %s skipped, %s is not set" % (where, kind, ", ".join(sorted(ctx.missing))))
            return
        if isinstance(cfg.get("url"), str) and _url_holds_key(cfg["url"]):
            raise ImportFailed("homepage: %s: the widget's url holds a user, a password or a key. The bridge reads "
                               "keys only from env variables: see docs/SERVER-SETUP.md#import-from-homepage" % where)
        try:
            check = getattr(load_type(bridge_type), "check", None)
            if callable(check):
                check(dict(cfg))
        except ValueError as exc:
            res.notes.append("%s: widget %s skipped (%s)" % (where, kind, exc))
            return
        source_name = _source_name(name, taken)
        res.sources.append(dict({"name": source_name}, every=opts["every"], **cfg))
        res.notes.append("%s: widget %s is the source %r (%s)" % (where, kind, source_name, bridge_type))

    for group in data:
        if not isinstance(group, dict) or len(group) != 1:
            res.notes.append("top: an entry that is not `- Group name: [...]` skipped")
            continue
        (key, body), = group.items()
        gname = _label(key)
        if gname is None or skipped([gname]):
            continue
        if isinstance(body, list):
            entries(body, [gname], 1)
        elif isinstance(body, dict):
            service(gname, body, [])   # a service at the top level; Homepage itself wants a group
        elif body is not None:
            res.notes.append("%s: not a group, skipped" % gname)
    for name in sorted(set(opts["extra"]) - used_extra):
        res.notes.append("extra: no imported source for the service %r" % name)
    return res


def _widgets(body):
    out = []
    if isinstance(body.get("widget"), dict):
        out.append(body["widget"])
    if isinstance(body.get("widgets"), list):
        out.extend(body["widgets"])
    return out


def load(raw, env, taken_names=(), own_services=(), logf=lambda m: None):
    """The `homepage` config object -> Result. Logs what was imported and what not; raises ImportFailed."""
    opts = options(raw)
    res = convert(read_yaml(opts["file"]), env, opts, taken_names, own_services)
    logf("homepage: %d launcher entries and %d sources from %s"
         % (len(res.services), len(res.sources), os.path.basename(opts["file"])))
    notes = res.notes
    if len(notes) > MAX_NOTES:
        notes = notes[:MAX_NOTES - 1] + ["%d more lines like these" % (len(notes) - MAX_NOTES + 1)]
    for note in notes:
        logf("homepage: " + note)
    return res
