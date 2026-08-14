#!/usr/bin/env python3
# ABOUTME: Probes whether krun honors an OCI user for the pinned database image.
# ABOUTME: Distinguishes guest-root fallback from the declared 1000:1000 identity.

"""Classify the effective identity observed inside the krun database guest."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from quadletgen.parser import load_service  # noqa: E402


CONTAINER_CLI = os.environ.get("CONTAINER_CLI", "podman")
COMMAND_TIMEOUT_SECONDS = 60
DATABASE_SPEC = REPO / "quadlets" / "immich-database.toml"
IDENTITY_PATTERN = re.compile(
    r"\buid=(?P<uid>\d+)(?:\([^)]*\))?\s+"
    r"gid=(?P<gid>\d+)(?:\([^)]*\))?"
)


def probe_command(image: str, container_cli: str = CONTAINER_CLI) -> list[str]:
    return [
        container_cli,
        "run",
        "--rm",
        "--pull=missing",
        "--runtime=krun",
        "--network=none",
        "--user=1000:1000",
        "--userns=keep-id:uid=1000,gid=1000",
        "--entrypoint=/usr/bin/id",
        image,
    ]


def classify_identity(output: str) -> str:
    match = IDENTITY_PATTERN.search(output)
    if match is None:
        compact = ":".join(output.split())
        if compact in {"0:0", "1000:1000"}:
            uid, gid = (int(part) for part in compact.split(":", 1))
        else:
            raise ValueError(f"could not parse krun identity: {output.strip()!r}")
    else:
        uid = int(match.group("uid"))
        gid = int(match.group("gid"))

    if (uid, gid) == (0, 0):
        return "guest-root-fallback"
    if (uid, gid) == (1000, 1000):
        return "honored-1000:1000"
    raise ValueError(f"unexpected krun identity: {uid}:{gid}")


def main() -> int:
    spec = load_service(DATABASE_SPEC)
    image = spec.container.image
    command = probe_command(image)
    result = subprocess.run(
        command,
        capture_output=True,
        check=False,
        text=True,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(
            f"krun identity probe failed with status {result.returncode}: {detail}"
        )

    classification = classify_identity(result.stdout)
    print(f"krun identity: {classification}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
