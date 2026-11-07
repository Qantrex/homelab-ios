"""Game servers: Minecraft Java and every Valve A2S server (Valheim, Palworld, CS2, Rust, ARK, ...), read with their
public status ping. Not an HTTP source: it opens its own TCP or UDP sockets and ignores `fetch`.

A status ping never wakes or changes anything. Minecraft: the Server List Ping (handshake with next state 1, status
request, read the JSON, close; never a login and never the ping packet), so a router such as itzg/mc-router that
answers for a sleeping backend answers the ping itself and the backend stays asleep. A2S: A2S_INFO (and, with
`players: true`, A2S_PLAYER), the query every server browser sends. There is no wake action.

Config (one source, many servers):
    {"name": "Games", "type": "gameserver", "servers": [
      {"name": "Survival", "type": "minecraft", "host": "mc.example.com", "port": 25565},
      {"name": "Valheim", "type": "a2s", "host": "nas.tail1234.ts.net", "port": 2457, "players": true,
       "expect_up": true}]}

    servers[].name       shown name, unique in the source
    servers[].type       "minecraft" or "a2s"
    servers[].host       a host name or IP address (no URL)
    servers[].port       default 25565 (minecraft) or 27015 (a2s). A2S wants the *query* port, which for some games
                         is not the game port (Valheim: game port + 1)
    servers[].players    a2s only, default false: also ask A2S_PLAYER for the names
    servers[].handshake_host   minecraft only: the address the ping claims to connect to, for a router that
                         chooses the backend by name (default: host)
    servers[].expect_up  default false: a server that does not answer is a problem. Without it a server that is
                         down is only shown as Offline, because game servers sleep and stop

What it gives: one list card in Lab, a row per server: "Running · 2/10 · Paper 26.3 · alice, bob +1", "Sleeping" when
the MOTD says the server sleeps (a router answers for it), "Offline" when it does not answer. Problems only for
`expect_up` servers that do not answer. One bad server (silence, junk, a huge or endless answer) is Offline and never
touches the others. Each server gets at most TIMEOUT seconds in all, and answers are capped in size.
"""

import json
import re
import socket
import struct
import threading
import time
import unicodedata

from . import SourceError, as_dict, as_list, as_text, safe_text, short_error

TIMEOUT = 4.0              # seconds for one server, DNS and all
MAX_SERVERS = 30
MAX_PACKET = 512 * 1024    # a Minecraft status packet (a favicon is about 10 KB)
MAX_TEXT_IN = 4000         # characters of a MOTD read before it is cut
MAX_SAMPLE = 100           # players looked at
SHOWN_PLAYERS = 5
NAME_LEN = 24
MOTD_LEN = 80
DEFAULTS = {"minecraft": 25565, "a2s": 27015}
SLEEPING = re.compile(r"\b(sleeping|asleep|sleeps|hibernating|suspended)\b", re.I)
STARTING = re.compile(r"\b(starting|waking|booting)\b", re.I)
SERVER_KEYS = ("name", "type", "host", "port", "players", "handshake_host", "expect_up")
HOST_RE = re.compile(r"^[A-Za-z0-9_.:\-\[\]%]{1,253}$")   # names, IPv4, IPv6; no URL, no spaces


