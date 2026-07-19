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


if __name__ == "__main__":
    unittest.main()
