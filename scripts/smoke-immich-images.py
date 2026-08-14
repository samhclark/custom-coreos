#!/usr/bin/env python3
# ABOUTME: Smoke-tests pinned Immich companion images under their declared users.
# ABOUTME: Validates image entrypoints without recreating the production VM topology.

"""Opt-in runtime smoke tests for Immich's PostgreSQL and Valkey images."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from quadletgen.model import Service  # noqa: E402
from quadletgen.parser import load_service  # noqa: E402


CONTAINER_CLI = os.environ.get("CONTAINER_CLI", "podman")
TIMEOUT_SECONDS = 180
COMMAND_TIMEOUT_SECONDS = 300


def run(
    arguments: list[str],
    *,
    capture: bool = False,
    check: bool = True,
    timeout: int = COMMAND_TIMEOUT_SECONDS,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [CONTAINER_CLI, *arguments],
        capture_output=capture,
        check=check,
        text=True,
        timeout=timeout,
    )


def service(name: str) -> Service:
    return load_service(REPO / "quadlets" / f"{name}.toml")


def container_arguments(spec: Service, name: str) -> list[str]:
    container = spec.container
    uid = container.container_user
    if uid is None or uid <= 0:
        raise RuntimeError(f"{spec.info.name} smoke requires a positive container-user")

    arguments = [
        "run",
        "--detach",
        "--name",
        name,
        "--pull=missing",
        "--network=none",
        f"--user={uid}:{uid}",
        f"--userns=keep-id:uid={uid},gid={uid}",
    ]
    if container.no_new_privileges:
        arguments.append("--security-opt=no-new-privileges")
    for capability in container.drop_capabilities:
        arguments.append(f"--cap-drop={capability}")
    if container.shm_size_mib is not None:
        arguments.append(f"--shm-size={container.shm_size_mib}m")
    if container.entrypoint is not None:
        arguments.append(f"--entrypoint={container.entrypoint}")
    return arguments


def wait_for_exec(name: str, command: list[str], description: str) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    last_result: subprocess.CompletedProcess[str] | None = None
    while time.monotonic() < deadline:
        last_result = run(
            ["exec", name, *command],
            capture=True,
            check=False,
            timeout=10,
        )
        if last_result.returncode == 0:
            return
        running = run(
            ["inspect", "--format={{.State.Running}}", name],
            capture=True,
            check=False,
            timeout=10,
        )
        if running.returncode != 0 or running.stdout.strip() != "true":
            break
        time.sleep(1)

    logs = run(["logs", name], capture=True, check=False, timeout=30)
    detail = ""
    if last_result is not None:
        detail = (last_result.stderr or last_result.stdout).strip()
    raise RuntimeError(
        f"{description} did not become ready: {detail}\n{logs.stdout}{logs.stderr}"
    )


def smoke_postgresql(spec: Service, temporary: Path) -> None:
    name = f"immich-postgres-smoke-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    data = temporary / "postgres"
    data.mkdir(mode=0o700)
    environment = dict(spec.container.environment)
    database = environment["POSTGRES_DB"]
    database_user = environment["POSTGRES_USER"]
    password_target = environment["POSTGRES_PASSWORD_FILE"]
    password_file = temporary / "immich-db-password"
    password_file.write_text("immich-smoke-only\n")
    password_file.chmod(0o400)
    arguments = container_arguments(spec, name)
    arguments += [
        "--volume",
        f"{data}:/var/lib/postgresql/data:Z",
        "--volume",
        f"{password_file}:{password_target}:ro,Z",
    ]
    for key in (
        "POSTGRES_PASSWORD_FILE",
        "POSTGRES_USER",
        "POSTGRES_DB",
        "POSTGRES_INITDB_ARGS",
        "DB_STORAGE_TYPE",
    ):
        arguments += ["--env", f"{key}={environment[key]}"]
    arguments.append(spec.container.image)

    print(f"smoke PostgreSQL: {spec.container.image}", flush=True)
    try:
        run(arguments, capture=True)
        wait_for_exec(
            name,
            ["pg_isready", "--username", database_user, "--dbname", database],
            "PostgreSQL",
        )
        checksums = run(
            [
                "exec",
                "--env",
                "PGPASSWORD=immich-smoke-only",
                name,
                "psql",
                "--username",
                database_user,
                "--dbname",
                database,
                "--tuples-only",
                "--no-align",
                "--command=SHOW data_checksums",
            ],
            capture=True,
        )
        if checksums.stdout.strip() != "on":
            raise RuntimeError("PostgreSQL smoke initialized without data checksums")
    finally:
        run(["rm", "--force", "--ignore", name], capture=True, timeout=30)


def smoke_valkey(spec: Service, temporary: Path) -> None:
    name = f"immich-valkey-smoke-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    data = temporary / "valkey"
    data.mkdir(mode=0o750)
    arguments = container_arguments(spec, name)
    arguments += ["--volume", f"{data}:/data:Z", spec.container.image]
    if spec.container.exec is not None:
        arguments.extend(spec.container.exec.split())

    print(f"smoke Valkey: {spec.container.image}", flush=True)
    try:
        run(arguments, capture=True)
        wait_for_exec(name, ["valkey-cli", "ping"], "Valkey")
    finally:
        run(["rm", "--force", "--ignore", name], capture=True, timeout=30)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="immich-image-smoke-", dir="/var/tmp") as root:
        temporary = Path(root)
        smoke_postgresql(service("immich-database"), temporary)
        smoke_valkey(service("immich-valkey"), temporary)
    print("Immich companion image smoke tests passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
