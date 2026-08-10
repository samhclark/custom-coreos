# ABOUTME: Regression tests for Jellyfin's owned and preserve-owner storage.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SERVICE = (
    REPO / "overlay-root/etc/systemd/system/nas-prepare-jellyfin-storage.service"
).read_text()
MANIFEST = (
    REPO / "overlay-root/usr/share/custom-coreos/storage/jellyfin.storage-manifest"
).read_text()
QUADLET = (
    REPO / "overlay-root/etc/containers/systemd/users/51120/jellyfin.container"
).read_text()


class JellyfinStoragePreparationTests(unittest.TestCase):
    def test_preparation_waits_for_service_identity(self):
        self.assertIn(
            "Requires=zfs.target ensure-nas-jellyfin-account.service",
            SERVICE,
        )
        self.assertIn(
            "After=zfs.target local-fs.target ensure-nas-jellyfin-account.service",
            SERVICE,
        )

    def test_existing_media_dataset_is_required_and_never_created(self):
        self.assertIn(
            "existing-zfs|tank/videos|/var/zfs/tank/videos",
            MANIFEST,
        )
        self.assertNotIn("managed-zfs|tank/videos", MANIFEST)

    def test_media_is_read_only_without_recursive_podman_relabel(self):
        self.assertIn(
            "Volume=/var/zfs/tank/videos/movies:/media/movies:ro",
            QUADLET,
        )
        self.assertIn(
            "Volume=/var/zfs/tank/videos/tv-shows:/media/tv-shows:ro",
            QUADLET,
        )
        self.assertNotIn("/media/movies:ro,Z", QUADLET)
        self.assertNotIn("/media/tv-shows:ro,Z", QUADLET)

    def test_uses_actual_videos_mountpoint_and_requires_both_libraries(self):
        self.assertIn("/var/zfs/tank/videos/movies", QUADLET)
        self.assertIn("/var/zfs/tank/videos/tv-shows", QUADLET)
        self.assertIn("--source tank/videos --access rx", QUADLET)

    def test_private_dataset_properties_are_creation_only(self):
        self.assertIn(
            "managed-zfs|tank/jellyfin/config|/var/lib/jellyfin/config|0750|"
            "recordsize=16K,compression=lz4,atime=off,primarycache=all",
            MANIFEST,
        )
        self.assertIn(
            "managed-zfs|tank/jellyfin/cache|/var/lib/jellyfin/cache|0750|"
            "recordsize=128K,compression=lz4,atime=off,primarycache=all",
            MANIFEST,
        )


if __name__ == "__main__":
    unittest.main()
