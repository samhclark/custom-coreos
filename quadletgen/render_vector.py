"""Render the host Vector journald collector from typed service identity."""

from __future__ import annotations

from .headers import generated_header
from .model import Fleet, Service


VECTOR_CONFIG_PATH = "etc/vector/vector.yaml"


def _component_name(service: Service) -> str:
    """Return a stable Vector component name for a service."""
    return service.info.name.replace("-", "_")


def journald_services(fleet: Fleet) -> tuple[Service, ...]:
    """Return enabled services which opt into host journald collection.

    ``container.log-driver = "journald"`` is deliberately the single
    declaration: Quadlet rendering and Vector collection cannot drift apart.
    """
    return tuple(
        sorted(
            (
                service
                for service in fleet.services
                if service.container.enabled
                and service.container.log_driver == "journald"
            ),
            key=lambda service: service.info.name,
        )
    )


def vector_config(fleet: Fleet) -> str:
    """Render the complete image-managed Vector configuration."""
    services = journald_services(fleet)
    lines = [
        generated_header("*.toml"),
        "data_dir: /var/lib/nas-vector",
        "",
    ]

    lines += ["sources:"]
    for service in services:
        component = _component_name(service)
        lines += [
            f"  {component}_journald:",
            "    type: journald",
            "    include_matches:",
            "      _UID:",
            f'        - "{service.host.uid}"',
            "    current_boot_only: false",
            "    since_now: false",
            "",
        ]

    lines += ["transforms:"]
    for service in services:
        component = _component_name(service)
        lines += [
            f"  {component}:",
            "    type: remap",
            "    inputs:",
            f"      - {component}_journald",
            "    source: |",
            '      .host = "nas"',
            f'      .service = "{service.info.name}"',
            "",
        ]

    lines += ["sinks:", "  victoria_logs:", "    type: http", "    inputs:"]
    for service in services:
        lines.append(f"      - {_component_name(service)}")
    lines += [
        "    uri: http://127.0.0.1:9428/insert/jsonline?_stream_fields=host,service&_msg_field=message&_time_field=timestamp",
        "    compression: gzip",
        "    framing:",
        "      method: newline_delimited",
        "    encoding:",
        "      codec: json",
        "    healthcheck:",
        "      enabled: false",
        "    buffer:",
        "      type: disk",
        "      max_size: 1073741824",
        "      when_full: block",
        "",
    ]
    return "\n".join(lines)
