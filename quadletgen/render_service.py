"""Render per-service Quadlet and host-account artifacts."""

from __future__ import annotations

import textwrap

from .headers import generated_header
from .model import (
    Fleet,
    HttpReadiness,
    KrunPasst,
    KrunTap,
    MarkerReadiness,
    PathAccess,
    RequiredOwner,
    Protocol,
    SUBID_COUNT,
    Service,
)
from .render_storage import storage_readiness_line, storage_volume_lines


def header(service: Service) -> str:
    return generated_header(service.source.name)


def wrap_comment(text: str) -> str:
    return textwrap.fill(
        text,
        width=78,
        initial_indent="# ",
        subsequent_indent="# ",
    )


def container_unit(service: Service, fleet: Fleet) -> str:
    info = service.info
    container = service.container
    krun = service.krun
    lines = [header(service)]
    lines += ["[Unit]", f"Description={info.description}"]
    if info.documentation is not None:
        lines.append(f"Documentation={info.documentation}")

    lines += ["", "[Container]"]
    lines.append(f"ContainerName={info.name}")
    lines.append(f"Image={container.image}")
    if krun is not None:
        lines.append("PodmanArgs=--runtime=krun")
        lines.append(f"Annotation=krun.cpus={krun.cpus}")
        lines.append(f"Annotation=krun.ram_mib={krun.ram_mib}")
        if isinstance(krun, KrunPasst):
            lines.append("Annotation=krun.use_passt=1")
        elif isinstance(krun, KrunTap):
            lines.append(f"Annotation=krun.tap_name={service.tap_name}")
        lines.append("StopSignal=SIGINT")
    if container.network is not None:
        lines.append(f"Network={container.network}")
    if service.active_tap:
        # libkrun opens /dev/net/tun after crun enters the container mount
        # namespace, so the device must exist there as well as on the host.
        lines.append("AddDevice=/dev/net/tun")
        for peer in fleet.active_taps:
            lines.append(f"AddHost={peer.info.name}.krun:{peer.tap_guest.ip}")
        lines.append(f"AddHost=host.krun.internal:{service.tap_gateway.ip}")
    for server in container.dns:
        lines.append(f"DNS={server}")
    for setting in container.sysctls:
        lines.append(f"Sysctl={setting}")
    if container.container_user is not None:
        lines.append(f"User={container.container_user}")
    if container.health_cmd is not None:
        lines.append(f"HealthCmd={container.health_cmd}")

    if container.environment:
        lines.append("")
        lines += [
            f"Environment={key}={value}"
            for key, value in container.environment
        ]

    for volume in container.volumes:
        lines.append("")
        if volume.comment is not None:
            lines.append(f"# {volume.comment}")
        options = f":{volume.options}" if volume.options else ""
        lines.append(f"Volume={volume.source}:{volume.target}{options}")

    lines += storage_volume_lines(service)

    for secret in container.secrets:
        target = secret.target or f"/run/secrets/{secret.name}"
        lines.append("")
        lines.append(
            "# Runtime secret written at boot by "
            "sops-distribute-secrets.service"
        )
        lines.append(
            f"Volume=/run/nas-secrets/{info.name}/{secret.name}:"
            f"{target}:ro,Z"
        )

    if container.ports and not isinstance(krun, KrunTap):
        lines.append("")
        for port in container.ports:
            suffix = "" if port.protocol is Protocol.TCP else f"/{port.protocol.value}"
            lines.append(
                f"PublishPort={port.host}:{port.container_port}{suffix}"
            )

    if container.exec is not None:
        lines += ["", f"Exec={container.exec}"]

    lines += ["", "[Service]"]
    if service.active_tap:
        lines.append("ExecStartPre=/usr/bin/test -c /dev/net/tun")
        lines.append(
            "ExecStartPre=/usr/bin/bash -ceu '"
            "for i in {1..90}; do "
            "if /usr/bin/test -r /run/nas-krun-network/policy-ready && "
            f"/usr/bin/test -e /sys/class/net/{service.tap_name}; then exit 0; fi; "
            "sleep 1; done; "
            'echo "krun network policy was not ready within 90 seconds" >&2; exit 1'"'"
        )
    lines += [
        f"ExecStartPre=/usr/bin/test -r /run/nas-secrets/"
        f"{info.name}/{secret.name}"
        for secret in container.secrets
    ]
    readiness = service.startup.readiness
    storage_readiness = storage_readiness_line(service)
    if storage_readiness is not None:
        lines.append(storage_readiness)
    if isinstance(readiness, MarkerReadiness):
        required_paths = ""
        for required_path in readiness.paths:
            required_paths += f" --path {required_path.path}"
            if required_path.mount_source is not None:
                required_paths += f" --source {required_path.mount_source}"
            if required_path.owner is RequiredOwner.SERVICE:
                required_paths += f" --owner {service.host.uid}:{service.host.uid}"
            if required_path.access:
                access_flags = {
                    PathAccess.READ: "r",
                    PathAccess.WRITE: "w",
                    PathAccess.EXECUTE: "x",
                }
                required_paths += " --access " + "".join(
                    access_flags[access] for access in required_path.access
                )
        lines.append(
            "ExecStartPre=/usr/local/bin/nas-wait-for-readiness.sh "
            f"marker {readiness.marker} {readiness.timeout_sec} "
            f"{readiness.interval_sec}{required_paths}"
        )
    elif isinstance(readiness, HttpReadiness):
        lines.append(
            "ExecStartPre=/usr/local/bin/nas-wait-for-readiness.sh "
            f"http {readiness.url} {readiness.timeout_sec} "
            f"{readiness.interval_sec}"
        )
    if service.startup.require_published_tcp_ports_free:
        host_ports = " ".join(
            str(port.host_port)
            for port in container.ports
            if port.protocol is Protocol.TCP
        )
        lines.append(
            "ExecStartPre=/usr/local/bin/nas-assert-tcp-ports-free.sh "
            f"{host_ports}"
        )
    if service.active_tap:
        probe_port = service.tap_spec.probe_port
        lines.append(
            "ExecStartPost=/usr/bin/bash -ceu '"
            "for i in {1..30}; do "
            f"if /usr/bin/timeout 1 /usr/bin/bash -c \"</dev/tcp/{service.tap_guest.ip}/{probe_port}\" "
            ">/dev/null 2>&1; "
            "then exit 0; fi; sleep 1; done; "
            f"echo \"libkrun guest {service.tap_guest.ip}:{probe_port} was not reachable\" >&2; "
            "exit 1'"
        )
    lines.append("Restart=always")
    lines.append(f"RestartSec={service.unit.restart_sec}")
    timeout_start_sec = service.unit.timeout_start_sec
    if timeout_start_sec is None and service.storage:
        timeout_start_sec = 330
    if timeout_start_sec is not None:
        lines.append(f"TimeoutStartSec={timeout_start_sec}")

    lines += ["", "[Install]", "WantedBy=default.target"]
    return "\n".join(lines) + "\n"


