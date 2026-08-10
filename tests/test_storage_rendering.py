# ABOUTME: Verifies container mounts and readiness are derived from storage policy.

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from quadletgen.model import ConfigError
from quadletgen.parser import load_service
from quadletgen.render_service import container_unit
from tests.quadlet_test_support import REPO, current_fleet, service_toml


STORAGE = """
[[storage]]
name = "state"
kind = "directory"
host-path = "/var/lib/service"
mode = "0750"
subdirectories = ["data"]

[[storage.exports]]
subpath = "data"
container-path = "/data"
access = "read-write"

[[storage]]
name = "media"
kind = "existing-zfs"
dataset = "tank/videos"
host-path = "/var/zfs/tank/videos"

[[storage.exports]]
subpath = "movies"
container-path = "/media/movies"
access = "read-only"
"""


class StorageRenderingTests(unittest.TestCase):
    def load(self, extra: str):
        with tempfile.TemporaryDirectory(dir=REPO) as directory:
            path = Path(directory) / "service.toml"
            path.write_text(service_toml(extra=extra))
            return load_service(path)

    def test_mounts_and_current_boot_readiness_share_one_source(self):
        service = self.load(STORAGE)
        unit = container_unit(service, current_fleet())

        self.assertIn("Volume=/var/lib/service/data:/data", unit)
        self.assertIn(
            "Volume=/var/zfs/tank/videos/movies:/media/movies:ro",
            unit,
        )
        self.assertIn(
            "marker /run/nas-storage/service/ready 90 1",
            unit,
        )
        self.assertIn(
            "--path /var/lib/service/data --owner 51999:51999 "
            "--access rwx",
            unit,
        )
        self.assertIn(
            "--path /var/zfs/tank/videos/movies --source tank/videos "
            "--access rx",
            unit,
        )

    def test_storage_rejects_a_second_handwritten_readiness_contract(self):
        with self.assertRaisesRegex(ConfigError, "owns startup readiness"):
            self.load(
                STORAGE
                + """
[startup.readiness]
marker = "/run/legacy/ready"
timeout-sec = 30
interval-sec = 1
"""
            )


if __name__ == "__main__":
    unittest.main()