def check(cfg):
    servers = cfg.get("servers")
    if not isinstance(servers, list) or not servers:
        raise ValueError("servers is required: a list of {name, type, host, port}")
    if len(servers) > MAX_SERVERS:
        raise ValueError("servers: at most %d" % MAX_SERVERS)
    names = set()
    for i, s in enumerate(servers):
        where = "servers[%d]" % i
        if not isinstance(s, dict):
            raise ValueError("%s must be an object" % where)
        extra = set(s) - set(SERVER_KEYS)
        if extra:
            raise ValueError("%s: unknown key %s (known: %s)" % (where, sorted(extra)[0], ", ".join(SERVER_KEYS)))
        name = s.get("name")
        if not isinstance(name, str) or not name.strip() or len(name) > 40 or _CONTROL.search(name):
            raise ValueError("%s: name must be 1-40 characters of text" % where)
        if name.strip().lower() in names:
            raise ValueError("%s: duplicate name %r" % (where, name))
        names.add(name.strip().lower())
        if s.get("type") not in DEFAULTS:
            raise ValueError("%s: type must be one of %s" % (where, ", ".join(sorted(DEFAULTS))))
        host = s.get("host")
        if not isinstance(host, str) or not HOST_RE.fullmatch(host):
            raise ValueError("%s: host must be a host name or IP address, not a URL" % where)
        port = s.get("port", DEFAULTS[s["type"]])
        if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
            raise ValueError("%s: port must be a number from 1 to 65535" % where)
        for key in ("players", "expect_up"):
            if not isinstance(s.get(key, False), bool):
                raise ValueError("%s: %s must be true or false" % (where, key))
        if s.get("players") and s["type"] != "a2s":
            raise ValueError("%s: players is only for type a2s (Minecraft sends its sample by itself)" % where)
        hh = s.get("handshake_host")
        if hh is not None and (s["type"] != "minecraft" or not isinstance(hh, str) or not HOST_RE.fullmatch(hh)):
            raise ValueError("%s: handshake_host is a host name, only for type minecraft" % where)


_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


# --------------------------------------------------------------------------------------------- sockets

class _Reader:
    """Reads exactly n bytes from a TCP socket before a fixed deadline, so a server that drips one byte a second
    still ends on time."""

    def __init__(self, sock, deadline):
        self.sock = sock
        self.deadline = deadline

    def read(self, n):
        out = b""
        while len(out) < n:
            left = self.deadline - time.monotonic()
            if left <= 0:
                raise SourceError("timeout")
            self.sock.settimeout(left)
            chunk = self.sock.recv(min(n - len(out), 65536))
            if not chunk:
                raise SourceError("connection closed")
            out += chunk
        return out

    def varint(self):
        value = 0
        for i in range(5):
            b = self.read(1)[0]
            value |= (b & 0x7F) << (7 * i)
            if not b & 0x80:
                if value >= 1 << 31:
                    raise SourceError("invalid answer")   # negative
                return value
        raise SourceError("invalid answer")


def _varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def _packet(body):
    return _varint(len(body)) + body


def _text(value, limit):
    """One line of display text from anything a server sent: formatting codes, control and invisible characters
    are gone, URLs become <url> (safe_text), at most `limit` characters."""
    value = re.sub("§.?", "", as_text(value)[:MAX_TEXT_IN], flags=re.S)
    value = "".join(" " if unicodedata.category(c) in ("Cc", "Zl", "Zp") else
                    ("" if unicodedata.category(c) in ("Cf", "Cs", "Co", "Cn") else c) for c in value)
    return safe_text(" ".join(value.split()), limit)


def _chat(node, depth=0):
    """The plain text of a chat component (a string, {"text", "extra": [...]}, or a list of those)."""
    if depth > 6:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return "".join(_chat(n, depth + 1) for n in node[:50])
    if isinstance(node, dict):
        return as_text(node.get("text")) + "".join(_chat(n, depth + 1) for n in as_list(node.get("extra"))[:50])
    return ""


