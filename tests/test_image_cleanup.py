# ABOUTME: Tests paginated, per-version GHCR cleanup planning.

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
PLANNER = REPO / "scripts/plan-image-cleanup.py"
SELECTOR = REPO / "scripts/select-expired-images.sh"


def version(
    identifier: int,
    created_at: str,
    tags: list[str] | None = None,
) -> dict[str, object]:
    return {
        "id": identifier,
        "created_at": created_at,
        "metadata": {"container": {"tags": tags or []}},
    }


class ImageCleanupTests(unittest.TestCase):
    def run_planner(
        self,
        pages: list[list[dict[str, object]]],
        *,
        github_output: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command: list[str | Path] = [
            PLANNER,
            "--cutoff",
            "2026-05-10T00:00:00Z",
        ]
        if github_output is not None:
            command += ["--github-output", github_output]
        source = "\n".join(json.dumps(page) for page in pages)
        return subprocess.run(
            command,
            input=source,
            capture_output=True,
            text=True,
            timeout=3,
        )

    def test_multiple_pages_are_flattened_and_versions_count_once(self):
        pages = [
            [
                version(40, "2026-05-09T00:00:00Z", ["stable", "old"]),
                version(30, "2026-05-10T00:00:00Z", ["at-cutoff"]),
            ],
            [
                version(20, "2026-04-01T00:00:00Z"),
                version(50, "2026-06-01T00:00:00Z", ["new"]),
            ],
        ]
        with tempfile.TemporaryDirectory(dir=REPO) as directory:
            output = Path(directory) / "github-output"
            result = self.run_planner(pages, github_output=output)
            github_fields = output.read_text()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Total package versions: 4", result.stdout)
        self.assertIn("Versions selected for deletion: 2", result.stdout)
        self.assertIn("Versions retained: 2", result.stdout)
        self.assertIn("tags=old,stable", result.stdout)
        self.assertIn("tags=<untagged>", result.stdout)
        self.assertLess(result.stdout.index("ID=20"), result.stdout.index("ID=40"))
        self.assertNotIn("ID=30", result.stdout)
        self.assertEqual(github_fields, "delete_versions=20,40\n")

    def test_duplicate_page_records_are_deduplicated_by_version_id(self):
        record = version(20, "2026-04-01T00:00:00Z", ["old"])

        result = self.run_planner([[record], [record]])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Total package versions: 1", result.stdout)
        self.assertIn("Versions selected for deletion: 1", result.stdout)

    def test_empty_pages_emit_an_empty_deletion_output(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory:
            output = Path(directory) / "github-output"
            result = self.run_planner([[], []], github_output=output)
            github_fields = output.read_text()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Total package versions: 0", result.stdout)
        self.assertEqual(github_fields, "delete_versions=\n")

    def test_conflicting_duplicate_records_fail_closed(self):
        result = self.run_planner(
            [
                [version(20, "2026-04-01T00:00:00Z")],
                [version(20, "2026-04-02T00:00:00Z")],
            ]
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicting records", result.stderr)

    def test_shell_selector_preserves_pages_and_github_api_failures(self):
        pages = [[version(20, "2026-04-01T00:00:00Z")], []]
        response = "\n".join(json.dumps(page) for page in pages)
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            fake_gh = directory / "gh"
            fake_date = directory / "date"
            gh_arguments = directory / "gh-arguments"
            fake_gh.write_text(
                "#!/bin/bash\nset -euo pipefail\n"
                "printf '%s\\n' \"$*\" > \"${FAKE_GH_ARGUMENTS}\"\n"
                "printf '%s\\n' \"${FAKE_GH_RESPONSE}\"\n"
            )
            fake_date.write_text(
                "#!/bin/bash\nset -euo pipefail\n"
                "printf '2026-05-10T00:00:00Z\\n'\n"
            )
            fake_gh.chmod(0o755)
            fake_date.chmod(0o755)
            environment = os.environ | {
                "GH_BIN": str(fake_gh),
                "DATE_BIN": str(fake_date),
                "FAKE_GH_ARGUMENTS": str(gh_arguments),
                "FAKE_GH_RESPONSE": response,
            }

            success = subprocess.run(
                [SELECTOR, "90"],
                env=environment,
                capture_output=True,
                text=True,
                timeout=3,
            )
            success_args = gh_arguments.read_text()

            legacy = subprocess.run(
                [SELECTOR, "90"],
                env=environment | {"CONTAINER_PACKAGE_NAME": "custom-coreos"},
                capture_output=True,
                text=True,
                timeout=3,
            )
            legacy_args = gh_arguments.read_text()

            fake_gh.write_text("#!/bin/bash\nexit 7\n")
            failure = subprocess.run(
                [SELECTOR, "90"],
                env=environment,
                capture_output=True,
                text=True,
                timeout=3,
            )

        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertIn("Total package versions: 1", success.stdout)
        self.assertIn(
            "/user/packages/container/nas%2Fbootc/versions --paginate",
            success_args,
        )
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertIn(
            "/user/packages/container/custom-coreos/versions --paginate",
            legacy_args,
        )

        self.assertEqual(failure.returncode, 7)
        self.assertNotIn("paginated API response", failure.stderr)


if __name__ == "__main__":
    unittest.main()
