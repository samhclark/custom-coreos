# ABOUTME: Tests strict TOML decoding into the rootless-service model.

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from quadletgen.compiler import compile_fleet
from quadletgen.model import ConfigError, Fleet, Protocol
from quadletgen.parser import load_service
from quadletgen.storage_model import ManagedZfsStorage, StorageAccess
from tests.quadlet_test_support import REPO, service_toml


class StrictParserTests(unittest.TestCase):
    def load(self, source: str, filename: str = "service.toml"):
        with tempfile.TemporaryDirectory(dir=REPO) as directory:
            path = Path(directory) / filename
            path.write_text(source)
            return load_service(path)

    def assert_invalid(self, source: str, message: str) -> None:
        with self.assertRaisesRegex(ConfigError, message):
            self.load(source)

    def assert_invalid_field(self, source: str, field: str) -> None:
        with self.assertRaises(ConfigError) as raised:
            self.load(source)
        self.assertIn(field, str(raised.exception))

    def test_rejects_unknown_keys_at_every_closed_boundary(self):
        self.assert_invalid(
            service_toml(extra="\n[typo]\nvalue = true"),
            "unknown keys: typo",
        )
        self.assert_invalid(
            service_toml(container="imag = \"typo\""),
            "unknown keys: imag",
        )
        self.assert_invalid(
            service_toml(
                krun=(
                    "enabled = true\ncpus = 1\nram-mib = 128\n"
                    "network-mode = \"tap\""
                )
            ),
            "unknown keys: network-mode",
        )

    def test_requires_immutable_image_reference(self):
        self.assert_invalid(
            service_toml().replace(
                f"example.invalid/service:1@sha256:{'a' * 64}",
                "example.invalid/service:1",
            ),
            "immutable name:tag@sha256 digest",
        )

    def test_top_level_parser_integrates_typed_storage(self):
        service = self.load(
            service_toml(
                extra="""
[[storage]]
name = "state"
kind = "managed-zfs"
dataset = "tank/service/state"
host-path = "/var/lib/service"
mode = "0750"
record-size = "128K"
compression = "lz4"
atime = false
primary-cache = "all"

[[storage.exports]]
subpath = "."
container-path = "/state"
access = "read-write"
"""
            )
        )

        self.assertEqual(len(service.storage), 1)
        storage = service.storage[0]
        self.assertIsInstance(storage, ManagedZfsStorage)
        self.assertEqual(storage.exports[0].access, StorageAccess.READ_WRITE)

    def test_storage_policy_is_bound_to_the_service(self):
        managed = """
[[storage]]
name = "state"
kind = "managed-zfs"
dataset = "tank/other/state"
host-path = "/var/lib/service"
mode = "0750"
record-size = "128K"
compression = "lz4"
atime = false
primary-cache = "all"

[[storage.exports]]
subpath = "."
container-path = "/state"
access = "read-write"
"""
        self.assert_invalid(
            service_toml(extra=managed),
            "managed datasets must be below tank/service/",
        )
        self.assert_invalid(
            service_toml(
                container='''
[[container.volumes]]
source = "/var/lib/legacy"
target = "/state"
''',
                extra=managed.replace("tank/other/state", "tank/service/state"),
            ),
            "also a raw volume",
        )

    def test_service_identity_matches_dns_and_source_filename_contracts(self):
        for invalid_name in ("service-", "s" * 64):
            with self.subTest(name=invalid_name):
                self.assert_invalid(
                    service_toml().replace(
                        'name = "service"',
                        f'name = "{invalid_name}"',
                    ),
                    "must match",
                )

        with self.assertRaisesRegex(ConfigError, "filename must be"):
            self.load(service_toml(), filename="different.toml")

    def test_host_identity_stays_inside_repository_allocators(self):
        too_long_username = "_nas_" + "s" * 27
        self.assert_invalid_field(
            service_toml().replace(
                'username = "_nas_service"',
                f'username = "{too_long_username}"',
            ),
            "[host].username",
        )
        self.assert_invalid(
            service_toml(uid=50999),
            "must be at least 51000",
        )
        self.assert_invalid(
            service_toml(subid_start=2**32),
            "must be at most",
        )
        self.assert_invalid_field(
            service_toml().replace(
                'display-name = "Test service"',
                'display-name = "Test:service"',
            ),
            "[host].display-name",
        )

    def test_parses_typed_ports_dns_sysctls_and_secrets_in_source_order(self):
        service = self.load(
            service_toml(
                container="""
dns = ["100.100.100.100", "2001:db8::53"]
sysctls = ["net.ipv4.ip_forward=1"]

[[container.ports]]
host = "127.0.0.1:8080"
container = 80

[[container.ports]]
host = "[0:0:0:0:0:0:0:1]:5353"
container = 5353
protocol = "udp"

[[container.secrets]]
name = "token"
"""
            )
        )

        self.assertEqual(
            [port.protocol for port in service.container.ports],
            [Protocol.TCP, Protocol.UDP],
        )
        self.assertEqual(
            [str(server) for server in service.container.dns],
            ["100.100.100.100", "2001:db8::53"],
        )
        self.assertEqual(service.container.ports[1].host, "[::1]:5353")
        self.assertEqual(service.container.sysctls, ("net.ipv4.ip_forward=1",))
        self.assertEqual(service.container.secrets[0].name, "token")

    def test_rejects_invalid_port_declarations(self):
        cases = {
            "hostname": 'host = "localhost:8080"\ncontainer = 80',
            "unbracketed IPv6": 'host = "::1:8080"\ncontainer = 80',
            "port zero": 'host = "127.0.0.1:0"\ncontainer = 80',
            "boolean": 'host = "127.0.0.1:8080"\ncontainer = true',
            "protocol": (
                'host = "127.0.0.1:8080"\ncontainer = 80\n'
                'protocol = "sctp"'
            ),
        }
        for label, declaration in cases.items():
            with self.subTest(label=label):
                self.assert_invalid(
                    service_toml(
                        container=f"\n[[container.ports]]\n{declaration}"
                    ),
                    "container",
                )

    def test_enum_type_errors_remain_configuration_errors(self):
        self.assert_invalid_field(
            service_toml(
                container=(
                    "[[container.ports]]\n"
                    'host = "127.0.0.1:8080"\n'
                    "container = 80\n"
                    'protocol = ["tcp"]'
                )
            ),
            "[container].ports[1].protocol",
        )
        self.assert_invalid_field(
            service_toml(
                krun=(
                    "enabled = true\ncpus = 1\nram-mib = 128\n"
                    'network = ["tap"]'
                )
            ),
            "[krun].network",
        )

    def test_duplicate_ports_use_typed_canonical_endpoints(self):
        self.assert_invalid(
            service_toml(
                container=(
                    "[[container.ports]]\n"
                    'host = "[::1]:5353"\n'
                    "container = 5353\n"
                    'protocol = "udp"\n\n'
                    "[[container.ports]]\n"
                    'host = "[0:0:0:0:0:0:0:1]:5353"\n'
                    "container = 5354\n"
                    'protocol = "udp"'
                )
            ),
            "duplicate published port",
        )

    def test_rejects_host_ports_without_tap_exception(self):
        self.assert_invalid(
            service_toml(
                container=(
                    'network = "host"\n\n[[container.ports]]\n'
                    'host = "127.0.0.1:8080"\ncontainer = 80'
                )
            ),
            "cannot be used with network",
        )

    def test_rejects_invalid_krun_variants(self):
        cases = {
            "missing enabled": "cpus = 1\nram-mib = 128",
            "disabled fields": "enabled = false\ncpus = 1",
            "low RAM": "enabled = true\ncpus = 1\nram-mib = 127",
            "passt host": (
                "enabled = true\ncpus = 1\nram-mib = 128\n"
                'network = "passt"'
            ),
        }
        for label, krun in cases.items():
            with self.subTest(label=label):
                container = 'network = "host"' if label == "passt host" else ""
                self.assert_invalid(
                    service_toml(container=container, krun=krun),
                    "krun",
                )

    def test_disabled_krun_normalizes_to_absence(self):
        self.assertIsNone(self.load(service_toml(krun="enabled = false")).krun)

    def test_tap_uses_explicit_probe_port_and_derives_network_values(self):
        service = self.load(
            service_toml(
                container=(
                    'network = "host"\n\n[[container.ports]]\n'
                    'host = "127.0.0.1:8081"\ncontainer = 8081\n\n'
                    '[[container.ports]]\n'
                    'host = "127.0.0.1:8080"\ncontainer = 8080'
                ),
                krun=(
                    "enabled = true\ncpus = 1\nram-mib = 128\n"
                    'network = "tap"\nipv4 = "10.253.99.2/30"\n'
                    "probe-port = 8080"
                ),
            )
        )

        self.assertTrue(service.active_tap)
        self.assertEqual(service.tap_name, "krun-51999")
        self.assertEqual(str(service.tap_guest), "10.253.99.2/30")
        self.assertEqual(str(service.tap_gateway), "10.253.99.1/30")
        self.assertEqual(service.tap_spec.probe_port, 8080)
        artifacts = {
            artifact.path: artifact.content
            for artifact in compile_fleet(Fleet.build([service]))
        }
        unit = artifacts[
            Path("etc/containers/systemd/users/51999/service.container")
        ]
        self.assertIn("/dev/tcp/10.253.99.2/8080", unit)
        self.assertNotIn("/dev/tcp/10.253.99.2/8081", unit)

    def test_tap_probe_must_reference_a_declared_tcp_container_port(self):
        container = (
            'network = "host"\n\n[[container.ports]]\n'
            'host = "127.0.0.1:8080"\ncontainer = 8080\n'
            'protocol = "udp"'
        )
        base_krun = (
            "enabled = true\ncpus = 1\nram-mib = 128\n"
            'network = "tap"\nipv4 = "10.253.99.2/30"'
        )

        self.assert_invalid(
            service_toml(container=container, krun=base_krun),
            "missing 'probe-port'",
        )
        self.assert_invalid(
            service_toml(
                container=container,
                krun=f"{base_krun}\nprobe-port = 8080",
            ),
            "declared TCP container port",
        )
        self.assert_invalid(
            service_toml(
                container=(
                    f"{container}\n\n"
                    "[[container.ports]]\n"
                    'host = "127.0.0.1:9090"\n'
                    "container = 9090"
                ),
                krun=(
                    f"{base_krun}\nprobe-port = 9090\n\n"
                    "[[krun.ingress]]\n"
                    'from = "source"\n'
                    "ports = [8080]"
                ),
            ),
            "TAP ingress ports must also be declared TCP ports.*8080",
        )

    def test_health_cmd_supports_only_explicit_disable(self):
        service = self.load(service_toml(container='health-cmd = "none"'))
        self.assertEqual(service.container.health_cmd, "none")
        self.assert_invalid(
            service_toml(container='health-cmd = "curl /health"'),
            "supports only",
        )

    def test_single_line_fields_reject_directive_injection(self):
        cases = {
            "[service].description": service_toml().replace(
                'description = "Test service"',
                'description = "Test service\\nRequires=evil.service"',
            ),
            "[service].documentation": service_toml().replace(
                'description = "Test service"',
                'description = "Test service"\n'
                'documentation = "https://example.invalid/\\nRequires=evil.service"',
            ),
            "[host].display-name": service_toml().replace(
                'display-name = "Test service"',
                'display-name = "Test service\\nZ /tmp 0777 root root -"',
            ),
            "[container].exec": service_toml(
                container='exec = "server\\nEnvironment=EVIL=1"'
            ),
            "[container].volumes[1].comment": service_toml(
                container=(
                    "[[container.volumes]]\n"
                    'source = "/var/lib/service"\n'
                    'target = "/data"\n'
                    'comment = "safe\\nVolume=/tmp:/escape"'
                )
            ),
        }
        for field, source in cases.items():
            with self.subTest(field=field):
                self.assert_invalid_field(source, field)

    def test_unit_atoms_reject_ambiguous_systemd_syntax(self):
        cases = {
            "[container].image": service_toml().replace(
                "example.invalid/service:1@sha256:",
                "example.invalid/%service:1@sha256:",
            ),
            "[container.environment].BAD": service_toml(
                container='[container.environment]\nBAD = "two words"'
            ),
            "[container.environment].DOLLAR": service_toml(
                container=(
                    "[container.environment]\n"
                    'DOLLAR = "${USER}"'
                )
            ),
            "[container].sysctls": service_toml(
                container='sysctls = ["net.ipv4.ip_forward=%n"]'
            ),
            "[container].exec": service_toml(container='exec = "server; reboot"'),
            "[startup.readiness].url": service_toml(
                extra=(
                    "[startup.readiness]\n"
                    'url = "http://127.0.0.1:bad/ready"\n'
                    "timeout-sec = 5\ninterval-sec = 1"
                )
            ),
        }
        for field, source in cases.items():
            with self.subTest(field=field):
                self.assert_invalid_field(source, field)
        self.assert_invalid_field(
            service_toml(
                extra=(
                    "[startup.readiness]\n"
                    'url = "http://${HOST}:8080/ready"\n'
                    "timeout-sec = 5\ninterval-sec = 1"
                )
            ),
            "[startup.readiness].url",
        )

    def test_environment_names_are_identifiers(self):
        for environment_name in ("BAD-NAME", "1BAD"):
            with self.subTest(name=environment_name):
                self.assert_invalid_field(
                    service_toml(
                        container=(
                            "[container.environment]\n"
                            f'"{environment_name}" = "value"'
                        )
                    ),
                    "[container.environment] key",
                )

    def test_paths_and_modes_match_their_output_grammars(self):
        cases = {
            "[container].volumes[1].source": service_toml(
                container=(
                    "[[container.volumes]]\n"
                    'source = "/var/lib/../escape"\n'
                    'target = "/data"'
                )
            ),
            "[container].volumes[1].target": service_toml(
                container=(
                    "[[container.volumes]]\n"
                    'source = "/var/lib/service"\n'
                    'target = "/data:other"'
                )
            ),
            "[container].volumes[1].options": service_toml(
                container=(
                    "[[container.volumes]]\n"
                    'source = "/var/lib/service"\n'
                    'target = "/data"\n'
                    'options = "ro;rw"'
                )
            ),
            "[container].secrets[1].target": service_toml(
                container=(
                    "[[container.secrets]]\n"
                    'name = "token"\n'
                    'target = "relative/path"'
                )
            ),
            "[data].path": service_toml(
                extra='[data]\npath = "/tmp/service"'
            ),
            "[data].mode": service_toml(
                extra=(
                    "[data]\n"
                    'path = "/var/lib/service"\n'
                    'mode = "0888"'
                )
            ),
            "[assets].path": service_toml(
                extra=(
                    "[assets]\n"
                    'path = "/usr/share/custom-coreos/somewhere-else"'
                )
            ),
            "[startup.readiness].marker": service_toml(
                extra=(
                    "[startup.readiness]\n"
                    'marker = "/run/service/../ready"\n'
                    "timeout-sec = 5\ninterval-sec = 1"
                )
            ),
            "[[startup.readiness.paths]][1].mount-source": service_toml(
                extra=(
                    "[startup.readiness]\n"
                    'marker = "/run/service/ready"\n'
                    "timeout-sec = 5\ninterval-sec = 1\n\n"
                    "[[startup.readiness.paths]]\n"
                    'path = "/var/lib/service"\n'
                    'mount-source = "tank/service;bad"'
                )
            ),
            "[[startup.readiness.paths]][1].owner": service_toml(
                extra=(
                    "[startup.readiness]\n"
                    'marker = "/run/service/ready"\n'
                    "timeout-sec = 5\ninterval-sec = 1\n\n"
                    "[[startup.readiness.paths]]\n"
                    'path = "/var/lib/service"\n'
                    'owner = "root"'
                )
            ),
            "[[startup.readiness.paths]][1].access[1]": service_toml(
                extra=(
                    "[startup.readiness]\n"
                    'marker = "/run/service/ready"\n'
                    "timeout-sec = 5\ninterval-sec = 1\n\n"
                    "[[startup.readiness.paths]]\n"
                    'path = "/var/lib/service"\n'
                    'access = ["delete"]'
                )
            ),
        }
        for field, source in cases.items():
            with self.subTest(field=field):
                self.assert_invalid_field(source, field)

    def test_manifest_fields_reject_delimiters(self):
        self.assert_invalid(
            service_toml(
                container=(
                    "[[container.secrets]]\n"
                    'name = "bad\\tname"'
                )
            ),
            "control characters",
        )
        self.assert_invalid(
            service_toml(
                extra=(
                    "[assets]\n"
                    'path = "/usr/share/bad\\npath"'
                )
            ),
            "control characters",
        )

    def test_startup_policy_rejects_ambiguous_or_persistent_readiness(self):
        cases = {
            "both targets": (
                "[startup.readiness]\n"
                'marker = "/run/service/ready"\n'
                'url = "http://127.0.0.1/ready"\n'
                "timeout-sec = 5\ninterval-sec = 1"
            ),
            "persistent marker": (
                "[startup.readiness]\n"
                'marker = "/var/lib/service/ready"\n'
                "timeout-sec = 5\ninterval-sec = 1"
            ),
            "missing interval": (
                "[startup.readiness]\n"
                'marker = "/run/service/ready"\n'
                "timeout-sec = 5"
            ),
            "URL without host": (
                "[startup.readiness]\n"
                'url = "http:///ready"\n'
                "timeout-sec = 5\ninterval-sec = 1"
            ),
            "HTTP with path requirements": (
                "[startup.readiness]\n"
                'url = "http://127.0.0.1/ready"\n'
                "timeout-sec = 5\ninterval-sec = 1\n\n"
                "[[startup.readiness.paths]]\n"
                'path = "/var/lib/service"'
            ),
        }
        for label, startup in cases.items():
            with self.subTest(label=label):
                self.assert_invalid(service_toml(extra=startup), "startup.readiness")

    def test_startup_port_guard_and_subdirectories_are_validated(self):
        self.assert_invalid(
            service_toml(
                extra=(
                    "[startup]\n"
                    "require-published-tcp-ports-free = true"
                )
            ),
            "requires at least one published TCP port",
        )
        self.assert_invalid(
            service_toml(
                extra=(
                    "[data]\n"
                    'path = "/var/lib/service"\n'
                    'subdirectories = ["../escape"]'
                )
            ),
            "unsafe relative path",
        )


if __name__ == "__main__":
    unittest.main()
