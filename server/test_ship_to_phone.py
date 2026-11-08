#!/usr/bin/env python3
"""Tests for scripts/ship-to-phone against a fake host: stub `ssh` and `scp` programs on PATH run the remote
commands locally and copy into a temp folder (SHIP_DIR), so nothing leaves the machine. Run from the repo root:

    python3 -m unittest -v server/test_ship_to_phone.py
"""

import json
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ship-to-phone")

SSH = """#!/usr/bin/env bash
# fake ssh: skip the -o options and the host, run the command line locally
while [ "$1" = -o ]; do shift 2; done
shift
exec bash -c "$*"
"""
SCP = """#!/usr/bin/env bash
# fake scp: scp -q [-o X]... SRC HOST:DEST -> cp (FAKE_CORRUPT=1 damages the copy)
shift
while [ "$1" = -o ]; do shift 2; done
dest=${2#*:}
cp "$1" "$dest"
[ -z "${FAKE_CORRUPT:-}" ] || printf x >> "$dest"
"""


def make_ipa(path, version, build):
    info = plistlib.dumps({"CFBundleShortVersionString": version, "CFBundleVersion": str(build)})
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/Homelab.app/Info.plist", info)
        z.writestr("Payload/Homelab.app/pad", os.urandom(64))


@unittest.skipUnless(shutil.which("bash"), "needs bash (the alpine bridge image has none)")
class ShipToPhone(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.remote = os.path.join(self.tmp, "remote")
        os.mkdir(self.remote)
        bindir = os.path.join(self.tmp, "bin")
        os.mkdir(bindir)
        for name, body in (("ssh", SSH), ("scp", SCP)):
            p = os.path.join(bindir, name)
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        self.env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], SHIP_HOST="fake-host",
                        SHIP_DIR=self.remote, SHIP_VERIFY="true", IPA=os.path.join(self.tmp, "Homelab.ipa"))
        self.env.pop("FAKE_CORRUPT", None)
        # CI runs as root on a checkout owned by another user: let git read it
        self.env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="safe.directory", GIT_CONFIG_VALUE_0="*")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ship(self, version, build, *args, **env):
        make_ipa(self.env["IPA"], version, build)
        return subprocess.run([SCRIPT, *args], cwd=ROOT, env=dict(self.env, **env), capture_output=True, text=True)

    def latest(self):
        with open(os.path.join(self.remote, "latest.json")) as f:
            return json.load(f)

    def ipas(self):
        return sorted(n for n in os.listdir(self.remote) if n.endswith(".ipa"))

    def test_help(self):
        r = subprocess.run([SCRIPT, "-h"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn("Usage: scripts/ship-to-phone", r.stdout)

    def test_first_ship(self):
        r = self.ship("1.0.0", 6)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        j = self.latest()
        self.assertEqual((j["version"], j["build"], j["file"]), ("1.0.0", 6, "Homelab-1.0.0-6.ipa"))
        self.assertEqual(set(j), {"version", "build", "file", "sha256", "size", "built", "commit"})
        self.assertRegex(j["built"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$")
        self.assertEqual(j["size"], os.path.getsize(self.env["IPA"]))
        out = subprocess.run(["sha256sum", os.path.join(self.remote, j["file"])], capture_output=True, text=True).stdout
        self.assertEqual(out.split()[0], j["sha256"])
        self.assertEqual(sorted(os.listdir(self.remote)), ["Homelab-1.0.0-6.ipa", "latest.json"])

    def test_refuses_older_or_same_build(self):
        self.assertEqual(self.ship("1.0.0", 6).returncode, 0)
        for build in (5, 6):
            r = self.ship("1.0.0", build)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("not newer", r.stderr)
        self.assertEqual(self.latest()["build"], 6)
        self.assertEqual(self.ipas(), ["Homelab-1.0.0-6.ipa"])

    def test_force_allows_lower_build(self):
        self.assertEqual(self.ship("1.0.0", 6).returncode, 0)
        r = self.ship("1.0.0", 5, "--force")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.latest()["build"], 5)
        self.assertEqual(self.ipas(), ["Homelab-1.0.0-5.ipa", "Homelab-1.0.0-6.ipa"])

    def test_keeps_last_three(self):
        for build in range(1, 6):
            self.assertEqual(self.ship("1.0.0", build).returncode, 0)
        self.assertEqual(self.ipas(), ["Homelab-1.0.0-3.ipa", "Homelab-1.0.0-4.ipa", "Homelab-1.0.0-5.ipa"])
        self.assertEqual(self.latest()["build"], 5)

    def test_sha_mismatch_aborts_before_latest_changes(self):
        self.assertEqual(self.ship("1.0.0", 6).returncode, 0)
        before = open(os.path.join(self.remote, "latest.json")).read()
        r = self.ship("1.0.0", 7, FAKE_CORRUPT="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("sha256 differs", r.stderr)
        self.assertEqual(open(os.path.join(self.remote, "latest.json")).read(), before)
        self.assertEqual(sorted(os.listdir(self.remote)), ["Homelab-1.0.0-6.ipa", "latest.json"])

    def test_dry_run_changes_nothing(self):
        r = self.ship("1.0.0", 6, "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dry run", r.stdout)
        self.assertEqual(os.listdir(self.remote), [])

    def test_stale_ipa_refused(self):
        log = subprocess.run(["git", "log", "-1", "--format=%ct", "--", "Sources"], cwd=ROOT, env=self.env,
                             capture_output=True, text=True)
        if log.returncode != 0 or not log.stdout.strip():
            self.skipTest("needs a git checkout with history")
        make_ipa(self.env["IPA"], "1.0.0", 6)
        os.utime(self.env["IPA"], (946684800, 946684800))   # 2000-01-01, older than any commit
        r = subprocess.run([SCRIPT], cwd=ROOT, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("older than the newest commit", r.stderr)
        self.assertEqual(os.listdir(self.remote), [])


if __name__ == "__main__":
    unittest.main()
