# ABOUTME: Behaviorally tests the shared local and CI build-input resolver.

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/resolve-build-inputs.sh"


class BuildInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=REPO)
        self.directory = Path(self.temporary.name)
        self.zfs = self.executable("zfs", "printf '2.4.3\\n'")
        self.kernel = self.executable(
            "kernel", "printf '7.1.4-200.fc44.x86_64\\n'"
        )
        self.skopeo = self.executable("skopeo", "exit \"${FAKE_SKOPEO_STATUS:-0}\"")
        self.environment = os.environ | {
            "RESOLVE_ZFS_BIN": str(self.zfs),
            "QUERY_KERNEL_BIN": str(self.kernel),
            "SKOPEO_BIN": str(self.skopeo),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, name: str, body: str) -> Path:
        path = self.directory / name
        path.write_text(f"#!/bin/bash\nset -euo pipefail\n{body}\n")
        path.chmod(0o755)
        return path

    def test_default_output_is_a_make_consumable_record(self):
        result = subprocess.run(
            [SCRIPT, "zfs-2.4"],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=3,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "2.4.3\t7.1.4-200.fc44.x86_64\t"
            "ghcr.io/samhclark/fedora-zfs-kmods:"
            "zfs-2.4.3_kernel-7.1.4-200.fc44.x86_64\n",
        )

    def test_github_output_contains_only_declared_fields(self):
        output = self.directory / "github-output"

        result = subprocess.run(
            [SCRIPT, "--github-output", output],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=3,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            output.read_text(),
            "zfs-version=2.4.3\n"
            "kernel-version=7.1.4-200.fc44.x86_64\n"
            "kmod-image=ghcr.io/samhclark/fedora-zfs-kmods:"
            "zfs-2.4.3_kernel-7.1.4-200.fc44.x86_64\n",
        )

    def test_missing_kmods_fail_before_emitting_outputs(self):
        environment = self.environment | {"FAKE_SKOPEO_STATUS": "1"}

        result = subprocess.run(
            [SCRIPT],
            env=environment,
            capture_output=True,
            text=True,
            timeout=3,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("No prebuilt ZFS kmods", result.stderr)

    def test_make_build_stops_before_podman_when_resolution_fails(self):
        marker = self.directory / "podman-called"
        podman = self.executable(
            "podman",
            'printf called > "${FAKE_PODMAN_MARKER}"\nexit 99',
        )
        environment = self.environment | {
            "FAKE_SKOPEO_STATUS": "1",
            "FAKE_PODMAN_MARKER": str(marker),
        }

        result = subprocess.run(
            [
                "make",
                "--no-print-directory",
                "build",
                f"PODMAN={podman}",
                f"SKOPEO={self.skopeo}",
            ],
            cwd=REPO,
            env=environment,
            capture_output=True,
            text=True,
            timeout=5,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No prebuilt ZFS kmods", result.stderr)
        self.assertNotIn("Building custom-coreos", result.stdout)
        self.assertFalse(marker.exists())

    def test_untrusted_resolver_output_cannot_inject_github_fields(self):
        bad_zfs = self.executable("bad-zfs", "printf '2.4.3\\nevil=value\\n'")
        environment = self.environment | {"RESOLVE_ZFS_BIN": str(bad_zfs)}

        result = subprocess.run(
            [SCRIPT],
            env=environment,
            capture_output=True,
            text=True,
            timeout=3,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("unsupported characters", result.stderr)

    def test_empty_or_null_versions_fail_before_registry_access(self):
        for value in ("", "null"):
            with self.subTest(value=value):
                bad_zfs = self.executable("bad-zfs", f"printf '%s\\n' '{value}'")
                marker = self.directory / f"registry-called-{value or 'empty'}"
                skopeo = self.executable(
                    "unused-skopeo",
                    'printf called > "${FAKE_REGISTRY_MARKER}"',
                )
                environment = self.environment | {
                    "RESOLVE_ZFS_BIN": str(bad_zfs),
                    "SKOPEO_BIN": str(skopeo),
                    "FAKE_REGISTRY_MARKER": str(marker),
                }

                result = subprocess.run(
                    [SCRIPT],
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=3,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("Failed to resolve ZFS version", result.stderr)
                self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
