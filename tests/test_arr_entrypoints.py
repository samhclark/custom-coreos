# ABOUTME: Verifies the image-controlled *arr and SABnzbd entrypoint contracts.

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
ENTRYPOINT_ROOT = REPO / "overlay-root/usr/share/custom-coreos"


SERVICES = {
    "sonarr": {
        "script": ENTRYPOINT_ROOT / "sonarr/sonarr-entrypoint.sh",
        "command": "/app/sonarr/bin/Sonarr -nobrowser -data=/config",
        "temp_dir": "/run/sonarr-temp",
    },
    "radarr": {
        "script": ENTRYPOINT_ROOT / "radarr/radarr-entrypoint.sh",
        "command": "/app/radarr/bin/Radarr -nobrowser -data=/config",
        "temp_dir": "/run/radarr-temp",
    },
    "prowlarr": {
        "script": ENTRYPOINT_ROOT / "prowlarr/prowlarr-entrypoint.sh",
        "command": "/app/prowlarr/bin/Prowlarr -nobrowser -data=/config",
        "temp_dir": "/run/prowlarr-temp",
    },
}

class ArrEntrypointContractTests(unittest.TestCase):
    def test_dotnet_adapters_have_the_required_identity_and_command_contract(self):
        for service, contract in SERVICES.items():
            with self.subTest(service=service):
                script = contract["script"].read_text()
                mode = contract["script"].stat().st_mode

                self.assertTrue(mode & stat.S_IXUSR)
                self.assertIn("set -euo pipefail", script)
                self.assertIn("umask 002", script)
                self.assertNotIn("groupmod", script)
                self.assertNotIn("usermod", script)
                self.assertIn("exec s6-setuidgid 1000:1000", script)
                self.assertIn("expected root or 1000:1000", script)
                self.assertIn(contract["command"], script)
                self.assertIn('"$@"', script)
                self.assertIn('mkdir -p "${temp_dir}"', script)
                self.assertIn('chown 1000:1000 "${temp_dir}"', script)
                self.assertNotIn("chown -R", script)

    def test_sabnzbd_has_the_family_selection_and_no_temp_directory(self):
        script = (
            ENTRYPOINT_ROOT / "sabnzbd/sabnzbd-entrypoint.sh"
        ).read_text()

        self.assertIn("if [[ -e /proc/net/if_inet6 ]]; then", script)
        self.assertIn('readonly family="::"', script)
        self.assertIn('readonly family="0.0.0.0"', script)
        self.assertIn(
            "python3 /app/sabnzbd/SABnzbd.py --config-file /config",
            script,
        )
        self.assertIn('--server "${family}" "$@"', script)
        self.assertNotIn("mkdir", script)
        self.assertNotIn("chown", script)

    def test_root_mode_prepares_temp_and_handoffs_numerically(self):
        for service, contract in SERVICES.items():
            with self.subTest(service=service):
                log, result = self._run_with_fake_root_commands(
                    contract["script"],
                    uid="0",
                    gid="0",
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("groupmod", log)
                self.assertNotIn("usermod", log)
                self.assertIn(f'mkdir -p {contract["temp_dir"]}', log)
                self.assertIn(f'chown 1000:1000 {contract["temp_dir"]}', log)
                self.assertIn(
                    f"s6-setuidgid 1000:1000 {contract['command']} --test-flag value",
                    log,
                )
                self.assertNotIn("chown -R", log)

    def test_sabnzbd_root_mode_uses_the_host_ipv6_family_signal(self):
        script = ENTRYPOINT_ROOT / "sabnzbd/sabnzbd-entrypoint.sh"
        log, result = self._run_with_fake_root_commands(
            script,
            uid="0",
            gid="0",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        expected_family = (
            "::" if Path("/proc/net/if_inet6").exists() else "0.0.0.0"
        )
        self.assertIn(
            "s6-setuidgid 1000:1000 python3 /app/sabnzbd/SABnzbd.py "
            f"--config-file /config --server {expected_family} --test-flag value",
            log,
        )

    def test_unexpected_identity_is_rejected_before_launch(self):
        script = ENTRYPOINT_ROOT / "sonarr/sonarr-entrypoint.sh"
        log, result = self._run_with_fake_root_commands(
            script,
            uid="1234",
            gid="1234",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported effective identity 1234:1234", result.stderr)
        self.assertEqual(log, "")

    def test_uid_1000_with_the_wrong_gid_is_rejected(self):
        script = ENTRYPOINT_ROOT / "radarr/radarr-entrypoint.sh"
        log, result = self._run_with_fake_root_commands(
            script,
            uid="1000",
            gid="1001",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UID 1000 requires GID 1000", result.stderr)
        self.assertEqual(log, "")

    @staticmethod
    def _run_with_fake_root_commands(
        script: Path,
        *,
        uid: str,
        gid: str,
    ) -> tuple[str, subprocess.CompletedProcess[str]]:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            fake_bin = temp / "bin"
            fake_bin.mkdir()
            log_path = temp / "commands.log"

            (fake_bin / "id").write_text(
                "#!/usr/bin/env bash\n"
                'case "$1" in\n'
                f'    -u) printf "%s\\n" "{uid}" ;;\n'
                f'    -g) printf "%s\\n" "{gid}" ;;\n'
                "esac\n"
            )
            (fake_bin / "mkdir").write_text(
                "#!/usr/bin/env bash\n"
                f'printf "mkdir %s\\n" "$*" >> "{log_path}"\n'
            )
            (fake_bin / "chown").write_text(
                "#!/usr/bin/env bash\n"
                f'printf "chown %s\\n" "$*" >> "{log_path}"\n'
            )
            (fake_bin / "s6-setuidgid").write_text(
                "#!/usr/bin/env bash\n"
                f'printf "s6-setuidgid %s\\n" "$*" >> "{log_path}"\n'
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)

            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"

            result = subprocess.run(
                [str(script), "--test-flag", "value"],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            log = log_path.read_text() if log_path.exists() else ""
            return log, result
