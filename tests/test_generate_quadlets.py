# ABOUTME: Unit tests for declarative Quadlet generation and stale-output cleanup.

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "generate_quadlets", REPO / "generate-quadlets.py"
)
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class RemoveStaleGeneratedTests(unittest.TestCase):
    def test_removes_only_unexpected_generated_files_and_empty_directories(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            overlay = Path(tmpdir) / "overlay-root"
            expected = overlay / "etc/containers/systemd/users/51210/current.container"
            stale = overlay / "etc/containers/systemd/users/59999/old.container"
            stale_script = overlay / "usr/local/bin/ensure-nas-old-account.sh"
            handwritten = overlay / "etc/systemd/system/handwritten.service"

            for path in (expected, stale, stale_script, handwritten):
                path.parent.mkdir(parents=True, exist_ok=True)

            expected.write_text(GENERATOR.header(Path("current.toml")) + "\n")
            stale.write_text(GENERATOR.header(Path("old.toml")) + "\n")
            stale_script.write_text(
                "#!/bin/bash\n" + GENERATOR.header(Path("old.toml")) + "\n"
            )
            handwritten.write_text("[Unit]\nDescription=Handwritten\n")

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                GENERATOR.remove_stale_generated({expected}, overlay)

            self.assertTrue(expected.exists())
            self.assertTrue(handwritten.exists())
            self.assertFalse(stale.exists())
            self.assertFalse(stale.parent.exists())
            self.assertFalse(stale_script.exists())
            self.assertTrue(stale_script.parent.exists())
            self.assertEqual(
                output.getvalue().splitlines(),
                [
                    f"removed {stale.relative_to(REPO)}",
                    f"removed {stale_script.relative_to(REPO)}",
                ],
            )

    def test_does_not_follow_a_symlink_with_a_generated_target(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            overlay = Path(tmpdir) / "overlay-root"
            target = Path(tmpdir) / "generated-target"
            link = overlay / "usr/local/bin/linked-file"
            link.parent.mkdir(parents=True)
            target.write_text(GENERATOR.header(Path("old.toml")) + "\n")
            link.symlink_to(target)

            GENERATOR.remove_stale_generated(set(), overlay)

            self.assertTrue(link.is_symlink())
            self.assertTrue(target.exists())


class PublishedPortTests(unittest.TestCase):
    def test_validates_and_renders_ipv4_and_ipv6_ports_in_source_order(self):
        container = {
            "image": "example.invalid/service:1",
            "ports": [
                {"host": "127.0.0.1:3900", "container": 3900},
                {"host": "[::1]:3901", "container": 3901},
            ],
        }
        GENERATOR.validate_ports("service.toml", container)

        cfg = {
            "_toml_path": Path("service.toml"),
            "service": {"name": "service", "description": "Test service"},
            "host": {"username": "_nas_service"},
            "container": container,
        }
        unit = GENERATOR.container_unit(cfg)

        self.assertIn(
            "PublishPort=127.0.0.1:3900:3900\n"
            "PublishPort=[::1]:3901:3901\n",
            unit,
        )
        self.assertNotIn("AutoUpdate=", unit)
        self.assertNotIn("Pull=", unit)

    def test_rejects_invalid_port_declarations(self):
        invalid_cases = {
            "host networking": {
                "network": "host",
                "ports": [{"host": "127.0.0.1:3900", "container": 3900}],
            },
            "hostname": {
                "ports": [{"host": "localhost:3900", "container": 3900}],
            },
            "unbracketed IPv6": {
                "ports": [{"host": "::1:3900", "container": 3900}],
            },
            "host port zero": {
                "ports": [{"host": "127.0.0.1:0", "container": 3900}],
            },
            "container port too large": {
                "ports": [{"host": "127.0.0.1:3900", "container": 65536}],
            },
            "boolean container port": {
                "ports": [{"host": "127.0.0.1:3900", "container": True}],
            },
            "missing host": {"ports": [{"container": 3900}]},
            "unknown key": {
                "ports": [
                    {
                        "host": "127.0.0.1:3900",
                        "container": 3900,
                        "protocol": "udp",
                    }
                ],
            },
            "duplicate": {
                "ports": [
                    {"host": "127.0.0.1:3900", "container": 3900},
                    {"host": "127.0.0.1:3900", "container": 3900},
                ],
            },
        }

        for label, container in invalid_cases.items():
            with self.subTest(label=label), self.assertRaises(SystemExit):
                with contextlib.redirect_stderr(io.StringIO()):
                    GENERATOR.validate_ports("service.toml", container)


class DnsTests(unittest.TestCase):
    def test_validates_and_renders_dns_servers_in_source_order(self):
        container = {
            "image": "example.invalid/service:1",
            "network": "host",
            "dns": ["100.100.100.100", "75.75.75.75", "2001:db8::53"],
        }
        GENERATOR.validate_dns("service.toml", container)

        cfg = {
            "_toml_path": Path("service.toml"),
            "service": {"name": "service", "description": "Test service"},
            "host": {"username": "_nas_service"},
            "container": container,
        }
        unit = GENERATOR.container_unit(cfg)

        self.assertIn(
            "Network=host\n"
            "DNS=100.100.100.100\n"
            "DNS=75.75.75.75\n"
            "DNS=2001:db8::53\n",
            unit,
        )

    def test_rejects_invalid_dns_declarations(self):
        invalid_cases = {
            "not an array": {"dns": "100.100.100.100"},
            "non-string": {"dns": [100]},
            "hostname": {"dns": ["resolver.example.com"]},
            "duplicate": {"dns": ["75.75.75.75", "75.75.75.75"]},
        }

        for label, container in invalid_cases.items():
            with self.subTest(label=label), self.assertRaises(SystemExit):
                with contextlib.redirect_stderr(io.StringIO()):
                    GENERATOR.validate_dns("service.toml", container)

    def test_accepts_loopback_dns_for_ordinary_host_networking(self):
        GENERATOR.validate_dns(
            "service.toml",
            {"network": "host", "dns": ["127.0.0.53"]},
        )


class StagedServiceTests(unittest.TestCase):
    def test_disabled_container_keeps_identity_outputs_but_omits_quadlet(self):
        cfg = {
            "_toml_path": Path("caddy.toml"),
            "_slug": "caddy",
            "service": {"name": "caddy"},
            "host": {"uid": 51310},
            "container": {"enabled": False},
        }

        paths = GENERATOR.generated_paths(cfg)

        self.assertNotIn(
            GENERATOR.OVERLAY
            / "etc/containers/systemd/users/51310/caddy.container",
            paths,
        )
        self.assertIn(
            GENERATOR.OVERLAY
            / "etc/systemd/system/ensure-nas-caddy-account.service",
            paths,
        )

    def test_rejects_non_boolean_container_enabled_value(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            toml_path = Path(tmpdir) / "invalid.toml"
            toml_path.write_text(
                """
[service]
name = "invalid"
description = "Invalid staged service"

[host]
username = "_nas_invalid"
uid = 51999
subid-start = 519990000
display-name = "Invalid"

[container]
enabled = "false"
image = "example.invalid/invalid:1"
"""
            )

            with self.assertRaises(SystemExit), contextlib.redirect_stderr(
                io.StringIO()
            ):
                GENERATOR.load_service(toml_path)


class ImmutableImageTests(unittest.TestCase):
    def write_service(self, directory: str, container_lines: str) -> Path:
        toml_path = Path(directory) / "service.toml"
        toml_path.write_text(
            f"""
[service]
name = "service"
description = "Test service"

[host]
username = "_nas_service"
uid = 51999
subid-start = 519990000
display-name = "Service"

[container]
{container_lines}
"""
        )
        return toml_path

    def test_accepts_tag_and_sha256_digest(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            toml_path = self.write_service(
                tmpdir,
                'image = "example.invalid/service:1.2.3@sha256:'
                + "a" * 64
                + '"',
            )

            cfg = GENERATOR.load_service(toml_path)

            self.assertEqual(cfg["service"]["name"], "service")

    def test_rejects_tag_without_digest(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            toml_path = self.write_service(
                tmpdir, 'image = "example.invalid/service:1.2.3"'
            )

            with self.assertRaises(SystemExit), contextlib.redirect_stderr(
                io.StringIO()
            ):
                GENERATOR.load_service(toml_path)

    def test_rejects_legacy_pull_and_auto_update_settings(self):
        for key, value in (("pull", "always"), ("auto-update", "registry")):
            with self.subTest(key=key), tempfile.TemporaryDirectory(
                dir=REPO
            ) as tmpdir:
                toml_path = self.write_service(
                    tmpdir,
                    'image = "example.invalid/service:1.2.3@sha256:'
                    + "a" * 64
                    + f'"\n{key} = "{value}"',
                )

                with self.assertRaises(SystemExit), contextlib.redirect_stderr(
                    io.StringIO()
                ):
                    GENERATOR.load_service(toml_path)


class KrunTests(unittest.TestCase):
    def write_service(self, directory: str, krun_lines: str | None) -> Path:
        krun_section = ""
        if krun_lines is not None:
            krun_section = f"\n[krun]\n{krun_lines}\n"

        toml_path = Path(directory) / "service.toml"
        toml_path.write_text(
            """
[service]
name = "service"
description = "Test service"

[host]
username = "_nas_service"
uid = 51999
subid-start = 519990000
display-name = "Service"

[container]
image = "example.invalid/service:1@sha256:"""
            + "a" * 64
            + '"\n'
            + krun_section
        )
        return toml_path

    def test_valid_krun_config_renders_runtime_resources_and_stop_signal(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            cfg = GENERATOR.load_service(
                self.write_service(
                    tmpdir,
                    "enabled = true\ncpus = 2\nram-mib = 512",
                )
            )

            unit = GENERATOR.container_unit(cfg)

            self.assertIn(
                "Image=example.invalid/service:1@sha256:"
                + "a" * 64
                + "\n"
                "PodmanArgs=--runtime=krun\n"
                "Annotation=krun.cpus=2\n"
                "Annotation=krun.ram_mib=512\n"
                "StopSignal=SIGINT\n",
                unit,
            )

    def test_service_without_krun_has_no_runtime_output(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            cfg = GENERATOR.load_service(self.write_service(tmpdir, None))

            unit = GENERATOR.container_unit(cfg)

            self.assertNotIn("runtime=krun", unit)
            self.assertNotIn("Annotation=krun.", unit)
            self.assertNotIn("StopSignal=", unit)

    def test_disabled_krun_accepts_no_other_fields_and_renders_nothing(self):
        with tempfile.TemporaryDirectory(dir=REPO) as tmpdir:
            cfg = GENERATOR.load_service(
                self.write_service(tmpdir, "enabled = false")
            )

            unit = GENERATOR.container_unit(cfg)

            self.assertNotIn("runtime=krun", unit)
            self.assertNotIn("StopSignal=", unit)

    def test_rejects_invalid_krun_config(self):
        invalid_cases = {
            "missing enabled": "cpus = 1\nram-mib = 128",
            "non-boolean enabled": 'enabled = "true"\ncpus = 1\nram-mib = 128',
            "fields while disabled": "enabled = false\ncpus = 1",
            "missing cpus": "enabled = true\nram-mib = 128",
            "boolean cpus": "enabled = true\ncpus = true\nram-mib = 128",
            "zero cpus": "enabled = true\ncpus = 0\nram-mib = 128",
            "missing RAM": "enabled = true\ncpus = 1",
            "boolean RAM": "enabled = true\ncpus = 1\nram-mib = true",
            "RAM below minimum": "enabled = true\ncpus = 1\nram-mib = 127",
            "unknown key": (
                "enabled = true\ncpus = 1\nram-mib = 128\nuse-passt = true"
            ),
        }

        for label, krun_lines in invalid_cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory(
                dir=REPO
            ) as tmpdir:
                with self.assertRaises(SystemExit), contextlib.redirect_stderr(
                    io.StringIO()
                ):
                    GENERATOR.load_service(
                        self.write_service(tmpdir, krun_lines)
                    )

    def test_rejects_loopback_dns_with_krun_host_networking(self):
        cfg = {
            "container": {"network": "host", "dns": ["127.0.0.53"]},
            "krun": {"enabled": True, "cpus": 1, "ram-mib": 128},
        }

        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            GENERATOR.validate_krun("service.toml", cfg)


if __name__ == "__main__":
    unittest.main()
