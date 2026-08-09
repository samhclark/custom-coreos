# ABOUTME: Tests synchronization of compiled artifacts into the image overlay.

from __future__ import annotations

import contextlib
import io
import stat
import tempfile
import unittest
from pathlib import Path

from quadletgen.compiler import Artifact
from quadletgen.model import ConfigError
from quadletgen.sync import check_artifacts, sync_artifacts
from tests.quadlet_test_support import GENERATED_PREFIX, REPO


class ArtifactSynchronizationTests(unittest.TestCase):
    def test_check_accepts_current_output_without_modifying_it(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            artifact = Artifact(
                Path("etc/systemd/system/current.service"),
                GENERATED_PREFIX + "current.toml — DO NOT EDIT\n",
            )
            with contextlib.redirect_stdout(io.StringIO()):
                sync_artifacts(repo, overlay, (artifact,))
            output = overlay / artifact.path
            before = (output.read_bytes(), output.stat().st_mtime_ns)

            with contextlib.redirect_stdout(io.StringIO()):
                check_artifacts(repo, overlay, (artifact,))

            self.assertEqual(
                before,
                (output.read_bytes(), output.stat().st_mtime_ns),
            )

    def test_check_reports_drift_without_repairing_it(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            output = overlay / "etc/systemd/system/current.service"
            output.parent.mkdir(parents=True)
            output.write_text("stale\n")
            artifact = Artifact(output.relative_to(overlay), "current\n")

            with self.assertRaisesRegex(ConfigError, "stale content"):
                check_artifacts(repo, overlay, (artifact,))

            self.assertEqual(output.read_text(), "stale\n")

    def test_check_reports_stale_output_without_removing_it(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            stale = overlay / "etc/systemd/system/old.service"
            stale.parent.mkdir(parents=True)
            stale.write_text(GENERATED_PREFIX + "old.toml — DO NOT EDIT\n")

            with self.assertRaisesRegex(ConfigError, "unexpected"):
                check_artifacts(repo, overlay, ())

            self.assertTrue(stale.exists())

    def test_sync_removes_only_stale_generated_files(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            stale = overlay / "etc/containers/systemd/users/59999/old.container"
            handwritten = overlay / "etc/systemd/system/handwritten.service"
            stale.parent.mkdir(parents=True)
            handwritten.parent.mkdir(parents=True)
            stale.write_text(
                GENERATED_PREFIX + "old.toml — DO NOT EDIT\n"
            )
            handwritten.write_text("[Unit]\nDescription=Handwritten\n")
            artifact = Artifact(
                Path("etc/systemd/system/current.service"),
                GENERATED_PREFIX + "current.toml — DO NOT EDIT\n",
            )

            with contextlib.redirect_stdout(io.StringIO()):
                sync_artifacts(repo, overlay, (artifact,))

            self.assertFalse(stale.exists())
            self.assertFalse(stale.parent.exists())
            self.assertTrue(handwritten.exists())
            self.assertEqual(
                (overlay / artifact.path).read_text(), artifact.content
            )

    def test_sync_does_not_follow_generated_symlink(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            target = repo / "target"
            link = overlay / "usr/local/bin/link"
            link.parent.mkdir(parents=True)
            target.write_text(GENERATED_PREFIX + "old.toml — DO NOT EDIT\n")
            link.symlink_to(target)

            with contextlib.redirect_stdout(io.StringIO()):
                sync_artifacts(repo, overlay, ())

            self.assertTrue(link.is_symlink())
            self.assertTrue(target.exists())

    def test_sync_rejects_symlink_at_expected_output(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            target = repo / "outside"
            link = overlay / "etc/systemd/system/current.service"
            link.parent.mkdir(parents=True)
            target.write_text("untouched\n")
            link.symlink_to(target)
            artifact = Artifact(
                Path("etc/systemd/system/current.service"),
                "replacement\n",
            )

            with self.assertRaisesRegex(ConfigError, "symlinked artifact"):
                with contextlib.redirect_stdout(io.StringIO()):
                    sync_artifacts(repo, overlay, (artifact,))

            self.assertTrue(link.is_symlink())
            self.assertEqual(target.read_text(), "untouched\n")

    def test_sync_rejects_symlinked_output_parent(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            outside = repo / "outside"
            overlay.mkdir()
            outside.mkdir()
            (overlay / "etc").symlink_to(outside, target_is_directory=True)
            artifact = Artifact(
                Path("etc/systemd/system/current.service"),
                "replacement\n",
            )

            with self.assertRaisesRegex(ConfigError, "symlinked output directory"):
                with contextlib.redirect_stdout(io.StringIO()):
                    sync_artifacts(repo, overlay, (artifact,))

            self.assertFalse((outside / "systemd/system/current.service").exists())

    def test_sync_normalizes_executable_mode_in_both_directions(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            repo = Path(directory_name)
            overlay = repo / "overlay-root"
            artifact_path = Path("usr/local/bin/generated")
            output = overlay / artifact_path
            output.parent.mkdir(parents=True)
            output.write_text("content\n")
            output.chmod(0o755)

            with contextlib.redirect_stdout(io.StringIO()):
                sync_artifacts(
                    repo,
                    overlay,
                    (Artifact(artifact_path, "content\n"),),
                )
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o644)

            with contextlib.redirect_stdout(io.StringIO()):
                sync_artifacts(
                    repo,
                    overlay,
                    (Artifact(artifact_path, "content\n", executable=True),),
                )
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o755)


if __name__ == "__main__":
    unittest.main()
