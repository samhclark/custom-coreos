"""Render machine-readable fleet metadata for non-Python consumers."""

from __future__ import annotations

from .headers import generated_header
from .model import ConfigError, Fleet


def account_units_manifest(fleet: Fleet) -> str:
    lines = [
        generated_header("fleet account units"),
        "# systemd unit",
    ]
    lines.extend(
        sorted(
            f"ensure-nas-{service.host.slug}-account.service"
            for service in fleet.services
        )
    )
    return "\n".join(lines) + "\n"


def active_taps_manifest(fleet: Fleet) -> str:
    lines = [
        generated_header("active TAP services"),
        "# tap\tuser-unit\taccount-unit",
    ]
    for service in fleet.active_taps:
        lines.append(
            _row(
                service.tap_name,
                f"user@{service.host.uid}.service",
                f"ensure-nas-{service.host.slug}-account.service",
            )
        )
    return "\n".join(lines) + "\n"


def secrets_manifest(fleet: Fleet) -> str:
    lines = [
        generated_header("fleet secret consumers"),
        "# service\tusername\tsecret",
    ]
    for service in sorted(fleet.services, key=lambda item: item.source.name):
        for secret in service.container.secrets:
            lines.append(
                _row(
                    service.info.name,
                    service.host.username,
                    secret.name,
                )
            )
    return "\n".join(lines) + "\n"


def assets_manifest(fleet: Fleet) -> str:
    lines = [
        generated_header("fleet image assets"),
        "# image asset path",
    ]
    lines.extend(
        sorted(
            {
                service.assets.path
                for service in fleet.services
                if service.assets is not None
            }
        )
    )
    return "\n".join(lines) + "\n"


def _row(*fields: str) -> str:
    for field in fields:
        if "\t" in field or "\n" in field:
            raise ConfigError(
                "fleet manifest fields cannot contain tabs or newlines"
            )
    return "\t".join(fields)
