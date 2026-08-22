# ABOUTME: Locks the image build context to its three production inputs.

from __future__ import annotations

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class ContainerContextTests(unittest.TestCase):
    def test_build_context_is_an_explicit_allowlist(self):
        rules = (REPO / ".dockerignore").read_text().splitlines()

        self.assertEqual(
            [line for line in rules if line and not line.startswith("#")],
            [
                "*",
                "!Containerfile",
                "!overlay-root/",
                "!overlay-root/**",
                "!patches/",
                "!patches/**",
            ],
        )

    def test_non_image_material_is_not_reincluded(self):
        rules = (REPO / ".dockerignore").read_text()

        for forbidden in (
            ".git",
            ".github",
            "docs",
            "quadlets",
            "scripts",
            "tests",
            "butane.yaml",
            "ignition.json",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(f"!{forbidden}", rules)

    def test_containerfile_replaces_coreos_usr_local_before_overlay_copy(self):
        containerfile = (REPO / "Containerfile").read_text()

        remove_symlink = containerfile.index("RUN rm /usr/local")
        copy_overlay = containerfile.index("COPY overlay-root/ /")
        self.assertLess(remove_symlink, copy_overlay)


if __name__ == "__main__":
    unittest.main()