def sysusers_conf(service: Service) -> str:
    host = service.host
    comment = wrap_comment(
        f"Host account for the rootless {host.display_name} Quadlet. This must "
        "stay usable by systemd's lingering user manager, so do not mark it "
        'as a fully locked "u!" account.'
    )
    return "\n".join(
        [
            header(service),
            comment,
            f"g {host.username} {host.uid}",
            f'u {host.username} {host.uid}:{host.uid} "NAS '
            f'{host.display_name} service user" /var/home/{host.username} '
            "/sbin/nologin",
        ]
    ) + "\n"


def tmpfiles_conf(service: Service) -> str:
    host = service.host
    lines = [
        header(service),
        wrap_comment(
            f"Rootless {host.display_name} uses a namespaced host account so "
            "the service identity does not collide with upstream image defaults."
        ),
    ]
    home = f"/var/home/{host.username}"
    for subdir in (
        "",
        "/.config",
        "/.config/containers",
        "/.local",
        "/.local/share",
        "/.local/share/containers",
        "/.cache",
    ):
        lines.append(f"d {home}{subdir} 0750 {host.username} {host.username} -")
    lines.append("d /var/lib/systemd/linger 0755 root root -")
    lines.append(f"f /var/lib/systemd/linger/{host.username} 0644 root root -")
    return "\n".join(lines) + "\n"


