# ABOUTME: Keeps Python development reproducible and self-bootstrapping through uv.

from __future__ import annotations

import tomllib
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class DevelopmentToolchainTests(unittest.TestCase):
    def test_uv_is_the_only_python_dependency_boundary(self):
        project = tomllib.loads((REPO / "pyproject.toml").read_text())

        self.assertEqual(project["project"]["requires-python"], ">=3.11")
        self.assertEqual(project["dependency-groups"]["dev"], ["ty==0.0.69"])
        self.assertFalse(project["tool"]["uv"]["package"])
        self.assertEqual(project["tool"]["uv"]["required-version"], "==0.12.3")
        self.assertTrue((REPO / "uv.lock").is_file())
        self.assertFalse((REPO / "requirements-dev.txt").exists())

    def test_make_runs_python_tools_in_the_locked_uv_environment(self):
        makefile = (REPO / "Makefile").read_text()

        self.assertIn("UV_RUN       := $(UV) run --locked", makefile)
        self.assertIn("$(UV_RUN) ty check", makefile)
        self.assertIn("$(UV_RUN) python -m unittest", makefile)
        self.assertIn("$(UV_RUN) python generate-quadlets.py", makefile)
        self.assertNotIn("$(PYTHON)", makefile)


if __name__ == "__main__":
    unittest.main()
