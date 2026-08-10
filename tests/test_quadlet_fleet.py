# ABOUTME: Tests cross-service invariants for the compiled rootless fleet.

from __future__ import annotations

import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from quadletgen.compiler import compile_fleet
from quadletgen.model import (
    ConfigError,
    Fleet,
    MarkerReadiness,
    RequiredPath,
    StartupSpec,
)
from quadletgen.parser import load_service
from tests.quadlet_test_support import REPO, current_fleet, service_toml


class FleetValidationTests(unittest.TestCase):
    def write(self, directory: Path, filename: str, source: str):
        path = directory / filename
        path.write_text(source)
        return load_service(path)

    def test_direct_model_construction_cannot_bypass_local_invariants(self):
        service = next(
            item for item in current_fleet().services if not item.storage
        )
        service = replace(
            service,
            startup=StartupSpec(
                readiness=MarkerReadiness(
                    marker="/run/example/ready",
                    timeout_sec=30,
                    interval_sec=1,
                    paths=(RequiredPath(path="/var/lib/example"),),
                )
            ),
        )
        readiness = service.startup.readiness
        self.assertIsInstance(readiness, MarkerReadiness)
        assert isinstance(readiness, MarkerReadiness)
        required_path = readiness.paths[0]
        invalid_changes = {
            "service name": lambda: replace(
                service,
                info=replace(service.info, name="../../../../outside"),
            ),
            "container image": lambda: replace(
                service,
                container=replace(
                    service.container,
                    image="example.invalid/service:latest",
                ),
            ),
            "host UID": lambda: replace(
                service,
                host=replace(service.host, uid=1),
            ),
            "readiness path": lambda: replace(
                service,
                startup=replace(
                    service.startup,
                    readiness=replace(
                        readiness,
                        paths=(
                            replace(
                                required_path,
                                path="/var/lib/../outside",
                            ),
                        ),
                    ),
                ),
            ),
        }
        for label, make_invalid in invalid_changes.items():
            with self.subTest(label=label):
                with self.assertRaises(ConfigError):
                    make_invalid()

    def test_rejects_duplicate_identity_and_overlapping_subids(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            first = self.write(
                directory,
                "first.toml",
                service_toml(name="first", uid=51991, subid_start=600000000),
            )
            duplicate_uid = self.write(
                directory,
                "second.toml",
                service_toml(name="second", uid=51991, subid_start=700000000),
            )
            with self.assertRaisesRegex(ConfigError, "duplicate uid"):
                Fleet.build([first, duplicate_uid])

            overlapping = self.write(
                directory,
                "third.toml",
                service_toml(name="third", uid=51992, subid_start=600000001),
            )
            with self.assertRaisesRegex(ConfigError, "ranges overlap"):
                Fleet.build([first, overlapping])

    def test_rejects_host_port_collisions_for_non_tap_publishers(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            first = self.write(
                directory,
                "first.toml",
                service_toml(
                    name="first",
                    uid=51970,
                    subid_start=600000000,
                    container=(
                        "[[container.ports]]\n"
                        'host = "127.0.0.1:8080"\n'
                        "container = 8080"
                    ),
                ),
            )
            second = self.write(
                directory,
                "second.toml",
                service_toml(
                    name="second",
                    uid=51980,
                    subid_start=700000000,
                    container=(
                        "[[container.ports]]\n"
                        'host = "127.0.0.1:8080"\n'
                        "container = 8080"
                    ),
                ),
            )
            tap = self.write(
                directory,
                "tap.toml",
                service_toml(
                    name="tap",
                    uid=51990,
                    subid_start=800000000,
                    container=(
                        'network = "host"\n\n'
                        "[[container.ports]]\n"
                        'host = "127.0.0.1:9090"\n'
                        "container = 9090"
                    ),
                    krun=(
                        "enabled = true\ncpus = 1\nram-mib = 128\n"
                        'network = "tap"\n'
                        'ipv4 = "10.253.99.2/30"\n'
                        "probe-port = 9090"
                    ),
                ),
            )

            with self.assertRaisesRegex(
                ConfigError,
                "host tcp port 8080 is also published by first.toml",
            ):
                Fleet.build([first, second, tap])

    def test_disabled_service_keeps_identity_but_has_no_runtime_artifacts(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            disabled = self.write(
                directory,
                "disabled.toml",
                service_toml(
                    name="disabled",
                    container=(
                        "enabled = false\n"
                        'network = "host"\n\n'
                        "[[container.ports]]\n"
                        'host = "127.0.0.1:8080"\n'
                        "container = 8080\n\n"
                        "[[container.secrets]]\n"
                        'name = "disabled-token"'
                    ),
                    krun=(
                        "enabled = true\ncpus = 1\nram-mib = 128\n"
                        'network = "tap"\n'
                        'ipv4 = "10.253.99.2/30"\n'
                        "probe-port = 8080"
                    ),
                    extra=(
                        "\n[assets]\n"
                        'path = "/usr/share/custom-coreos/disabled"'
                    ),
                ),
            )
            active = self.write(
                directory,
                "active.toml",
                service_toml(
                    name="active",
                    uid=51990,
                    subid_start=800000000,
                    container=(
                        'network = "host"\n\n'
                        "[[container.ports]]\n"
                        'host = "127.0.0.1:8080"\n'
                        "container = 8080"
                    ),
                    krun=(
                        "enabled = true\ncpus = 1\nram-mib = 128\n"
                        'network = "tap"\n'
                        'ipv4 = "10.253.98.2/30"\n'
                        "probe-port = 8080"
                    ),
                ),
            )
            fleet = Fleet.build([disabled, active])
            artifacts = {
                artifact.path: artifact.content
                for artifact in compile_fleet(fleet)
            }
            paths = set(artifacts)

        self.assertIn(Path("usr/lib/sysusers.d/nas-disabled.conf"), paths)
        self.assertIn(Path("etc/subuid"), paths)
        self.assertNotIn(
            Path("etc/containers/systemd/users/51999/disabled.container"),
            paths,
        )
        self.assertEqual(
            [service.info.name for service in fleet.active_taps],
            ["active"],
        )
        self.assertIn(
            "ensure-nas-disabled-account.service",
            artifacts[Path("usr/share/custom-coreos/fleet/account-units.list")],
        )
        self.assertNotIn(
            "krun-51999\t",
            artifacts[Path("usr/share/custom-coreos/fleet/active-taps.tsv")],
        )
        self.assertIn(
            "disabled\t_nas_disabled\tdisabled-token",
            artifacts[Path("usr/share/custom-coreos/fleet/secrets.tsv")],
        )
        self.assertIn(
            "/usr/share/custom-coreos/disabled",
            artifacts[Path("usr/share/custom-coreos/fleet/assets.list")],
        )

    def test_fleet_requires_at_least_one_active_tap(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            service = self.write(
                directory,
                "service.toml",
                service_toml(),
            )
            with self.assertRaisesRegex(
                ConfigError,
                "must contain at least one active TAP service",
            ):
                Fleet.build([service])

    def test_active_fleet_without_assets_emits_a_header_only_manifest(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            service = self.write(
                directory,
                "service.toml",
                service_toml(
                    container=(
                        'network = "host"\n\n'
                        "[[container.ports]]\n"
                        'host = "127.0.0.1:8080"\n'
                        "container = 8080"
                    ),
                    krun=(
                        "enabled = true\ncpus = 1\nram-mib = 128\n"
                        'network = "tap"\n'
                        'ipv4 = "10.253.99.2/30"\n'
                        "probe-port = 8080"
                    ),
                ),
            )
            artifacts = {
                artifact.path: artifact.content
                for artifact in compile_fleet(Fleet.build([service]))
            }

        assets = artifacts[
            Path("usr/share/custom-coreos/fleet/assets.list")
        ]
        self.assertEqual(
            [line for line in assets.splitlines() if not line.startswith("#")],
            [],
        )
        account_script = artifacts[
            Path("usr/local/bin/ensure-nas-service-account.sh")
        ]
        self.assertNotIn("semanage fcontext", account_script)
        self.assertNotIn("restorecon", account_script)


if __name__ == "__main__":
    unittest.main()
