# ABOUTME: Behaviorally tests the isolated host boundary for exact-image verification.

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
VERIFY = REPO / "scripts/verify-built-image.sh"


class BuiltImageContractTests(unittest.TestCase):
    def test_wrapper_inspects_labels_and_runs_without_host_access(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "arguments.log"
            fake = root / "container-cli"
            fake.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -eu
                    printf '%s\\n' "$*" >> "${FAKE_LOG}"
                    if [[ "$*" == *custom-coreos.kernel-version* ]]; then
                        printf '%s\\n' '7.1.4-200.fc44.x86_64'
                    elif [[ "$*" == *custom-coreos.zfs-version* ]]; then
                        printf '%s\\n' '2.4.3'
                    elif [[ "${1}" == run ]]; then
                        contract="$(cat)"
                        [[ "${contract}" == *'bootc container lint'* ]]
                    else
                        exit 64
                    fi
                    """
                )
            )
            fake.chmod(0o755)
            environment = os.environ | {
                "CONTAINER_CLI": str(fake),
                "FAKE_LOG": str(log),
            }

            subprocess.run(
                [str(VERIFY), "custom-coreos:contract-test"],
                cwd=REPO,
                env=environment,
                check=True,
            )

            calls = log.read_text().splitlines()
            self.assertEqual(len(calls), 3)
            run = calls[-1]
            self.assertIn("run --rm", run)
            self.assertIn("--network=none", run)
            self.assertIn("--pull=never", run)
            self.assertIn("--read-only", run)
            self.assertIn("--cap-drop=all", run)
            self.assertIn("--security-opt=no-new-privileges", run)
            self.assertNotIn("--volume", run)
            self.assertNotIn("--device", run)
            self.assertTrue(run.endswith("7.1.4-200.fc44.x86_64 2.4.3"))

    def test_wrapper_rejects_a_missing_version_label_before_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "container-cli"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "[[ \"$*\" == *kernel-version* ]] && printf '<no value>\\n' "
                "|| printf '2.4.3\\n'\n"
            )
            fake.chmod(0o755)

            result = subprocess.run(
                [str(VERIFY), "custom-coreos:contract-test"],
                cwd=REPO,
                env=os.environ | {"CONTAINER_CLI": str(fake)},
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required image version label is missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
