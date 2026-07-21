# ABOUTME: Regression tests for Garage's bounded normal-boot storage checks.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = (
    REPO / "overlay-root/usr/local/bin/zfs-create-garage-datasets.sh"
).read_text()


class GarageDatasetPreparationTests(unittest.TestCase):
    def test_normal_boot_has_no_recursive_preparation_or_ownership_scan(self):
        marker = 'if [[ "${preparation_mode}" == "normal" ]]'
        normal_branch = SCRIPT.split(marker, 1)[1].split("\nelse\n", 1)[0]

        self.assertIn('bounded_state_is_ready "${path}"', normal_branch)
        self.assertNotIn("prepare_dataset", normal_branch)
        self.assertNotIn("verify_descendant_owners", normal_branch)
        self.assertNotIn("restorecon_recursive", normal_branch)
        self.assertNotIn("find ", normal_branch)

    def test_bounded_sample_is_constant_depth(self):
        sample_function = SCRIPT.split("sample_descendant() {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn("-mindepth 1 -maxdepth 1", sample_function)
        self.assertIn("-print -quit", sample_function)

    def test_full_repair_requires_durable_state(self):
        self.assertIn(
            'REPAIR_REQUEST="${MIGRATION_DIR}/repair-required"', SCRIPT
        )
        self.assertIn('elif [[ -e "${REPAIR_REQUEST}" ]]', SCRIPT)
        self.assertIn('preparation_mode="requested-repair"', SCRIPT)
        self.assertIn('rm -f "${REPAIR_REQUEST}"', SCRIPT)

    def test_recursive_verification_fails_when_find_fails(self):
        verification = SCRIPT.split("verify_descendant_owners() {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn('if ! unexpected="$(find ', verification)
        self.assertIn("Unable to verify ownership", verification)

    def test_unconditional_descendant_scan_regression_is_absent(self):
        self.assertNotIn("descendant_owners_are_ready", SCRIPT)

    def test_mutation_guard_checks_both_stores_and_fails_closed(self):
        guard = SCRIPT.split("ensure_garage_stopped() {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn("podman container exists garage", guard)
        self.assertIn("rootless_podman container exists garage", guard)
        self.assertIn('if ! listeners="$(ss -H -ltn)"', guard)
        self.assertIn("Unable to inspect Garage host ports", guard)


if __name__ == "__main__":
    unittest.main()
