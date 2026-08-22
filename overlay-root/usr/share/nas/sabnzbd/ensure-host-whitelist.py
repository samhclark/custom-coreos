#!/usr/bin/env python3
"""Safely maintain SABnzbd's startup and shared-download settings."""

from __future__ import annotations

import io
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

from configobj import ConfigObj, ConfigObjError


ENVIRONMENT_NAME = "NAS_SABNZBD_ALLOWED_HOSTNAMES"
PERMISSIONS_ENVIRONMENT_NAME = "NAS_SABNZBD_COMPLETED_PERMISSIONS"
SECTION_NAME = "misc"
KEY_NAME = "host_whitelist"
PERMISSIONS_KEY_NAME = "permissions"
DEFAULT_COMPLETED_PERMISSIONS = "2770"


class ConfigError(RuntimeError):
    """The configuration is not safe to modify automatically."""


def _entries(value: object) -> list[str]:
    if isinstance(value, str):
        values = [value]
    elif isinstance(value, list):
        values = value
    else:
        raise ConfigError("host_whitelist is not a string or list")

    entries: list[str] = []
    for entry in values:
        if not isinstance(entry, str):
            raise ConfigError("host_whitelist contains a non-string value")
        entries.extend(item.strip() for item in entry.split(",") if item.strip())
    return entries


def _allowed_hostnames() -> list[str]:
    raw = os.environ.get(ENVIRONMENT_NAME, "")
    names = _entries(raw)
    if not names or any(
        not re.fullmatch(r"[A-Za-z0-9.-]+", name) for name in names
    ):
        raise ConfigError(f"invalid {ENVIRONMENT_NAME} value")
    if len({name.casefold() for name in names}) != len(names):
        raise ConfigError(f"duplicate names in {ENVIRONMENT_NAME}")
    return names


def _completed_permissions() -> str:
    permissions = os.environ.get(
        PERMISSIONS_ENVIRONMENT_NAME, DEFAULT_COMPLETED_PERMISSIONS
    )
    if not re.fullmatch(r"[0-7]{4}", permissions):
        raise ConfigError(
            f"invalid {PERMISSIONS_ENVIRONMENT_NAME} value"
        )
    if permissions[-3:] != "770":
        raise ConfigError(
            f"{PERMISSIONS_ENVIRONMENT_NAME} must grant owner/group rwx"
        )
    return permissions


def _read_config(path: Path) -> tuple[bytes, bool, int | None]:
    try:
        directory_stat = os.stat(path.parent, follow_symlinks=False)
    except OSError as error:
        raise ConfigError(f"cannot inspect config directory: {error}") from error
    if not stat.S_ISDIR(directory_stat.st_mode):
        raise ConfigError("config parent is not a directory")

    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
    except FileNotFoundError:
        return b"", False, None
    except OSError as error:
        raise ConfigError(f"cannot open config safely: {error}") from error

    try:
        descriptor_stat = os.fstat(descriptor)
        if not stat.S_ISREG(descriptor_stat.st_mode):
            raise ConfigError("config path is not a regular file")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks), True, stat.S_IMODE(descriptor_stat.st_mode)
    except OSError as error:
        raise ConfigError(f"cannot read config safely: {error}") from error
    finally:
        os.close(descriptor)


def _parse(content: bytes, path: Path) -> ConfigObj:
    try:
        text = content.decode("utf-8")
        return ConfigObj(
            text.splitlines(keepends=True),
            encoding="UTF-8",
            interpolation=False,
            list_values=True,
            raise_errors=True,
            write_empty_values=True,
        )
    except (ConfigObjError, SyntaxError, UnicodeError, ValueError, TypeError) as error:
        raise ConfigError(f"cannot parse {path}: {error}") from error


def _serialize(config: ConfigObj) -> bytes:
    output = io.BytesIO()
    try:
        config.write(outfile=output)
    except (ConfigObjError, OSError, UnicodeError, ValueError, TypeError) as error:
        raise ConfigError(f"cannot serialize configuration: {error}") from error
    return output.getvalue()


def _updated_config(
    content: bytes,
    path: Path,
    required: list[str],
    completed_permissions: str,
) -> bytes:
    config = _parse(content, path)
    if SECTION_NAME not in config:
        config[SECTION_NAME] = {}
    section = config[SECTION_NAME]
    if not isinstance(section, dict):
        raise ConfigError(f"[{SECTION_NAME}] is not a section")

    existing = _entries(section.get(KEY_NAME, []))
    combined: list[str] = []
    seen: set[str] = set()
    for name in existing + required:
        folded = name.casefold()
        if folded not in seen:
            combined.append(name)
            seen.add(folded)
    section[KEY_NAME] = combined
    # SABnzbd applies this mode recursively after unpacking. In particular,
    # this repairs restrictive mode bits preserved from Unix-aware archives.
    section[PERMISSIONS_KEY_NAME] = completed_permissions
    serialized = _serialize(config)
    # Validate the exact bytes that will be atomically installed. This keeps a
    # future ConfigObj/API change from replacing a valid file with output that
    # SABnzbd itself cannot parse.
    _parse(serialized, path)
    return serialized


def _safe_mode(mode: int | None) -> int:
    if mode is None:
        return 0o600
    # Preserve existing non-world-writable credentials while repairing an
    # accidentally group/other-writable file to the new-file mode.
    return mode if not mode & 0o022 else 0o600


def _write_atomically(path: Path, content: bytes, mode: int) -> None:
    descriptor = -1
    temporary_name = ""
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
        )
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())

        # Do not replace a path that appeared as a symlink or other object
        # after the initial read. An absent path is allowed to remain absent.
        try:
            current_stat = os.lstat(path)
        except FileNotFoundError:
            current_stat = None
        if current_stat is not None and not stat.S_ISREG(current_stat.st_mode):
            raise ConfigError("config path changed to a non-regular file")
        os.replace(temporary_name, path)
        temporary_name = ""

        directory_descriptor = os.open(
            path.parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError as error:
        raise ConfigError(f"cannot atomically replace config: {error}") from error
    finally:
        if descriptor != -1:
            os.close(descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def ensure_host_whitelist(path: Path) -> bool:
    if os.geteuid() != 1000 or os.getegid() != 1000:
        raise ConfigError("helper must run as UID:GID 1000:1000")
    required = _allowed_hostnames()
    completed_permissions = _completed_permissions()

    main_content, main_exists, main_mode = _read_config(path)
    target = path
    content = main_content
    mode = main_mode
    if not main_exists:
        backup = path.with_name(f"{path.name}.bak")
        backup_content, backup_exists, backup_mode = _read_config(backup)
        if backup_exists:
            # Let SABnzbd restore this backup to the main path on startup.
            target = backup
            content = backup_content
            mode = backup_mode

    updated = _updated_config(
        content, target, required, completed_permissions
    )
    target_mode = _safe_mode(mode)
    try:
        current_stat = os.lstat(target)
    except FileNotFoundError:
        current_stat = None
    if current_stat is not None:
        if not stat.S_ISREG(current_stat.st_mode):
            raise ConfigError("config path changed to a non-regular file")
        if (
            updated == content
            and stat.S_IMODE(current_stat.st_mode) == target_mode
        ):
            return False
    _write_atomically(target, updated, target_mode)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} CONFIG_PATH", file=sys.stderr)
        return 2
    try:
        ensure_host_whitelist(Path(sys.argv[1]))
    except (ConfigError, OSError) as error:
        print(f"sabnzbd config: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
