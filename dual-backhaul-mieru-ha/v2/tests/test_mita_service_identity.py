"""Regression checks: native Mita needs the Unix socket owner to exist."""
from pathlib import Path
import unittest

BASE = Path(__file__).resolve().parents[1]

class MitaIdentityTests(unittest.TestCase):
    def test_fresh_installer_creates_mita_before_start(self):
        source = (BASE / "foreign-mieru.sh").read_text()
        self.assertIn("useradd --system --gid mita", source)
        self.assertIn("User=mita", source)
        self.assertIn("Group=mita", source)
        self.assertLess(source.index("useradd --system --gid mita"), source.index("systemctl enable --now dual-ha-mita"))

    def test_existing_install_never_rotates_secret(self):
        source = (BASE / "foreign-mieru.sh").read_text()
        self.assertIn("-e /etc/dual-ha/mieru-bundle.env", source)
        self.assertIn("refusing to overwrite secrets", source)

    def test_repair_preserves_bundle(self):
        source = (BASE / "repair-foreign-mieru.sh").read_text()
        self.assertIn("User=mita", source)
        self.assertIn("Group=mita", source)
        self.assertIn("systemctl restart dual-ha-mita.service", source)
        self.assertNotIn("openssl rand -hex", source)
        self.assertNotIn("mita replace config", source)
        self.assertNotIn("rm -f /etc/dual-ha/mieru-bundle.env", source)

if __name__ == "__main__":
    unittest.main()
