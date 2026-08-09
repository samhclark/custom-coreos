# ABOUTME: Tests synchronization of compiled artifacts into the image overlay.

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from quadletgen.compiler import Artifact
from quadletgen.sync import sync_artifacts
from tests.quadlet_test_support import GENERATED_PREFIX, REPO


class ArtifactSynchronizationTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
