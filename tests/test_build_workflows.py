# ABOUTME: Guards the shared validation boundary used by image build workflows.

from __future__ import annotations

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
WORKFLOWS = REPO / ".github/workflows"


class BuildWorkflowTests(unittest.TestCase):
    def test_image_workflows_use_one_reusable_preflight(self):
        preflight = (WORKFLOWS / "build-preflight.yaml").read_text()
        self.assertIn("workflow_call:", preflight)
        self.assertIn("verify-repository:", preflight)
        self.assertIn("verify-sops-image:", preflight)
        self.assertIn("query-versions:", preflight)
        self.assertEqual(preflight.count("run: make check"), 1)
        self.assertEqual(preflight.count("run: make test"), 1)
        self.assertIn("uses: astral-sh/setup-uv@", preflight)
        self.assertNotIn("actions/setup-python", preflight)
        self.assertNotIn("pip install", preflight)

        for filename in ("build.yaml", "build-check.yaml"):
            with self.subTest(filename=filename):
                workflow = (WORKFLOWS / filename).read_text()
                self.assertEqual(
                    workflow.count(
                        "uses: ./.github/workflows/build-preflight.yaml"
                    ),
                    1,
                )
                self.assertIn("needs: preflight", workflow)
                self.assertIn("needs.preflight.outputs.zfs-version", workflow)
                self.assertIn("needs.preflight.outputs.kernel-version", workflow)
                self.assertNotIn("make check", workflow)
                self.assertNotIn("make test", workflow)
                self.assertNotIn("Verify SOPS image signature", workflow)
                self.assertNotIn("Resolve and verify build inputs", workflow)
                self.assertEqual(workflow.count("make verify-image"), 1)

    def test_production_image_is_verified_before_registry_login_and_push(self):
        workflow = (WORKFLOWS / "build.yaml").read_text()

        verification = workflow.index("make verify-image")
        self.assertLess(verification, workflow.index("Log in to Container Registry"))
        self.assertLess(verification, workflow.index("Push to registry"))

    def test_signature_policy_exists_only_in_shared_preflight(self):
        identity = "--certificate-identity-regexp=https://github.com/getsops"
        issuer = (
            "--certificate-oidc-issuer="
            "https://token.actions.githubusercontent.com"
        )
        preflight = (WORKFLOWS / "build-preflight.yaml").read_text()
        self.assertEqual(preflight.count(identity), 1)
        self.assertEqual(preflight.count(issuer), 1)

        all_workflows = "\n".join(
            path.read_text() for path in WORKFLOWS.glob("*.yaml")
        )
        self.assertEqual(all_workflows.count(identity), 1)
        self.assertEqual(all_workflows.count(issuer), 1)

    def test_production_publisher_is_serialized_without_cancellation(self):
        workflow = (WORKFLOWS / "build.yaml").read_text()

        self.assertIn("group: custom-coreos-publisher", workflow)
        self.assertIn("cancel-in-progress: false", workflow)


if __name__ == "__main__":
    unittest.main()
