# ABOUTME: Regression tests for Jellyfin's owned state and shared media export.

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

    def test_media_dataset_is_prepared_once_by_the_fleet_resource(self):
        self.assertIn(
            "resource|media|media|52000|2775|tank/videos|/var/zfs/tank/videos",
            (
                REPO
                / "overlay-root/usr/share/custom-coreos/storage/media.storage-manifest"
            ).read_text(),
        )
        self.assertNotIn("managed-zfs|tank/videos", MANIFEST)
        self.assertNotIn("existing-zfs|tank/videos", MANIFEST)

    def test_media_is_read_only_without_recursive_podman_relabel(self):
        self.assertIn(
            "Volume=/var/zfs/tank/videos/data/media:/data/media:ro",
            QUADLET,
        )
        self.assertNotIn("/data/media:ro,Z", QUADLET)

    def test_jellyfin_keeps_the_shared_media_group(self):
        self.assertIn("GroupAdd=keep-groups", QUADLET)
        self.assertIn("m _nas_jellyfin media\n", (
            REPO / "overlay-root/usr/lib/sysusers.d/nas-fleet-groups.conf"
        ).read_text())
        self.assertIn("_nas_jellyfin:52000:1\n", (
            REPO / "overlay-root/etc/subgid"
        ).read_text())

    def test_waits_for_the_single_fleet_readiness_marker(self):
        self.assertIn(
            "marker /run/nas-storage/media/ready 300 2 "
            "--path /var/zfs/tank/videos/data/media "
            "--source tank/videos --access rx",
            QUADLET,
        )

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
