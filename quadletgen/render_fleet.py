"""Render fleet-level host identity artifacts."""

from __future__ import annotations

from .headers import generated_header
from .model import Fleet


def fleet_groups_sysusers_conf(fleet: Fleet) -> str:
    lines = [
        generated_header("_fleet.toml"),
        "# Fleet groups are shared by explicitly opted-in rootless services.",
    ]
    for group in fleet.groups:
        lines.append(f"g {group.name} {group.gid}")
    for service in fleet.services:
        for group_name in service.identity.supplemental_groups:
            lines.append(f"m {service.host.username} {group_name}")
    return "\n".join(lines) + "\n"