def ensure_account_script(service: Service) -> str:
    host = service.host

    return f"""#!/bin/bash
{header(service)}
# ABOUTME: Ensures the {host.username} rootless service account has the state
# required for a lingering user manager.

set -euo pipefail

USER_NAME="{host.username}"
USER_UID="{host.uid}"
USER_HOME="/var/home/{host.username}"
USER_SHELL="/sbin/nologin"
USER_SUBID_START="{host.subid_start}"
USER_SUBID_COUNT="{SUBID_COUNT}"

log() {{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}}

ensure_subid_entry() {{
    local file="$1"
    local expected="${{USER_NAME}}:${{USER_SUBID_START}}:${{USER_SUBID_COUNT}}"
    local current

    if [[ ! -e "${{file}}" ]]; then
        install -o root -g root -m 0644 /dev/null "${{file}}"
    fi

    current="$(grep -E "^${{USER_NAME}}:" "${{file}}" || true)"

    if [[ -z "${{current}}" ]]; then
        log "Adding ${{expected}} to ${{file}}"
        printf '%s\\n' "${{expected}}" >> "${{file}}"
        return
    fi

    if [[ "${{current}}" != "${{expected}}" ]]; then
        log "Leaving existing ${{file}} entry for ${{USER_NAME}}: ${{current}}"
    fi
}}

if ! getent passwd "${{USER_NAME}}" >/dev/null; then
    log "User ${{USER_NAME}} does not exist yet, skipping"
    exit 0
fi

shadow_entry="$(getent shadow "${{USER_NAME}}" || true)"
shadow_password_field="${{shadow_entry#*:}}"
shadow_password_field="${{shadow_password_field%%:*}}"

if [[ -z "${{shadow_password_field}}" || "${{shadow_password_field}}" == "!"* ]]; then
    log "Resetting ${{USER_NAME}} to an invalid but not fully locked password marker"
    usermod --password '*' "${{USER_NAME}}"
fi

log "Clearing account expiry for ${{USER_NAME}}"
chage --expiredate -1 "${{USER_NAME}}"

current_home="$(getent passwd "${{USER_NAME}}" | cut -d: -f6)"
if [[ "${{current_home}}" != "${{USER_HOME}}" ]]; then
    log "Resetting home for ${{USER_NAME}} to ${{USER_HOME}}"
    usermod --home "${{USER_HOME}}" "${{USER_NAME}}"
fi

current_shell="$(getent passwd "${{USER_NAME}}" | cut -d: -f7)"
if [[ "${{current_shell}}" != "${{USER_SHELL}}" ]]; then
    log "Resetting shell for ${{USER_NAME}} to ${{USER_SHELL}}"
    usermod --shell "${{USER_SHELL}}" "${{USER_NAME}}"
fi

ensure_subid_entry /etc/subuid
ensure_subid_entry /etc/subgid

if systemctl is-failed --quiet "user@${{USER_UID}}.service"; then
    log "Retrying user@${{USER_UID}}.service after account setup"
    systemctl reset-failed "user@${{USER_UID}}.service"
    systemctl start "user@${{USER_UID}}.service"
fi
"""


def ensure_account_unit(service: Service) -> str:
    host = service.host
    return f"""{header(service)}
[Unit]
Description=Prepare {host.username} for a lingering user manager
DefaultDependencies=no
After=local-fs.target systemd-sysusers.service systemd-tmpfiles-setup.service
Before=sysinit.target systemd-logind.service user@{host.uid}.service
ConditionPathExists=/etc/passwd

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ensure-nas-{host.slug}-account.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
"""
