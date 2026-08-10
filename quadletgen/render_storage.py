# ABOUTME: Derives container mounts and startup checks from typed storage contracts.

"""Render the rootless-service side of declarative storage."""

from __future__ import annotations

import posixpath

from .model import Service
from .storage_model import (
    DirectoryStorage,
    ExistingZfsStorage,
    ManagedZfsStorage,
    StorageAccess,
    StorageSpec,
)


def storage_volume_lines(service: Service) -> tuple[str, ...]:
    """Return Quadlet comments and mounts derived from service storage."""

    lines: list[str] = []
    for storage in service.storage:
        for export in storage.exports:
            source = _export_path(storage, export.subpath)
            options = ":ro" if export.access is StorageAccess.READ_ONLY else ""
            lines += [
                "",
                f"# Declarative {storage.name} storage",
                f"Volume={source}:{export.container_path}{options}",
            ]
    return tuple(lines)


def storage_readiness_line(service: Service) -> str | None:
    """Return the current-boot marker and host-path contract for storage."""

    if not service.storage:
        return None
    requirements: list[str] = []
    seen_paths: set[str] = set()
    for storage in service.storage:
        for export in storage.exports:
            path = _export_path(storage, export.subpath)
            if path in seen_paths:
                continue
            seen_paths.add(path)
            requirements += ["--path", path]
            if isinstance(storage, (ManagedZfsStorage, ExistingZfsStorage)):
                requirements += ["--source", storage.dataset]
            if isinstance(storage, (DirectoryStorage, ManagedZfsStorage)):
                requirements += [
                    "--owner",
                    f"{service.host.uid}:{service.host.uid}",
                ]
            access = (
                "rx"
                if export.access is StorageAccess.READ_ONLY
                else "rwx"
            )
            requirements += ["--access", access]

    marker = f"/run/nas-storage/{service.info.name}/ready"
    return " ".join(
        [
            "ExecStartPre=/usr/local/bin/nas-wait-for-readiness.sh",
            "marker",
            marker,
            "90",
            "1",
            *requirements,
        ]
    )


def _export_path(storage: StorageSpec, subpath: str) -> str:
    if subpath == ".":
        return storage.host_path
    return posixpath.join(storage.host_path, subpath)
