"""Guard resilient source/toolchain bootstrap; CI cannot recreate provider HTTP restrictions."""
import pathlib
import unittest

SCRIPT = (pathlib.Path(__file__).resolve().parents[1] / "build-backhaul.sh").read_text()

class BootstrapTests(unittest.TestCase):
    def test_go_version_is_pinned_and_checksums_are_enforced(self):
        self.assertIn("GO_VERSION=1.23.1", SCRIPT)
        self.assertIn("GO_SHA256=49bbb517cfa9eee677e1e7897f7cf9cfdbcf49e05f61984a2789136de359f9bd", SCRIPT)
        self.assertIn("sha256sum --check --status", SCRIPT)

    def test_go_download_fallbacks_exist(self):
        for endpoint in ("https://go.dev/dl/", "https://dl.google.com/go/", "https://storage.googleapis.com/golang/", "https://proxy.golang.org"):
            self.assertIn(endpoint, SCRIPT)
        self.assertIn('export GOTOOLCHAIN="go$GO_VERSION+auto"', SCRIPT)

    def test_build_is_isolated(self):
        self.assertIn("/opt/dual-ha/bin/backhaul", SCRIPT)
        self.assertNotIn("systemctl restart", SCRIPT)
        self.assertNotIn("/usr/local/bin/backhaul", SCRIPT)

if __name__ == "__main__":
    unittest.main()
