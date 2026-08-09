"""Synchronize compiled artifacts into the image overlay."""

from __future__ import annotations

import os
import stat
import tempfile
from pathlib import Path

from .compiler import Artifact
from .headers import GENERATED_HEADER_PREFIX, GENERATED_HEADER_SUFFIX
from .model import ConfigError


def check_artifacts(
    repo: Path,
    overlay: Path,
    artifacts: tuple[Artifact, ...],
) -> None:
    """Fail when tracked generated output differs without changing it."""
    _require_real_directory(overlay)
    expected_paths = {overlay / artifact.path for artifact in artifacts}
    problems: list[str] = []
    for artifact in artifacts:
        path = overlay / artifact.path
        try:
            _require_safe_parent(overlay, path)
            existing = _read_regular_file(path)
        except ConfigError as error:
            problems.append(str(error))
            continue
        if existing is None:
            problems.append(
                f"missing: {path.relative_to(repo)}"
            )
            continue
        desired_mode = 0o755 if artifact.executable else 0o644
        if existing[0] != artifact.content:
            problems.append(
                f"stale content: {path.relative_to(repo)}"
            )
        if existing[1] != desired_mode:
            problems.append(
                f"stale mode: {path.relative_to(repo)} "
                f"(expected {desired_mode:04o}, found {existing[1]:04o})"
            )

    problems.extend(
        f"unexpected: {path.relative_to(repo)}"
        for path in _stale_generated_paths(overlay, expected_paths)
    )
    if problems:
        raise ConfigError(
            "generated artifact drift:\n- " + "\n- ".join(problems)
        )
    print("ok   generated artifact parity")


def sync_artifacts(
    repo: Path,
    overlay: Path,
    artifacts: tuple[Artifact, ...],
) -> None:
    _ensure_real_directory(overlay)
    expected_paths = {overlay / artifact.path for artifact in artifacts}
    for artifact in artifacts:
        _write(repo, overlay, overlay / artifact.path, artifact)
    _remove_stale_generated(repo, overlay, expected_paths)


def _write(repo: Path, overlay: Path, path: Path, artifact: Artifact) -> None:
    _ensure_safe_parent(overlay, path)
    desired_mode = 0o755 if artifact.executable else 0o644
    existing = _read_regular_file(path)
    changed = (
        existing is None
        or existing[0] != artifact.content
        or existing[1] != desired_mode
    )
    if existing is None or existing[0] != artifact.content:
        _atomic_replace(path, artifact.content, desired_mode)
    elif existing[1] != desired_mode:
        _set_mode_without_following(path, desired_mode)
    print(f"{'wrote' if changed else 'ok   '} {path.relative_to(repo)}")


def _ensure_real_directory(path: Path) -> None:
    try:
        path.mkdir()
    except FileExistsError:
        pass
    _require_real_directory(path)


def _require_real_directory(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        raise ConfigError(f"output parent is missing: {path}") from None
    if stat.S_ISLNK(metadata.st_mode):
        raise ConfigError(f"refusing to traverse symlinked output directory: {path}")
    if not stat.S_ISDIR(metadata.st_mode):
        raise ConfigError(f"output parent is not a directory: {path}")


def _ensure_safe_parent(overlay: Path, path: Path) -> None:
    relative = _relative_output_path(overlay, path)

    current = overlay
    _ensure_real_directory(current)
    for part in relative.parts[:-1]:
        current /= part
        _ensure_real_directory(current)


def _require_safe_parent(overlay: Path, path: Path) -> None:
    relative = _relative_output_path(overlay, path)
    current = overlay
    _require_real_directory(current)
    for part in relative.parts[:-1]:
        current /= part
        _require_real_directory(current)


def _relative_output_path(overlay: Path, path: Path) -> Path:
    try:
        relative = path.relative_to(overlay)
    except ValueError:
        raise ConfigError(f"artifact path escapes overlay: {path}") from None
    if not relative.parts or any(part in {".", ".."} for part in relative.parts):
        raise ConfigError(f"artifact path escapes overlay: {path}")
    return relative


def _read_regular_file(path: Path) -> tuple[str, int] | None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(metadata.st_mode):
        raise ConfigError(f"refusing to replace symlinked artifact: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        raise ConfigError(f"artifact output is not a regular file: {path}")

    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ConfigError(f"could not safely open artifact {path}: {error}") from error
    with os.fdopen(descriptor, encoding="utf-8") as artifact_file:
        content = artifact_file.read()
        mode = stat.S_IMODE(os.fstat(artifact_file.fileno()).st_mode)
    return content, mode


def _atomic_replace(path: Path, content: str, mode: int) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary_file:
            temporary_file.write(content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def _set_mode_without_following(path: Path, mode: int) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ConfigError(f"could not safely open artifact {path}: {error}") from error
    try:
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


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
    for path in _stale_generated_paths(overlay, expected_paths):
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


def _stale_generated_paths(
    overlay: Path,
    expected_paths: set[Path],
) -> list[Path]:
    return sorted(
        path
        for path in overlay.rglob("*")
        if path not in expected_paths and _has_generated_header(path)
    )
