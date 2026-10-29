"""Validate generated Backhaul HTTP/WSS router, not just generic HAProxy config."""
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import unittest

BASE = Path(__file__).resolve().parents[1]


class BackhaulRouterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = (BASE / "iran-backhaul.sh").read_text()
        start = 'cat >/etc/dual-ha/backhaul-router.cfg <<EOF\n'
        end = '\nEOF'
        if start not in script:
            raise AssertionError("Router template absent")
        template = script.split(start, 1)[1].split(end, 1)[0]
        cls.config = template.replace("$CONTROL", "/assets/testcontrol0001") \
                             .replace("$TUNNEL", "/socket/testtunnel0001")

    def test_router_stays_loopback_only(self):
        self.assertIn("bind 127.0.0.1:19080", self.config)
        self.assertIn("server backhaul 127.0.0.1:19081", self.config)
        self.assertNotIn("bind *:443", self.config)
        self.assertNotIn("bind 0.0.0.0:443", self.config)

    def test_haproxy_syntax_valid(self):
        with TemporaryDirectory() as d:
            dest = Path(d) / "backhaul.cfg"
            dest.write_text(self.config + "\n")
            r = subprocess.run(["haproxy", "-c", "-f", str(dest)],
                               text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_rerun_does_not_rotate_tokens(self):
        script = (BASE / "iran-backhaul.sh").read_text()
        self.assertIn("Existing Backhaul staging installation detected", script)
        self.assertLess(script.index("Existing Backhaul staging installation detected"),
                        script.index('TOKEN="$(openssl rand -hex 32)"'))


if __name__ == "__main__":
    unittest.main()
