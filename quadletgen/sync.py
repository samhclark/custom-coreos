"""Synchronize compiled artifacts into the image overlay."""

from __future__ import annotations

from pathlib import Path

from .compiler import Artifact
from .render_service import GENERATED_HEADER_PREFIX, GENERATED_HEADER_SUFFIX


def sync_artifacts(
    repo: Path,
    overlay: Path,
    artifacts: tuple[Artifact, ...],
) -> None:
    expected_paths = {overlay / artifact.path for artifact in artifacts}
    for artifact in artifacts:
        _write(repo, overlay / artifact.path, artifact)
    _remove_stale_generated(repo, overlay, expected_paths)


def _write(repo: Path, path: Path, artifact: Artifact) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    changed = not path.exists() or path.read_text() != artifact.content
    if changed:
        path.write_text(artifact.content)
    if artifact.executable:
        path.chmod(0o755)
    print(f"{'wrote' if changed else 'ok   '} {path.relative_to(repo)}")


def _has_generated_header(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        with path.open(errors="replace") as generated_file:
            for _ in range(2):
                line = generated_file.readline().rstrip("\n")
                if line.startswith(GENERATED_HEADER_PREFIX) and line.endswith(
                    GENERATED_HEADER_SUFFIX
                ):
                    return True
    except OSError:
        return False
    return False


def _remove_stale_generated(
    repo: Path,
    overlay: Path,
    expected_paths: set[Path],
) -> None:
    stale_paths = sorted(
        path
        for path in overlay.rglob("*")
        if path not in expected_paths and _has_generated_header(path)
    )
    for path in stale_paths:
        path.unlink()
        print(f"removed {path.relative_to(repo)}")

        # Per-UID Quadlet directories are generator-created. Other output
        # directories are shared with hand-written overlay files.
        users_dir = overlay / "etc/containers/systemd/users"
        if path.parent.parent == users_dir:
            try:
                path.parent.rmdir()
            except OSError:
                pass