def _count(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 10_000_000 else None


def ping_minecraft(host, port, handshake_host, deadline):
    """Minecraft Java Server List Ping. Status only: never the login state, never the ping packet."""
    left = deadline - time.monotonic()
    if left <= 0:
        raise SourceError("timeout")
    addr = handshake_host.encode("utf-8")
    handshake = b"\x00" + _varint(47) + _varint(len(addr)) + addr + struct.pack(">H", port) + _varint(1)
    with socket.create_connection((host, port), timeout=left) as sock:
        sock.sendall(_packet(handshake) + _packet(b"\x00"))
        r = _Reader(sock, deadline)
        length = r.varint()
        if not 2 <= length <= MAX_PACKET:
            raise SourceError("invalid answer")
        body = r.read(length)
    sub = _Buf(body)
    if sub.varint() != 0:
        raise SourceError("invalid answer")
    size = sub.varint()
    if size > length:
        raise SourceError("invalid answer")
    raw = sub.read(size)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        raise SourceError("invalid answer")
    if not isinstance(data, dict):
        raise SourceError("invalid answer")
    players = as_dict(data.get("players"))
    names = []
    for p in as_list(players.get("sample"))[:MAX_SAMPLE]:
        n = _text(as_dict(p).get("name"), NAME_LEN)
        if n:
            names.append(n)
    return {"online": _count(players.get("online")), "max": _count(players.get("max")), "names": names,
            "version": _text(as_dict(data.get("version")).get("name"), 40),
            "motd": _text(_chat(data.get("description")), MOTD_LEN)}


class _Buf(_Reader):
    """The same VarInt reading over bytes already read."""

    def __init__(self, body):
        self.body, self.pos = body, 0

    def read(self, n):
        if self.pos + n > len(self.body):
            raise SourceError("invalid answer")
        self.pos += n
        return self.body[self.pos - n:self.pos]


# A2S ------------------------------------------------------------------------------------------

A2S_HEAD = b"\xff\xff\xff\xff"
INFO_REQUEST = A2S_HEAD + b"TSource Engine Query\x00"


def _query(sock, request, deadline, kinds):
    """Send `request` and wait for a reply whose type byte is in `kinds`. UDP gets lost: one resend. Returns (type
    byte, the bytes after it)."""
    for attempt in range(2):
        left = deadline - time.monotonic()
        if left <= 0:
            break
        sock.send(request)
        sock.settimeout(left if attempt else min(left, max(left / 2, 0.5)))
        try:
            reply = sock.recv(4096)
        except socket.timeout:
            continue
        if reply[:4] == b"\xfe\xff\xff\xff":
            raise SourceError("fragmented answer")
        if len(reply) < 5 or reply[:4] != A2S_HEAD:
            raise SourceError("invalid answer")
        if reply[4] in kinds:
            return reply[4], reply[5:]
        raise SourceError("invalid answer")
    raise SourceError("timeout")


def _cstring(buf, pos):
    end = buf.find(b"\x00", pos)
    if end < 0:
        raise SourceError("invalid answer")
    return buf[pos:end].decode("utf-8", "replace"), end + 1


def _asked(sock, base, deadline, kinds):
    """base + challenge (ffffffff first). Servers answer 0x41 with a challenge; ask again with it (twice at most)."""
    challenge = b"\xff\xff\xff\xff"
    for _ in range(3):
        kind, rest = _query(sock, base + challenge, deadline, kinds | {0x41})
        if kind != 0x41:
            return kind, rest
        if len(rest) < 4:
            raise SourceError("invalid answer")
        challenge = rest[:4]
    raise SourceError("invalid answer")


def _info(sock, deadline):
    kind, rest = _query(sock, INFO_REQUEST, deadline, {0x49, 0x6D, 0x41})
    if kind == 0x41:   # since 2020 servers want the challenge echoed
        if len(rest) < 4:
            raise SourceError("invalid answer")
        kind, rest = _query(sock, INFO_REQUEST + rest[:4], deadline, {0x49, 0x6D})
    try:
        if kind == 0x49:
            pos = 1   # protocol
            name, pos = _cstring(rest, pos)
            game_map, pos = _cstring(rest, pos)
            _folder, pos = _cstring(rest, pos)
            game, pos = _cstring(rest, pos)
            app_id = struct.unpack_from("<H", rest, pos)[0]
            players, mx, bots = rest[pos + 2], rest[pos + 3], rest[pos + 4]
            pos += 9   # app id, players, max, bots, type, environment, visibility, vac
            if app_id == 2400:
                pos += 3   # The Ship
            version, pos = _cstring(rest, pos)
        else:   # 0x6D, GoldSource: address, name, map, folder, game, players, max, protocol ...
            _addr, pos = _cstring(rest, 0)
            name, pos = _cstring(rest, pos)
            game_map, pos = _cstring(rest, pos)
            _folder, pos = _cstring(rest, pos)
            game, pos = _cstring(rest, pos)
            players, mx, bots, version = rest[pos], rest[pos + 1], 0, ""
    except (IndexError, struct.error):
        raise SourceError("invalid answer")
    return {"online": max(players - bots, 0), "max": mx, "version": _text(version, 40), "game": _text(game, 40),
            "map": _text(game_map, 40), "name": _text(name, 60)}


def _player_names(sock, deadline):
    kind, rest = _asked(sock, A2S_HEAD + b"U", deadline, {0x44})
    count, pos, names = rest[0] if rest else 0, 1, []
    for _ in range(min(count, MAX_SAMPLE)):
        if pos >= len(rest):
            break
        try:
            name, pos = _cstring(rest, pos + 1)   # skip the index byte
        except SourceError:
            break
        pos += 8                                   # score and duration
        name = _text(name, NAME_LEN)
        if name:
            names.append(name)
    return names


def ping_a2s(host, port, want_players, deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        raise SourceError("timeout")
    family, _t, _p, _c, addr = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)[0]
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.connect(addr)   # a connected UDP socket only takes answers from the server's own address
        info = _info(sock, deadline)
        info["names"] = []
        if want_players and info["online"]:
            try:
                info["names"] = _player_names(sock, deadline)
            except (SourceError, OSError):
                pass   # the names are a bonus
    return info


# --------------------------------------------------------------------------------------------- card

def _probe(s):
    deadline = time.monotonic() + TIMEOUT
    if s["type"] == "minecraft":
        return ping_minecraft(s["host"], s.get("port", DEFAULTS["minecraft"]),
                              s.get("handshake_host") or s["host"], deadline)
    return ping_a2s(s["host"], s.get("port", DEFAULTS["a2s"]), bool(s.get("players")), deadline)


def _run(s, out):
    try:
        out["info"] = _probe(s)
    except SourceError as exc:
        out["why"] = str(exc) if str(exc) not in ("timeout", "connection closed") else ""
    except socket.gaierror as exc:
        out["why"] = short_error(exc)
    except Exception:  # noqa: BLE001 - one bad server never breaks the others (refused, reset, junk, a bug)
        out["why"] = ""


def _row(s, out):
    """(item, problem or None) of one server."""
    info = out.get("info")
    if info is None:
        why = out.get("why")
        item = {"title": s["name"], "value": "offline", "tint": "gray",
                "subtitle": "Offline" + (" · " + why if why else "")}
        if not s.get("expect_up"):
            return item, None
        item["tint"] = "red"
        return item, {"id": "gameserver-" + (re.sub(r"[^a-z0-9]+", "-", s["name"].lower()).strip("-") or "server"),
                      "severity": "problem", "text": "%s: not answering" % s["name"]}
    motd = info.get("motd") or ""
    state, tint = "Running", "green"
    if SLEEPING.search(motd):
        state, tint = "Sleeping", "gray"
    elif STARTING.search(motd):
        state, tint = "Starting", "orange"
    parts = [state]
    if info["online"] is not None and info["max"] is not None:
        parts.append("%d/%d" % (info["online"], info["max"]))
    elif info["online"] is not None:
        parts.append("%d online" % info["online"])
    label = info.get("version") or info.get("game")
    if label:
        parts.append(label)
    names = info.get("names") or []
    if names:
        extra = (info["online"] or 0) - SHOWN_PLAYERS
        parts.append(", ".join(names[:SHOWN_PLAYERS]) + (" +%d" % extra if extra > 0 else ""))
    if motd and state != "Running":
        parts.append(motd)
    item = {"title": s["name"], "subtitle": " · ".join(parts), "tint": tint}
    if info["online"] is not None:
        item["value"] = str(info["online"])
    return item, None


def collect(cfg, fetch):
    servers = [s for s in as_list(cfg.get("servers")) if isinstance(s, dict)]
    outs = [{} for _ in servers]
    threads = [threading.Thread(target=_run, args=(s, o), daemon=True, name="gameserver " + s["name"])
               for s, o in zip(servers, outs)]
    for t in threads:
        t.start()
    end = time.monotonic() + TIMEOUT + 1   # DNS is not bounded by the socket deadline: a stuck lookup is left behind
    for t in threads:
        t.join(max(end - time.monotonic(), 0))
    items, problems, up = [], [], 0
    for s, o in zip(servers, outs):
        item, problem = _row(s, dict(o))
        up += 1 if "info" in o else 0
        items.append(item)
        if problem:
            problems.append(problem)
    card = {"id": "gameservers", "title": cfg["name"], "subtitle": "%d of %d up" % (up, len(items)),
            "icon": "gamecontroller", "style": "list", "place": "lab", "items": items}
    return {"problems": problems, "cards": [card]}
