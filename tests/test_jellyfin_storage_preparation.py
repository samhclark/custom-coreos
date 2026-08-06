# ABOUTME: Regression tests for Jellyfin ZFS preparation and read-only media
# access.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = (
    REPO / "overlay-root/usr/local/bin/zfs-prepare-jellyfin-storage.sh"
).read_text()
SERVICE = (
    REPO / "overlay-root/etc/systemd/system/zfs-prepare-jellyfin-storage.service"
).read_text()
QUADLET = REPO / "quadlets/jellyfin.toml"


class JellyfinStoragePreparationTests(unittest.TestCase):
    def test_preparation_waits_for_service_identity(self):
        self.assertIn("Requires=ensure-nas-jellyfin-account.service", SERVICE)
        self.assertIn(
            "After=zfs.target ensure-nas-jellyfin-account.service",
            SERVICE,
        )

    def test_existing_media_dataset_is_required_and_never_created(self):
        self.assertIn('MEDIA_DATASET="${POOL}/videos"', SCRIPT)
        self.assertIn('if ! dataset_exists "${MEDIA_DATASET}"', SCRIPT)
        self.assertNotIn('zfs create "${MEDIA_DATASET}"', SCRIPT)

    def test_media_is_read_only_without_recursive_podman_relabel(self):
        source = QUADLET.read_text()
        media_volumes = source.split(
            'source = "/var/zfs/tank/videos/movies"', 1
        )[1]

        self.assertIn('target = "/media/movies"', media_volumes)
        self.assertIn(
            'source = "/var/zfs/tank/videos/tv-shows"', media_volumes
        )
        self.assertIn('target = "/media/tv-shows"', media_volumes)
        self.assertEqual(media_volumes.count('options = "ro"'), 2)
        self.assertNotIn(":z", media_volumes)
        self.assertNotIn(":Z", media_volumes)
        self.assertIn('ensure_fcontext_rule "${MEDIA_PATH}(/.*)?"', SCRIPT)
        self.assertIn('restorecon_recursive "${MEDIA_PATH}"', SCRIPT)

    def test_uses_actual_videos_mountpoint_and_requires_both_libraries(self):
        self.assertIn('MEDIA_PATH="/var/zfs/tank/videos"', SCRIPT)
        self.assertIn('MOVIES_PATH="${MEDIA_PATH}/movies"', SCRIPT)
        self.assertIn('TV_PATH="${MEDIA_PATH}/tv-shows"', SCRIPT)
        self.assertIn(
            'for library_path in "${MOVIES_PATH}" "${TV_PATH}"', SCRIPT
        )

    def test_media_relabel_requires_stopped_container_and_free_port(self):
        media_repair = SCRIPT.split(
            'if ! labels_are_ready "${MEDIA_PATH}"', 1
        )[1]

        self.assertLess(
            media_repair.index("ensure_jellyfin_stopped"),
            media_repair.index('restorecon_recursive "${MEDIA_PATH}"'),
        )
        self.assertIn("rootless_podman container exists jellyfin", SCRIPT)
        self.assertIn(":8096$", SCRIPT)

    def test_bounded_normal_media_checks_are_constant_depth(self):
        sample_function = SCRIPT.split("sample_descendant() {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn("-mindepth 1 -maxdepth 1", sample_function)
        self.assertIn("-print -quit", sample_function)


if __name__ == "__main__":
    unittest.main()
