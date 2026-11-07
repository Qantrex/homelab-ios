#!/usr/bin/env python3
"""Tests for the game server source (server/sources/gameserver.py) against fake servers on localhost: a Minecraft
Server List Ping server (TCP) and an A2S server (UDP, with the challenge). Run from the repo root:

    python3 -m unittest -v server/test_source_gameserver.py
"""

import json
import os
import socket
import socketserver
import struct
import sys
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sources  # noqa: E402
from sources import gameserver  # noqa: E402

gameserver.TIMEOUT = 1.5   # the silent and slow fakes would otherwise take 4 s each


def varint(n):
    return gameserver._varint(n)


def mc_packet(obj, raw=None):
    """A status response packet: id 0, the JSON as a VarInt-prefixed string."""
    data = raw if raw is not None else json.dumps(obj).encode("utf-8")
    body = b"\x00" + varint(len(data)) + data
    return varint(len(body)) + body


class FakeMinecraft:
    """TCP server. `reply(handshake_bytes)` returns what to send (bytes), or a generator for slow drips. It records
    every packet it received, so tests can check that no login and no ping packet came."""

    def __init__(self, reply):
        self.received = []
        outer = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(3)
                try:
                    data = self.request.recv(4096)
                    outer.received.append(data)
                    out = reply(data)
                    if isinstance(out, bytes):
                        self.request.sendall(out)
                    else:
                        for chunk in out:
                            self.request.sendall(chunk)
                    try:   # a real server would wait for a ping packet; see if one comes
                        more = self.request.recv(4096)
                        if more:
                            outer.received.append(more)
                    except OSError:
                        pass
                except OSError:
                    pass

        socketserver.ThreadingTCPServer.allow_reuse_address = True
        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]

    def __enter__(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()


def cstr(text):
    return text.encode("utf-8") + b"\x00"


def info_reply(name="Valheim World", game_map="Dedicated", game="Valheim", players=2, mx=10, bots=0, version="0.220.5",
               app_id=0):
    return (b"\xff\xff\xff\xffI" + b"\x11" + cstr(name) + cstr(game_map) + cstr("valheim") + cstr(game)
            + struct.pack("<h", app_id) + bytes([players, mx, bots]) + b"dlw\x01" + cstr(version) + b"\x00")


def players_reply(names):
    out = b"\xff\xff\xff\xffD" + bytes([len(names)])
    for i, n in enumerate(names):
        out += bytes([i]) + cstr(n) + struct.pack("<f", 3.0) + struct.pack("<f", 100.0)
    return out


class FakeA2S:
    """UDP server. `script(request, state)` returns the datagram to answer with, or None for silence. `challenge`: the
    modern behaviour, A2S_INFO and A2S_PLAYER only with the challenge it gave."""

    CHALLENGE = b"\x01\x02\x03\x04"

    def __init__(self, info=None, names=(), challenge=True, script=None):
        self.requests = []
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.stop = False
        info = info if info is not None else info_reply()

        def default(req):
            if req.startswith(b"\xff\xff\xff\xffTSource"):
                if challenge and not req.endswith(self.CHALLENGE):
                    return b"\xff\xff\xff\xffA" + self.CHALLENGE
                return info
            if req.startswith(b"\xff\xff\xff\xffU"):
                if req[5:9] != self.CHALLENGE:
                    return b"\xff\xff\xff\xffA" + self.CHALLENGE
                return players_reply(list(names))
            return None

        self.script = script or default

    def run(self):
        while not self.stop:
            try:
                req, addr = self.sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            self.requests.append(req)
            reply = self.script(req)
            if reply is not None:
                self.sock.sendto(reply, addr)

    def __enter__(self):
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop = True
        self.thread.join()
        self.sock.close()


def free_port(kind=socket.SOCK_STREAM):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_games(*servers, **cfg):
    spec = sources.parse([dict({"name": "Games", "type": "gameserver", "servers": list(servers)}, **cfg)], {})[0]
    runner = sources.Runner([spec])
    runner.run_one(spec)
    return runner.merged(), runner


def mc(name, port, **kw):
    return dict({"name": name, "type": "minecraft", "host": "127.0.0.1", "port": port}, **kw)


def a2s(name, port, **kw):
    return dict({"name": name, "type": "a2s", "host": "127.0.0.1", "port": port}, **kw)


def rows(out):
    return {i["title"]: i for i in out["cards"][0]["items"]}


def paper(**extra):
    obj = {"version": {"name": "Paper 26.3", "protocol": 770}, "description": {"text": "A Paper server"},
           "players": {"max": 10, "online": 2, "sample": [{"name": "alice", "id": "x"}, {"name": "bob", "id": "y"}]}}
    obj.update(extra)
    return obj


class MinecraftSource(unittest.TestCase):
    def test_normal(self):
        with FakeMinecraft(lambda _d: mc_packet(paper())) as fake:
            out, runner = run_games(mc("Survival", fake.port))
        self.assertIsNone(runner.states["Games"].error)
        self.assertEqual(out["problems"], [])
        card = out["cards"][0]
        self.assertEqual((card["id"], card["title"], card["subtitle"], card["place"], card["style"]),
                         ("Games:gameservers", "Games", "1 of 1 up", "lab", "list"))
        item = card["items"][0]
        self.assertEqual((item["title"], item["subtitle"], item["value"], item["tint"]),
                         ("Survival", "Running · 2/10 · Paper 26.3 · alice, bob", "2", "green"))

    def test_status_only_never_a_login_or_a_ping(self):
        with FakeMinecraft(lambda _d: mc_packet(paper())) as fake:
            run_games(mc("Survival", fake.port, handshake_host="mc.example.com"))
            time.sleep(0.2)
        first = fake.received[0]
        # handshake: id 0, protocol, address, port, next state 1; then the status request (length 1, id 0)
        self.assertTrue(first.endswith(struct.pack(">H", fake.port) + b"\x01\x01\x00"), first)
        self.assertIn(b"mc.example.com", first)
        self.assertEqual(len(fake.received), 1, "nothing after the status request: no ping packet, no login")

    def test_sleeping_router_motd(self):
        sleeping = {"version": {"name": "mc-router", "protocol": 0}, "players": {"max": 0, "online": 0},
                    "description": "§7Server is §lSleeping§r, join to wake it"}
        with FakeMinecraft(lambda _d: mc_packet(sleeping)) as fake:
            out, _ = run_games(mc("Survival", fake.port, expect_up=True))
        item = rows(out)["Survival"]
        self.assertEqual(item["subtitle"], "Sleeping · 0/0 · mc-router · Server is Sleeping, join to wake it")
        self.assertEqual(item["tint"], "gray")
        self.assertEqual(out["problems"], [], "an answering router is not a down server")

    def test_chat_component_motd_and_codes(self):
        motd = {"text": "§aHello ", "extra": [{"text": "world"}, "!", {"text": "§kx", "extra": [{"text": "y"}]}]}
        with FakeMinecraft(lambda _d: mc_packet(paper(description=motd, players={"online": 0, "max": 5}))) as fake:
            out, _ = run_games(mc("S", fake.port))
        self.assertEqual(gameserver._text(gameserver._chat(motd), 80), "Hello world!xy")
        self.assertTrue(rows(out)["S"]["subtitle"].startswith("Running · 0/5"))

    def test_offline_is_not_a_problem_by_default(self):
        out, runner = run_games(mc("Survival", free_port()))
        self.assertIsNone(runner.states["Games"].error)
        self.assertEqual(out["problems"], [])
        item = rows(out)["Survival"]
        self.assertEqual((item["subtitle"], item["value"], item["tint"]), ("Offline", "offline", "gray"))
        self.assertEqual(out["cards"][0]["subtitle"], "0 of 1 up")

    def test_expect_up_makes_offline_a_problem(self):
        out, _ = run_games(mc("Survival", free_port(), expect_up=True), mc("Other", free_port()))
        self.assertEqual([(p["id"], p["severity"], p["text"]) for p in out["problems"]],
                         [("Games:gameserver-survival", "problem", "Survival: not answering")])
        self.assertEqual(rows(out)["Survival"]["tint"], "red")
        self.assertEqual(rows(out)["Other"]["tint"], "gray")

    def test_player_names_are_capped_and_cleaned(self):
        sample = [{"name": "p%d" % i} for i in range(40)] + [{"name": "§cEvil\x07 http://evil.example/x?a=1"}]
        sample.insert(0, {"name": "x" * 500})
        sample.insert(1, {"name": 5})
        sample.insert(2, "junk")
        obj = paper(players={"online": 41, "max": 100, "sample": sample})
        with FakeMinecraft(lambda _d: mc_packet(obj)) as fake:
            out, _ = run_games(mc("S", fake.port))
        sub = rows(out)["S"]["subtitle"]
        self.assertEqual(sub.count(","), 4, sub)
        self.assertTrue(sub.endswith("+36"), sub)
        self.assertLess(len(sub), 200)

    def test_url_and_control_characters_in_motd(self):
        motd = "Join \x1b[31mhttp://evil.example/login?token=abc\x00 now\n‮​!"
        with FakeMinecraft(lambda _d: mc_packet(paper(description=motd, version={"name": "sleeping x"}))) as fake:
            out, _ = run_games(mc("S", fake.port))
        sub = rows(out)["S"]["subtitle"]
        self.assertNotIn("http", sub)
        self.assertNotIn("evil", sub)
        for ch in "\x1b\x00\n‮​":
            self.assertNotIn(ch, sub)

    def test_odd_numbers_and_shapes(self):
        for players in ({"online": "many", "max": True}, {"online": -3, "max": 1e30}, [], "x", None):
            with self.subTest(players=players):
                with FakeMinecraft(lambda _d, p=players: mc_packet(paper(players=p))) as fake:
                    out, runner = run_games(mc("S", fake.port))
                self.assertIsNone(runner.states["Games"].error)
                self.assertTrue(rows(out)["S"]["subtitle"].startswith("Running"))

    def test_hostile_replies_are_offline_and_never_break_the_others(self):
        huge = varint(10_000_000)   # a packet length far over the cap
        bad_varint = b"\xff\xff\xff\xff\xff\xff\xff"
        wrong_id = varint(3) + b"\x01\x01{"
        deep = b"[" * 200_000 + b"]" * 200_000
        cases = {
            "garbage": lambda _d: b"HTTP/1.1 400 Bad Request\r\n\r\n",
            "huge": lambda _d: huge + b"\x00" * 100,
            "varint": lambda _d: bad_varint,
            "id": lambda _d: wrong_id,
            "notjson": lambda _d: mc_packet(None, raw=b"{nope"),
            "list": lambda _d: mc_packet(None, raw=b"[1, 2]"),
            "deep": lambda _d: mc_packet(None, raw=deep),
            "badutf8": lambda _d: mc_packet(None, raw=b'{"x": "\xff\xfe"}'),
            "short": lambda _d: varint(50) + b"\x00",
            "strlen": lambda _d: varint(5) + b"\x00" + varint(1 << 20) + b"ab",
            "empty": lambda _d: b"",
        }
        fakes = [(name, FakeMinecraft(fn)) for name, fn in cases.items()]
        good = FakeMinecraft(lambda _d: mc_packet(paper()))
        try:
            for _n, f in fakes:
                f.__enter__()
            good.__enter__()
            started = time.monotonic()
            out, runner = run_games(*[mc(n, f.port) for n, f in fakes], mc("Good", good.port))
            took = time.monotonic() - started
        finally:
            for _n, f in fakes:
                f.__exit__()
            good.__exit__()
        self.assertIsNone(runner.states["Games"].error)
        by = rows(out)
        for name in cases:
            self.assertTrue(by[name]["subtitle"].startswith("Offline"), (name, by[name]))
        self.assertTrue(by["Good"]["subtitle"].startswith("Running"))
        self.assertLess(took, gameserver.TIMEOUT + 2, "servers are probed in parallel")

    def test_slow_drip_ends_on_time(self):
        def drip(_d):
            for b in mc_packet(paper()):
                time.sleep(0.5)
                yield bytes([b])
        with FakeMinecraft(drip) as fake:
            started = time.monotonic()
            out, runner = run_games(mc("Slow", fake.port))
            took = time.monotonic() - started
        self.assertIsNone(runner.states["Games"].error)
        self.assertEqual(rows(out)["Slow"]["subtitle"], "Offline")
        self.assertLess(took, gameserver.TIMEOUT + 2)

    def test_silent_server_times_out(self):
        def silent(_d):
            time.sleep(6)
            return b""
        with FakeMinecraft(silent) as fake:
            started = time.monotonic()
            out, _ = run_games(mc("Mute", fake.port))
            took = time.monotonic() - started
        self.assertEqual(rows(out)["Mute"]["subtitle"], "Offline")
        self.assertLess(took, gameserver.TIMEOUT + 2)


class A2SSource(unittest.TestCase):
    def test_normal_with_challenge(self):
        with FakeA2S() as fake:
            out, runner = run_games(a2s("Valheim", fake.port))
        self.assertIsNone(runner.states["Games"].error)
        item = rows(out)["Valheim"]
        self.assertEqual((item["subtitle"], item["value"], item["tint"]), ("Running · 2/10 · 0.220.5", "2", "green"))
        self.assertEqual(len(fake.requests), 2, "the first request gets the challenge, the second the answer")
        self.assertTrue(fake.requests[1].endswith(FakeA2S.CHALLENGE))

    def test_no_challenge_old_server(self):
        with FakeA2S(challenge=False) as fake:
            out, _ = run_games(a2s("Old", fake.port))
        self.assertTrue(rows(out)["Old"]["subtitle"].startswith("Running · 2/10"))
        self.assertEqual(len(fake.requests), 1)

    def test_players_are_asked_only_when_configured(self):
        with FakeA2S(names=["alice", "", "bob"]) as fake:
            out, _ = run_games(a2s("Plain", fake.port), a2s("Names", fake.port, players=True))
        self.assertEqual(rows(out)["Plain"]["subtitle"], "Running · 2/10 · 0.220.5")
        self.assertEqual(rows(out)["Names"]["subtitle"], "Running · 2/10 · 0.220.5 · alice, bob")
        self.assertEqual(sum(1 for r in fake.requests if r.startswith(b"\xff\xff\xff\xffU")), 2,
                         "A2S_PLAYER first without, then with the challenge, for one server only")

    def test_bots_do_not_count(self):
        with FakeA2S(info=info_reply(players=8, mx=16, bots=6)) as fake:
            out, _ = run_games(a2s("CS2", fake.port))
        self.assertTrue(rows(out)["CS2"]["subtitle"].startswith("Running · 2/16"))

    def test_player_failure_keeps_the_server_up(self):
        def script(req):
            if req.startswith(b"\xff\xff\xff\xffU"):
                return b"\xff\xff\xff\xffDjunk"
            return info_reply() if req.endswith(FakeA2S.CHALLENGE) else b"\xff\xff\xff\xffA" + FakeA2S.CHALLENGE
        with FakeA2S(script=script) as fake:
            out, _ = run_games(a2s("V", fake.port, players=True))
        self.assertEqual(rows(out)["V"]["subtitle"], "Running · 2/10 · 0.220.5")

    def test_silence_is_offline(self):
        with FakeA2S(script=lambda _r: None) as fake:
            started = time.monotonic()
            out, _ = run_games(a2s("V", fake.port, expect_up=True))
            took = time.monotonic() - started
        self.assertEqual(rows(out)["V"]["subtitle"], "Offline")
        self.assertEqual(out["problems"][0]["text"], "V: not answering")
        self.assertLess(took, gameserver.TIMEOUT + 2)

    def test_closed_port_is_offline(self):
        out, runner = run_games(a2s("V", free_port(socket.SOCK_DGRAM)))
        self.assertIsNone(runner.states["Games"].error)
        self.assertEqual(rows(out)["V"]["subtitle"], "Offline")

    def test_hostile_replies(self):
        cases = {
            "garbage": b"hello",
            "tiny": b"\xff\xff\xff\xff",
            "fragmented": b"\xfe\xff\xff\xff\x01\x00\x00\x00",
            "wrongtype": b"\xff\xff\xff\xffZxxxxxx",
            "truncated": b"\xff\xff\xff\xffI\x11name\x00",
            "nochallenge": b"\xff\xff\xff\xffA\x01",
            "loop": b"\xff\xff\xff\xffA\x01\x02\x03\x04",
            "big": b"\xff\xff\xff\xffI" + b"A" * 3000,
            "ctrl": info_reply(name="\x1b[31mred http://evil.example/ ‮", version="\x00\x01v http://x.example/1"),
        }
        fakes = {n: FakeA2S(script=lambda _r, r=r: r) for n, r in cases.items()}
        try:
            for f in fakes.values():
                f.__enter__()
            out, runner = run_games(*[a2s(n, f.port) for n, f in fakes.items()])
        finally:
            for f in fakes.values():
                f.__exit__()
        self.assertIsNone(runner.states["Games"].error)
        by = rows(out)
        for name in cases:
            if name != "ctrl":
                self.assertTrue(by[name]["subtitle"].startswith("Offline"), (name, by[name]))
        for ch in "\x1b\x00\x01‮":
            self.assertNotIn(ch, by["ctrl"]["subtitle"])
        self.assertNotIn("http", by["ctrl"]["subtitle"])

    def test_huge_player_list(self):
        names = ["player%03d" % i for i in range(255)]
        with FakeA2S(names=names, info=info_reply(players=255, mx=255)) as fake:
            out, _ = run_games(a2s("Big", fake.port, players=True))
        sub = rows(out)["Big"]["subtitle"]
        self.assertTrue(sub.endswith("player000, player001, player002, player003, player004 +250"), sub)


class MixedAndConfig(unittest.TestCase):
    def test_both_types_in_one_card_and_nothing_else(self):
        with FakeMinecraft(lambda _d: mc_packet(paper())) as m, FakeA2S() as v:
            out, _ = run_games(mc("Survival", m.port), a2s("Valheim", v.port), mc("Gone", free_port()))
        self.assertEqual([i["title"] for i in out["cards"][0]["items"]], ["Survival", "Valheim", "Gone"])
        self.assertEqual(out["cards"][0]["subtitle"], "2 of 3 up")
        self.assertEqual((out["hosts"], out["services"], out["problems"]), ([], [], []))

    def test_status_state_is_ok_even_when_every_server_is_down(self):
        _, runner = run_games(mc("A", free_port()), a2s("B", free_port(socket.SOCK_DGRAM)))
        row = runner.status()[0]
        self.assertEqual((row["name"], row["type"], row["state"]), ("Games", "gameserver", "ok"))

    def test_no_actions(self):
        with self.assertRaisesRegex(ValueError, "no actions"):
            sources.parse([{"name": "Games", "type": "gameserver", "actions": {"wake": ["x"]},
                            "servers": [mc("A", 25565)]}], {})

    def test_config_checks(self):
        ok = mc("A", 25565)
        bad = [({}, "servers is required"),
               ({"servers": []}, "servers is required"),
               ({"servers": ["x"]}, "must be an object"),
               ({"servers": [dict(ok, type="quake")]}, "type must be one of"),
               ({"servers": [dict(ok, host="http://mc.example.com")]}, "not a URL"),
               ({"servers": [dict(ok, host="")]}, "host must be"),
               ({"servers": [dict(ok, port=0)]}, "port"),
               ({"servers": [dict(ok, port="25565")]}, "port"),
               ({"servers": [dict(ok, port=True)]}, "port"),
               ({"servers": [dict(ok, expect_up="yes")]}, "expect_up"),
               ({"servers": [dict(ok, players=True)]}, "only for type a2s"),
               ({"servers": [dict(ok, wake=True)]}, "unknown key wake"),
               ({"servers": [dict(ok, name="")]}, "name must be"),
               ({"servers": [ok, dict(ok, name="a")]}, "duplicate name"),
               ({"servers": [dict(a2s("V", 1), handshake_host="x")]}, "handshake_host"),
               ({"servers": [dict(ok, name="n%d" % i) for i in range(31)]}, "at most")]
        for raw, words in bad:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, words):
                    sources.parse([dict({"name": "Games", "type": "gameserver"}, **raw)], {})

    def test_defaults(self):
        spec = sources.parse([{"name": "Games", "type": "gameserver",
                               "servers": [{"name": "A", "type": "a2s", "host": "nas.tail1234.ts.net"},
                                           {"name": "B", "type": "minecraft", "host": "mc.example.com"}]}], {})[0]
        self.assertEqual(spec["actions"], [])


if __name__ == "__main__":
    unittest.main()
