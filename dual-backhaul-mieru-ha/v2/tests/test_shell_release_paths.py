"""Guard against Bash nounset interpolation regressions in installer filenames."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReleaseFilenameTests(unittest.TestCase):
    def test_mita_archive_expands_version_safely(self):
        content = (ROOT / "foreign-mieru.sh").read_text()
        self.assertIn('mita_${VERSION}_linux_amd64.tar.gz', content)
        self.assertNotRegex(content, r'\$VERSION_linux_amd64')

    def test_mieru_archive_expands_version_safely(self):
        content = (ROOT / "iran-mieru.sh").read_text()
        self.assertIn('mieru_${VERSION}_linux_amd64.tar.gz', content)
        self.assertNotRegex(content, r'\$VERSION_linux_amd64')

    def test_other_release_paths_do_not_accidentally_expand_suffix(self):
        for filename in ("foreign-mieru.sh", "iran-mieru.sh"):
            content = (ROOT / filename).read_text()
            self.assertNotRegex(content, r'\$VERSION_[A-Za-z0-9_]+')


if __name__ == "__main__":
    unittest.main()
