# ABOUTME: Regression tests for VictoriaMetrics steady-state ZFS preparation.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = (
    REPO
    / "overlay-root/usr/local/bin/zfs-create-victoria-metrics-dataset.sh"
).read_text()
SERVICE = (
    REPO
    / "overlay-root/etc/systemd/system/zfs-create-victoria-metrics-dataset.service"
).read_text()
QUADLET = (
    REPO
    / "overlay-root/etc/containers/systemd/users/51250/victoria-metrics.container"
).read_text()


class VictoriaMetricsDatasetPreparationTests(unittest.TestCase):
    def test_preparation_waits_for_service_identity(self):
        self.assertIn(
            "Requires=ensure-nas-victoriametrics-account.service",
            SERVICE,
        )
        self.assertIn(
            "After=zfs.target ensure-nas-victoriametrics-account.service",
            SERVICE,
        )

    def test_dataset_mount_and_service_identity_are_verified(self):
        self.assertIn(
            'expected \'${DATA_DATASET}\'',
            SCRIPT,
        )
        self.assertIn(
            'does not have expected UID/GID ${SERVICE_UID}:${SERVICE_GID}',
            SCRIPT,
        )

    def test_bounded_label_check_triggers_recursive_repair(self):
        self.assertIn("-mindepth 1 -maxdepth 1", SCRIPT)
        self.assertIn("owners_are_ready", SCRIPT)
        self.assertIn('! labels_are_ready', SCRIPT)
        self.assertIn("restorecon_recursive", SCRIPT)
        self.assertIn("verify_descendant_owners", SCRIPT)
        self.assertIn("ownership_repair", SCRIPT)
        self.assertIn("relabel_repair", SCRIPT)
        self.assertNotIn("ownership_migration", SCRIPT)
        self.assertNotIn("relabel_migration", SCRIPT)

    def test_recursive_repair_requires_stopped_service_and_free_port(self):
        repair = SCRIPT.split(
            'if [[ "${ownership_repair}" -eq 1 || '
            '"${relabel_repair}" -eq 1 ]]',
            1,
        )[1]

        guard = repair.index("ensure_victoriametrics_stopped")
        root_marker = repair.index('chown root:root "${DATA_PATH}"')
        descendant_chown = repair.index(
            '-exec chown -h "${SERVICE_UID}:${SERVICE_GID}"'
        )
        restorecon = repair.index("restorecon_recursive")
        final_root = repair.index(
            'chown "${SERVICE_UID}:${SERVICE_GID}" "${DATA_PATH}"'
        )

        self.assertLess(guard, root_marker)
        self.assertLess(root_marker, descendant_chown)
        self.assertLess(root_marker, restorecon)
        self.assertLess(descendant_chown, final_root)
        self.assertLess(restorecon, final_root)
        self.assertIn("rootless_podman container exists victoria-metrics", SCRIPT)
        self.assertIn(":8428$", SCRIPT)

    def test_retired_rootful_quadlet_guard_is_absent(self):
        self.assertNotIn(
            "/etc/containers/systemd/victoria-metrics.container",
            QUADLET,
        )


if __name__ == "__main__":
    unittest.main()
