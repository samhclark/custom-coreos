# ABOUTME: Locks the opt-in VM runner to a single-disk, networkless safety boundary.

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
RUNNER_PATH = REPO / "scripts/run-vm-smoke.sh"
RUNNER = RUNNER_PATH.read_text()
IGNITION = (REPO / "tests/vm-smoke.bu").read_text()


class VmSmokeSafetyTests(unittest.TestCase):
    def test_qemu_has_one_transient_disk_and_no_connectivity(self):
        self.assertEqual(RUNNER.count("    -drive "), 1)
        for required in (
            "-snapshot",
            "-nic none",
            "-nodefaults",
            "-display none",
            "-monitor none",
            "-sandbox on,obsolete=deny,elevateprivileges=deny,"
            "spawn=deny,resourcecontrol=deny",
            "-fw_cfg \"name=opt/com.coreos/config,file=${ignition}\"",
        ):
            with self.subTest(required=required):
                self.assertIn(required, RUNNER)
        self.assertNotIn("sudo", RUNNER)
        self.assertNotIn("--device", RUNNER)
        self.assertNotIn("--volume", RUNNER)
        for forbidden_option in (
            "-blockdev",
            "-cdrom",
            "-hda",
            "-hdb",
            "-netdev",
            "-fsdev",
            "-virtfs",
        ):
            self.assertNotIn(forbidden_option, RUNNER)

    def test_runner_never_converts_cleans_or_commits_the_input(self):
        for forbidden in (
            "qemu-img create",
            "qemu-img convert",
            "qemu-img commit",
            "qemu-img rebase",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, RUNNER)
        self.assertIsNone(re.search(r"^\s*(?:rm|rmdir)\b", RUNNER, re.MULTILINE))
        self.assertIn("before_hash", RUNNER)
        self.assertIn("after_hash", RUNNER)
        self.assertIn("mktemp -d \"${repo}/build/vm-smoke/", RUNNER)
        self.assertIn("TMPDIR=\"${run_dir}\"", RUNNER)

    def test_qemu_option_paths_reject_field_separators(self):
        self.assertIn("must not contain commas or newlines", RUNNER)

    def test_serial_sentinel_is_normalized_before_exact_matching(self):
        self.assertIn("tr -d '\\r'", RUNNER)
        self.assertIn("grep -Fqx 'NAS_VM_SMOKE_PASS'", RUNNER)

    def test_smoke_service_has_no_multi_user_ordering_cycle(self):
        self.assertIn("WantedBy=multi-user.target", IGNITION)
        self.assertNotIn("After=multi-user.target", IGNITION)
        self.assertNotIn("Wants=multi-user.target", IGNITION)

    def test_ignition_has_no_storage_fixture_or_production_authority(self):
        for forbidden in (
            "zpool ",
            "zfs create",
            "zfs destroy",
            "zfs set",
            "zfs rollback",
            "mkfs",
            "wipefs",
            "/dev/sd",
            "/dev/nvme",
            "/dev/disk",
            "/dev/mapper",
            "luks",
            "cryptsetup",
            "sgdisk",
            "parted",
            "blkdiscard",
            "mount ",
            "nas-secrets",
            "secrets.sops",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, IGNITION.lower())
        self.assertIn("mask: true", IGNITION)
        self.assertIn("NAS_VM_SMOKE_PASS", IGNITION)


class VmSmokeRunnerBehaviorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repo"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "tests").mkdir()
        (self.root / "scripts/run-vm-smoke.sh").symlink_to(RUNNER_PATH)
        (self.root / "tests/vm-smoke.bu").write_text(IGNITION)

        self.qcow = self.root / "fresh.qcow2"
        self.qcow.write_bytes(b"standalone qcow fixture")
        self.ovmf = self.root / "OVMF_CODE.fd"
        self.ovmf.write_bytes(b"firmware fixture")
        self.qemu_log = self.root / "qemu-arguments.json"
        self.image_log = self.root / "qemu-img.log"
        self.container_log = self.root / "container-arguments.log"
        self.ignition_input = self.root / "butane-input.bu"

        self.qemu_img = self.executable(
            "qemu-img",
            """
            printf '%s\\n' "$*" >> "${FAKE_IMAGE_LOG}"
            case "${1:-}" in
                info)
                    printf '%s\\n' "${FAKE_IMAGE_INFO}"
                    ;;
                check)
                    exit "${FAKE_IMAGE_CHECK_STATUS:-0}"
                    ;;
                *)
                    exit 64
                    ;;
            esac
            """,
        )
        self.container = self.executable(
            "container-cli",
            """
            printf '%s\\n' "$@" > "${FAKE_CONTAINER_LOG}"
            tee "${FAKE_IGNITION_INPUT}" >/dev/null
            printf '{}\\n'
            """,
        )
        self.timeout = self.executable(
            "timeout",
            r"""
            python3 - "$@" <<'PY'
            import json
            import os
            import sys
            from pathlib import Path

            arguments = sys.argv[1:]
            Path(os.environ["FAKE_QEMU_LOG"]).write_text(
                json.dumps({"arguments": arguments, "tmpdir": os.environ["TMPDIR"]})
            )
            qemu_arguments = arguments[5:]
            serial = qemu_arguments[qemu_arguments.index("-serial") + 1]
            if not serial.startswith("file:"):
                raise SystemExit(65)
            sentinel = os.environ.get("FAKE_GUEST_SENTINEL", "PASS")
            output = "NAS_VM_SMOKE_BEGIN\r\n"
            if sentinel != "NONE":
                output += f"NAS_VM_SMOKE_{sentinel}\r\n"
            Path(serial.removeprefix("file:")).write_bytes(output.encode())
            if os.environ.get("FAKE_MUTATE_QCOW") == "1":
                drive = qemu_arguments[qemu_arguments.index("-drive") + 1]
                fields = dict(field.split("=", 1) for field in drive.split(","))
                with Path(fields["file"]).open("ab") as image:
                    image.write(b"mutated")
            raise SystemExit(int(os.environ.get("FAKE_QEMU_STATUS", "0")))
            PY
            """,
        )
        self.environment = os.environ | {
            "CONTAINER_CLI": str(self.container),
            "BUTANE_IMAGE": "example.invalid/butane@sha256:pinned",
            "QEMU_BIN": "/nonexistent/qemu-system-x86_64",
            "QEMU_IMG_BIN": str(self.qemu_img),
            "JQ_BIN": "jq",
            "TIMEOUT_BIN": str(self.timeout),
            "OVMF_CODE": str(self.ovmf),
            "FAKE_IMAGE_INFO": json.dumps(
                {"format": "qcow2", "format-specific": {"data": {}}}
            ),
            "FAKE_IMAGE_LOG": str(self.image_log),
            "FAKE_CONTAINER_LOG": str(self.container_log),
            "FAKE_IGNITION_INPUT": str(self.ignition_input),
            "FAKE_QEMU_LOG": str(self.qemu_log),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, name: str, body: str) -> Path:
        path = self.root / name
        path.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            + textwrap.dedent(body).lstrip()
        )
        path.chmod(0o755)
        return path

    def run_runner(self, **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.root / "scripts/run-vm-smoke.sh", self.qcow],
            cwd=self.root,
            env=self.environment | environment,
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_success_uses_the_exact_isolated_qemu_contract(self):
        result = self.run_runner()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NAS_VM_SMOKE_PASS", result.stdout)
        invocation = json.loads(self.qemu_log.read_text())
        arguments = invocation["arguments"]
        self.assertEqual(
            arguments[:5],
            [
                "--foreground",
                "--signal=TERM",
                "--kill-after=10s",
                "180s",
                "/nonexistent/qemu-system-x86_64",
            ],
        )
        qemu_arguments = arguments[5:]
        self.assertEqual(qemu_arguments.count("-drive"), 1)
        self.assertEqual(qemu_arguments.count("-device"), 1)
        self.assertEqual(
            qemu_arguments[qemu_arguments.index("-device") + 1],
            "virtio-blk-pci,drive=osdisk,bootindex=1",
        )
        self.assertEqual(qemu_arguments[qemu_arguments.index("-nic") + 1], "none")
        self.assertIn("-snapshot", qemu_arguments)
        self.assertIn("-nodefaults", qemu_arguments)
        for forbidden in ("-blockdev", "-cdrom", "-hda", "-netdev", "-fsdev"):
            self.assertNotIn(forbidden, qemu_arguments)
        self.assertTrue(Path(invocation["tmpdir"]).is_relative_to(self.root / "build"))

        self.assertEqual(
            self.image_log.read_text().splitlines(),
            [
                f"info --output=json {self.qcow}",
                f"check --quiet -f qcow2 {self.qcow}",
            ],
        )
        container_arguments = self.container_log.read_text().splitlines()
        for required in (
            "--network=none",
            "--pull=never",
            "--read-only",
            "--cap-drop=all",
            "--security-opt=no-new-privileges",
        ):
            self.assertIn(required, container_arguments)
        self.assertNotIn("--volume", container_arguments)
        self.assertEqual(self.ignition_input.read_text(), IGNITION)
        self.assertNotEqual(IGNITION, (REPO / "butane.yaml").read_text())

    def test_backing_and_external_data_files_are_rejected_before_qemu(self):
        unsafe_records = (
            {"backing-filename": "https://example.invalid/base"},
            {"full-backing-filename": "/host/base.qcow2"},
            {"format-specific": {"data": {"data-file": "/host/data.raw"}}},
        )
        for extra in unsafe_records:
            with self.subTest(extra=extra):
                record = {"format": "qcow2", "format-specific": {"data": {}}}
                record.update(extra)
                result = self.run_runner(FAKE_IMAGE_INFO=json.dumps(record))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be standalone", result.stderr)
                self.assertFalse(self.qemu_log.exists())

    def test_corrupt_image_is_rejected_before_qemu(self):
        result = self.run_runner(FAKE_IMAGE_CHECK_STATUS="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("integrity check failed", result.stderr)
        self.assertFalse(self.qemu_log.exists())

    def test_base_image_mutation_fails_even_after_guest_pass(self):
        result = self.run_runner(FAKE_MUTATE_QCOW="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QCOW changed despite the transient VM contract", result.stderr)

    def test_guest_failure_and_missing_pass_report_retained_artifacts(self):
        for sentinel, message in (
            ("FAIL status=1", "Guest reported a failed assertion"),
            ("NONE", "Guest did not report a pass sentinel"),
        ):
            with self.subTest(sentinel=sentinel):
                result = self.run_runner(FAKE_GUEST_SENTINEL=sentinel)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertIn("artifacts:", result.stderr)


if __name__ == "__main__":
    unittest.main()
