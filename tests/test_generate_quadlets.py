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


if __name__ == "__main__":
    unittest.main()
