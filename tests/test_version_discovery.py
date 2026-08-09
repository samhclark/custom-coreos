# ABOUTME: Behaviorally tests the leaf version-discovery scripts.

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
ZFS_SCRIPT = REPO / "scripts/resolve-zfs-version.sh"
KERNEL_SCRIPT = REPO / "scripts/query-coreos-kernel.sh"


class VersionDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=REPO)
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, name: str, body: str) -> Path:
        path = self.directory / name
        path.write_text(f"#!/bin/bash\nset -euo pipefail\n{body}\n")
        path.chmod(0o755)
        return path

    def test_zfs_resolver_rejects_a_stream_without_releases(self):
        gh = self.executable("gh", "printf '[]\\n'")

        result = subprocess.run(
            [ZFS_SCRIPT, "zfs-does-not-exist"],
            env=os.environ | {"GH_BIN": str(gh)},
            capture_output=True,
            text=True,
            timeout=3,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("No ZFS release found", result.stderr)

    def test_kernel_resolver_honors_the_skopeo_override(self):
        skopeo = self.executable(
            "skopeo",
            "printf '%s\\n' "
            "'{\"Digest\":\"sha256:abc\",\"Labels\":"
            "{\"ostree.linux\":\"7.1.4-200.fc44.x86_64\"}}'",
        )

        result = subprocess.run(
            [KERNEL_SCRIPT],
            env=os.environ | {"SKOPEO_BIN": str(skopeo)},
            capture_output=True,
            text=True,
            timeout=3,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "7.1.4-200.fc44.x86_64\n")


if __name__ == "__main__":
    unittest.main()
