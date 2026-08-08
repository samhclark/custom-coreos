"""Command-line entry point for the rootless service fleet compiler."""

from __future__ import annotations

import sys
from pathlib import Path

from .compiler import compile_fleet
from .model import ConfigError, Fleet
from .parser import load_service
from .secrets import verify_sops
from .sync import sync_artifacts


def run(repo: Path) -> int:
    quadlet_dir = repo / "quadlets"
    overlay = repo / "overlay-root"
    toml_paths = sorted(quadlet_dir.glob("*.toml"))
    if not toml_paths:
        raise ConfigError(f"no TOML configs found in {quadlet_dir}")
    fleet = Fleet.build([load_service(path) for path in toml_paths])
    verify_sops(
        fleet,
        overlay / "usr/share/custom-coreos/secrets/secrets.sops.yaml",
    )
    for service in fleet.services:
        if not service.container.enabled:
            print(f"skip  quadlets/{service.source.name} container (disabled)")
    sync_artifacts(repo, overlay, compile_fleet(fleet))
    return 0


def main(repo: Path) -> int:
    try:
        return run(repo)
    except ConfigError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
