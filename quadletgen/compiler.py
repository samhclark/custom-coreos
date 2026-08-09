"""Compile a validated fleet into a complete set of filesystem artifacts."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .model import ConfigError, Fleet, SUBID_COUNT
from .render_network import (
    network_policy_script,
    network_policy_unit,
    networkd_dependencies,
    networkd_netdev,
    networkd_network,
    nft_filter,
    nft_nat,
    nftables_policy_dropin,
)
from .render_manifest import (
    account_units_manifest,
    active_taps_manifest,
    assets_manifest,
    secrets_manifest,
)
from .render_service import (
    container_unit,
    ensure_account_script,
    ensure_account_unit,
    sysusers_conf,
    tmpfiles_conf,
)


ARTIFACT_PATH_RE = re.compile(
    r"^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$"
)


@dataclass(frozen=True)
class Artifact:
    path: Path
    content: str
    executable: bool = False

    def __post_init__(self) -> None:
        if (
            self.path.is_absolute()
            or not ARTIFACT_PATH_RE.fullmatch(self.path.as_posix())
            or ".." in self.path.parts
        ):
            raise ConfigError(
                f"artifact path must be normalized and relative: {self.path}"
            )
        if type(self.executable) is not bool:
            raise ConfigError("artifact executable flag must be a boolean")


def compile_fleet(fleet: Fleet) -> tuple[Artifact, ...]:
    artifacts: list[Artifact] = []
    for service in fleet.services:
        host = service.host
        if service.container.enabled:
            artifacts.append(
                Artifact(
                    Path(
                        f"etc/containers/systemd/users/{host.uid}/"
                        f"{service.info.name}.container"
                    ),
                    container_unit(service, fleet),
                )
            )
        artifacts += [
            Artifact(
                Path(f"usr/lib/sysusers.d/nas-{host.slug}.conf"),
                sysusers_conf(service),
            ),
            Artifact(
                Path(f"usr/lib/tmpfiles.d/nas-{host.slug}-rootless.conf"),
                tmpfiles_conf(service),
            ),
            Artifact(
                Path(f"usr/local/bin/ensure-nas-{host.slug}-account.sh"),
                ensure_account_script(service),
                executable=True,
            ),
            Artifact(
                Path(
                    f"etc/systemd/system/ensure-nas-{host.slug}-account.service"
                ),
                ensure_account_unit(service),
            ),
        ]
        if service.active_tap:
            artifacts += [
                Artifact(
                    Path(f"usr/lib/systemd/network/80-{service.tap_name}.netdev"),
                    networkd_netdev(service),
                ),
                Artifact(
                    Path(f"usr/lib/systemd/network/80-{service.tap_name}.network"),
                    networkd_network(service),
                ),
            ]

    subids = _subid_file(fleet)
    artifacts += [
        Artifact(Path("etc/subuid"), subids),
        Artifact(Path("etc/subgid"), subids),
        Artifact(
            Path("usr/local/bin/nas-krun-network-policy.sh"),
            network_policy_script(fleet),
            executable=True,
        ),
        Artifact(
            Path("etc/systemd/system/nas-krun-network-policy.service"),
            network_policy_unit(fleet),
        ),
        Artifact(
            Path("etc/systemd/system/nftables.service.d/10-nas-krun-policy.conf"),
            nftables_policy_dropin(),
        ),
        Artifact(
            Path(
                "etc/systemd/system/systemd-networkd.service.d/"
                "10-nas-krun-accounts.conf"
            ),
            networkd_dependencies(fleet),
        ),
        Artifact(Path("etc/nftables/nas-krun-filter.nft"), nft_filter(fleet)),
        Artifact(Path("etc/nftables/nas-krun-nat.nft"), nft_nat(fleet)),
        Artifact(
            Path("usr/share/custom-coreos/fleet/account-units.list"),
            account_units_manifest(fleet),
        ),
        Artifact(
            Path("usr/share/custom-coreos/fleet/active-taps.tsv"),
            active_taps_manifest(fleet),
        ),
        Artifact(
            Path("usr/share/custom-coreos/fleet/secrets.tsv"),
            secrets_manifest(fleet),
        ),
        Artifact(
            Path("usr/share/custom-coreos/fleet/assets.list"),
            assets_manifest(fleet),
        ),
    ]
    paths = [artifact.path for artifact in artifacts]
    if len(set(paths)) != len(paths):
        duplicates = sorted(path for path in set(paths) if paths.count(path) > 1)
        raise ConfigError(
            "compiler produced duplicate artifact paths: "
            + ", ".join(map(str, duplicates))
        )
    return tuple(artifacts)


def _subid_file(fleet: Fleet) -> str:
    # No header comment: shadow-utils does not document comment support in
    # subuid/subgid, so these files stay bare.
    return "".join(
        f"{service.host.username}:{service.host.subid_start}:{SUBID_COUNT}\n"
        for service in fleet.services
    )
