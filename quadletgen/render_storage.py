# ABOUTME: Derives container mounts and startup checks from typed storage contracts.

"""Render the rootless-service side of declarative storage."""

from __future__ import annotations

import posixpath

from .headers import generated_header
from .model import Protocol, Service
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
            "300",
            "2",
            *requirements,
        ]
    )


def storage_manifest(service: Service) -> str:
    """Render the closed data language consumed by the storage runtime."""

    if not service.storage:
        raise ValueError(f"{service.info.name} has no storage to render")
    tcp_ports = ",".join(
        str(endpoint.host_port)
        for endpoint in service.container.endpoints
        if endpoint.protocol is Protocol.TCP
        and endpoint.host_port is not None
    ) or "-"
    lines = [
        "nas-storage-manifest-v1",
        generated_header(service.source.name),
        "|".join(
            (
                "service",
                service.info.name,
                service.host.username,
                str(service.host.uid),
                str(service.host.uid),
                tcp_ports,
            )
        ),
    ]
    emitted_datasets: set[str] = set()
    declared_datasets = {
        item.dataset
        for item in service.storage
        if isinstance(item, ManagedZfsStorage)
    }
    for storage in service.storage:
        if isinstance(storage, DirectoryStorage):
            lines.append(
                f"directory|{storage.host_path}|{storage.mode}"
            )
            for subdirectory in sorted(
                storage.subdirectories,
                key=lambda value: (value.count("/"), value),
            ):
                lines.append(
                    "directory|"
                    f"{posixpath.join(storage.host_path, subdirectory)}|"
                    f"{storage.mode}"
                )
        elif isinstance(storage, ManagedZfsStorage):
            parts = storage.dataset.split("/")
            for depth in range(2, len(parts)):
                parent = "/".join(parts[:depth])
                if parent not in emitted_datasets and parent not in declared_datasets:
                    lines.append(f"managed-zfs|{parent}|none|-|-")
                    emitted_datasets.add(parent)
            properties = ",".join(
                (
                    f"recordsize={storage.record_size.value}",
                    f"compression={storage.compression.value}",
                    f"atime={'on' if storage.atime else 'off'}",
                    f"primarycache={storage.primary_cache.value}",
                )
            )
            lines.append(
                f"managed-zfs|{storage.dataset}|{storage.host_path}|"
                f"{storage.mode}|{properties}"
            )
            emitted_datasets.add(storage.dataset)
        else:
            lines.append(
                f"existing-zfs|{storage.dataset}|{storage.host_path}"
            )
    return "\n".join(lines) + "\n"


def storage_unit(service: Service) -> str:
    """Render the root one-shot that prepares a service's storage."""

    if not service.storage:
        raise ValueError(f"{service.info.name} has no storage to render")
    account_unit = f"ensure-nas-{service.host.slug}-account.service"
    has_zfs = any(
        isinstance(item, (ManagedZfsStorage, ExistingZfsStorage))
        for item in service.storage
    )
    requires = [account_unit]
    after = ["local-fs.target", account_unit]
    conditions: list[str] = []
    if has_zfs:
        requires.insert(0, "zfs.target")
        after.insert(0, "zfs.target")
        conditions.append("ConditionPathIsDirectory=/sys/module/zfs")

    lines = [
        generated_header(service.source.name),
        "[Unit]",
        f"Description=Prepare declarative storage for {service.info.name}",
        f"Requires={' '.join(requires)}",
        f"After={' '.join(after)}",
        *conditions,
        "",
        "[Service]",
        "Type=oneshot",
        "User=root",
        "ExecStart=/usr/local/bin/nas-prepare-storage.sh "
        f"/usr/share/custom-coreos/storage/{service.info.name}.storage-manifest",
        "TimeoutStartSec=infinity",
        "Restart=on-failure",
        "RestartSec=30",
        "StandardOutput=journal",
        "StandardError=journal",
        "RemainAfterExit=yes",
        "",
        "[Install]",
        "WantedBy=multi-user.target",
    ]
    return "\n".join(lines) + "\n"


def _export_path(storage: StorageSpec, subpath: str) -> str:
    if subpath == ".":
        return storage.host_path
    return posixpath.join(storage.host_path, subpath)
