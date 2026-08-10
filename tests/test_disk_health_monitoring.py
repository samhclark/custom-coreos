# ABOUTME: Keeps ZFS health reporting on the monitored Prometheus path.

from __future__ import annotations

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
OVERLAY = REPO / "overlay-root"
CONTAINERFILE = (REPO / "Containerfile").read_text()
COLLECTOR = (OVERLAY / "usr/local/bin/disk-health-metrics.sh").read_text()
ALERTS = (
    OVERLAY / "usr/share/custom-coreos/vmalert/alert-rules.yml"
).read_text()
DASHBOARD = (
    OVERLAY / "usr/share/custom-coreos/grafana/dashboards/zfs-disk-health.json"
).read_text()


class DiskHealthMonitoringTests(unittest.TestCase):
    def test_zfs_health_uses_the_node_exporter_textfile_path(self):
        self.assertIn('PROM_FILE="${TEXTFILE_DIR}/disk_health.prom"', COLLECTOR)
        self.assertIn("zpool_healthy", COLLECTOR)
        self.assertIn("zpool_state", COLLECTOR)
        self.assertIn("zpool_healthy == 0", ALERTS)
        self.assertIn('"expr": "zpool_state == 1"', DASHBOARD)
        self.assertIn("disk-health-metrics.timer", CONTAINERFILE)

    def test_unconsumed_journal_health_path_is_absent(self):
        retired = (
            OVERLAY / "usr/local/bin/zfs-health-check.sh",
            OVERLAY / "etc/systemd/system/zfs-health-check.service",
            OVERLAY / "etc/systemd/system/zfs-health-check.timer",
        )

        self.assertNotIn("zfs-health-check", CONTAINERFILE)
        self.assertTrue(all(not path.exists() for path in retired))


if __name__ == "__main__":
    unittest.main()
