"""Strict TOML parsing for rootless service configuration."""

from __future__ import annotations

import ipaddress
import re
import tomllib
from pathlib import Path
from typing import Literal, Mapping, NoReturn

from .model import (
    AssetsSpec,
    ConfigError,
    ContainerSpec,
    DataSpec,
    HostIdentity,
    HttpReadiness,
    IngressRule,
    KrunNetwork,
    KrunPasst,
    KrunSpec,
    KrunTap,
    KrunTsi,
    MarkerReadiness,
    PathAccess,
    Protocol,
    PublishedPort,
    ReadinessSpec,
    RequiredOwner,
    RequiredPath,
    SecretMount,
    Service,
    ServiceInfo,
    StartupSpec,
    UnitSpec,
    VolumeMount,
)


def _fail(path: str, message: str) -> NoReturn:
    raise ConfigError(f"{path}: {message}")


def _table(
    value: object,
    path: str,
    allowed: set[str],
    *,
    required: bool = True,
) -> dict[str, object]:
    if value is None and not required:
        return {}
    if not isinstance(value, dict):
        _fail(path, "must be a table")
    unknown = sorted(set(value) - allowed)
    if unknown:
        _fail(path, f"has unknown keys: {', '.join(unknown)}")
    return value


def _required(table: Mapping[str, object], key: str, path: str) -> object:
    if key not in table:
        _fail(path, f"is missing {key!r}")
    return table[key]


def _string(value: object, path: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        _fail(path, "must be a non-empty string" if nonempty else "must be a string")
    if any(not character.isprintable() for character in value):
        _fail(path, "cannot contain control characters")
    return value


def _integer(
    value: object,
    path: str,
) -> int:
    if type(value) is not int:
        _fail(path, "must be an integer")
    return value


def _boolean(value: object, path: str) -> bool:
    if type(value) is not bool:
        _fail(path, "must be a boolean")
    return value


def _optional_string(
    table: Mapping[str, object], key: str, path: str
) -> str | None:
    return _string(table[key], f"{path}.{key}") if key in table else None


def _string_array(value: object, path: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        _fail(path, "must be an array of strings")
    result = []
    for index, item in enumerate(value, start=1):
        result.append(_string(item, f"{path}[{index}]"))
    return tuple(result)


def _parse_service_info(raw: object, name: str) -> ServiceInfo:
    path = f"{name}: [service]"
    table = _table(raw, path, {"name", "description", "documentation"})
    service_name = _string(_required(table, "name", path), f"{path}.name")
    documentation = (
        _string(table["documentation"], f"{path}.documentation")
        if "documentation" in table
        else None
    )
    return ServiceInfo(
        name=service_name,
        description=_string(
            _required(table, "description", path), f"{path}.description"
        ),
        documentation=documentation,
    )


def _parse_host(raw: object, name: str) -> HostIdentity:
    path = f"{name}: [host]"
    table = _table(
        raw,
        path,
        {"username", "uid", "subid-start", "display-name"},
    )
    username = _string(_required(table, "username", path), f"{path}.username")
    uid = _integer(_required(table, "uid", path), f"{path}.uid")
    display_name = _string(
        _required(table, "display-name", path), f"{path}.display-name"
    )
    return HostIdentity(
        username=username,
        uid=uid,
        subid_start=_integer(
            _required(table, "subid-start", path),
            f"{path}.subid-start",
        ),
        display_name=display_name,
    )


def _parse_ports(raw: object, name: str) -> tuple[PublishedPort, ...]:
    path = f"{name}: [container].ports"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(item, item_path, {"host", "container", "protocol"})
        host = _string(_required(table, "host", item_path), f"{item_path}.host")
        if host.startswith("["):
            match = re.fullmatch(r"\[([^]]+)]:(\d+)", host)
            expected_version = 6
        else:
            match = re.fullmatch(r"([^:]+):(\d+)", host)
            expected_version = 4
        if match is None:
            _fail(f"{item_path}.host", "must be an IPv4:port or [IPv6]:port endpoint")
        try:
            address = ipaddress.ip_address(match.group(1))
        except ValueError:
            _fail(f"{item_path}.host", "contains an invalid IP address")
        if address.version != expected_version:
            _fail(f"{item_path}.host", "must bracket IPv6 addresses")
        host_port = int(match.group(2))
        container_port = _integer(
            _required(table, "container", item_path), f"{item_path}.container"
        )
        protocol_text = _string(
            table.get("protocol", Protocol.TCP.value),
            f"{item_path}.protocol",
        )
        if protocol_text not in {item.value for item in Protocol}:
            _fail(f"{item_path}.protocol", 'must be "tcp" or "udp"')
        protocol = Protocol(protocol_text)
        result.append(
            PublishedPort(address, host_port, container_port, protocol)
        )
    return tuple(result)


def _parse_dns(raw: object, name: str) -> tuple[ipaddress.IPv4Address | ipaddress.IPv6Address, ...]:
    path = f"{name}: [container].dns"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of IP addresses")
    result = []
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        text = _string(item, item_path)
        try:
            address = ipaddress.ip_address(text)
        except ValueError:
            _fail(item_path, "must be a valid IP address")
        result.append(address)
    return tuple(result)


def _parse_sysctls(raw: object, name: str) -> tuple[str, ...]:
    path = f"{name}: [container].sysctls"
    if raw is None:
        return ()
    return _string_array(raw, path)


def _parse_environment(raw: object, name: str) -> tuple[tuple[str, str], ...]:
    path = f"{name}: [container.environment]"
    if raw is None:
        return ()
    if not isinstance(raw, dict):
        _fail(path, "must be a table")
    result = []
    for key, value in raw.items():
        environment_name = _string(key, f"{path} key")
        environment_value = _string(
            value,
            f"{path}.{environment_name}",
            nonempty=False,
        )
        result.append((environment_name, environment_value))
    return tuple(result)


def _parse_volumes(raw: object, name: str) -> tuple[VolumeMount, ...]:
    path = f"{name}: [container].volumes"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(item, item_path, {"source", "target", "options", "comment"})
        source = _string(
            _required(table, "source", item_path),
            f"{item_path}.source",
        )
        target = _string(
            _required(table, "target", item_path),
            f"{item_path}.target",
        )
        options = _optional_string(table, "options", item_path)
        result.append(
            VolumeMount(
                source=source,
                target=target,
                options=options,
                comment=_optional_string(table, "comment", item_path),
            )
        )
    return tuple(result)


def _parse_secrets(raw: object, name: str) -> tuple[SecretMount, ...]:
    path = f"{name}: [container].secrets"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(item, item_path, {"name", "target"})
        secret_name = _string(_required(table, "name", item_path), f"{item_path}.name")
        target = (
            _string(table["target"], f"{item_path}.target")
            if "target" in table
            else None
        )
        result.append(SecretMount(secret_name, target))
    return tuple(result)


def _parse_container(raw: object, name: str) -> ContainerSpec:
    path = f"{name}: [container]"
    table = _table(
        raw,
        path,
        {
            "image", "enabled", "network", "container-user", "health-cmd",
            "dns", "sysctls", "environment", "volumes", "secrets", "ports", "exec",
        },
    )
    image = _string(_required(table, "image", path), f"{path}.image")
    health_cmd_text = _optional_string(table, "health-cmd", path)
    if health_cmd_text is not None and health_cmd_text != "none":
        _fail(f"{path}.health-cmd", 'currently supports only "none"')
    health_cmd: Literal["none"] | None = (
        "none" if health_cmd_text is not None else None
    )
    network_text = _optional_string(table, "network", path)
    if network_text is not None and network_text != "host":
        _fail(f"{path}.network", 'currently supports only "host"')
    network: Literal["host"] | None = (
        "host" if network_text is not None else None
    )
    exec_text = _optional_string(table, "exec", path)
    return ContainerSpec(
        image=image,
        enabled=_boolean(table["enabled"], f"{path}.enabled") if "enabled" in table else True,
        network=network,
        container_user=_integer(table["container-user"], f"{path}.container-user")
        if "container-user" in table else None,
        health_cmd=health_cmd,
        dns=_parse_dns(table.get("dns"), name),
        sysctls=_parse_sysctls(table.get("sysctls"), name),
        environment=_parse_environment(table.get("environment"), name),
        volumes=_parse_volumes(table.get("volumes"), name),
        secrets=_parse_secrets(table.get("secrets"), name),
        ports=_parse_ports(table.get("ports"), name),
        exec=exec_text,
    )


def _parse_ingress(raw: object, name: str) -> tuple[IngressRule, ...]:
    path = f"{name}: [[krun.ingress]]"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(item, item_path, {"from", "ports"})
        source = _string(_required(table, "from", item_path), f"{item_path}.from")
        ports_raw = _required(table, "ports", item_path)
        if not isinstance(ports_raw, list):
            _fail(f"{item_path}.ports", "must be an array of TCP ports")
        ports = tuple(
            _integer(port, f"{item_path}.ports[{index}]")
            for index, port in enumerate(ports_raw, start=1)
        )
        result.append(IngressRule(source, ports))
    return tuple(result)


def _parse_host_access(raw: object, name: str) -> tuple[int, ...]:
    path = f"{name}: [krun].host-access"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of TCP ports")
    ports = tuple(
        _integer(port, f"{path}[{index}]")
        for index, port in enumerate(raw, start=1)
    )
    return ports


def _parse_krun(raw: object, name: str, container: ContainerSpec) -> KrunSpec | None:
    if raw is None:
        return None
    path = f"{name}: [krun]"
    table = _table(
        raw,
        path,
        {
            "enabled",
            "cpus",
            "ram-mib",
            "network",
            "ipv4",
            "probe-port",
            "ingress",
            "host-access",
        },
    )
    enabled = _boolean(_required(table, "enabled", path), f"{path}.enabled")
    if not enabled:
        extra = sorted(set(table) - {"enabled"})
        if extra:
            _fail(path, f"fields are not allowed when disabled: {', '.join(extra)}")
        return None
    cpus = _integer(_required(table, "cpus", path), f"{path}.cpus")
    ram_mib = _integer(_required(table, "ram-mib", path), f"{path}.ram-mib")
    network_text = _string(
        table.get("network", KrunNetwork.TSI.value),
        f"{path}.network",
    )
    if network_text not in {item.value for item in KrunNetwork}:
        _fail(f"{path}.network", 'must be "tsi", "passt", or "tap"')
    network = KrunNetwork(network_text)
    tap_only_present = any(
        key in table for key in ("ipv4", "probe-port", "ingress", "host-access")
    )
    if network is KrunNetwork.TAP:
        try:
            ipv4_text = _string(_required(table, "ipv4", path), f"{path}.ipv4")
            parsed = ipaddress.ip_interface(ipv4_text)
        except (TypeError, ValueError):
            _fail(f"{path}.ipv4", "must be an IPv4 interface address")
        if not isinstance(parsed, ipaddress.IPv4Interface):
            _fail(f"{path}.ipv4", "must be an IPv4 interface address")
        ipv4 = parsed
        probe_port = _integer(
            _required(table, "probe-port", path),
            f"{path}.probe-port",
        )
        return KrunTap(
            cpus=cpus,
            ram_mib=ram_mib,
            ipv4=ipv4,
            probe_port=probe_port,
            ingress=_parse_ingress(table.get("ingress"), name),
            host_access=_parse_host_access(table.get("host-access"), name),
        )
    if tap_only_present:
        _fail(path, 'TAP-only fields require network = "tap"')
    if network is KrunNetwork.PASST:
        return KrunPasst(cpus, ram_mib)
    return KrunTsi(cpus, ram_mib)


def _parse_data(raw: object, name: str) -> DataSpec | None:
    if raw is None:
        return None
    path = f"{name}: [data]"
    table = _table(raw, path, {"path", "mode", "subdirectories"})
    subdirectories = _string_array(
        table.get("subdirectories", []),
        f"{path}.subdirectories",
    )
    data_path = _string(
        _required(table, "path", path),
        f"{path}.path",
    )
    mode = _string(table.get("mode", "0750"), f"{path}.mode")
    return DataSpec(
        data_path,
        mode,
        subdirectories,
    )


def _parse_assets(
    raw: object,
    name: str,
) -> AssetsSpec | None:
    if raw is None:
        return None
    path = f"{name}: [assets]"
    table = _table(raw, path, {"path"})
    asset_path = _string(
        _required(table, "path", path),
        f"{path}.path",
    )
    return AssetsSpec(asset_path)


def _parse_unit(raw: object, name: str) -> UnitSpec:
    if raw is None:
        return UnitSpec()
    path = f"{name}: [unit]"
    table = _table(raw, path, {"restart-sec", "timeout-start-sec"})
    return UnitSpec(
        restart_sec=_integer(table.get("restart-sec", 30), f"{path}.restart-sec"),
        timeout_start_sec=_integer(table["timeout-start-sec"], f"{path}.timeout-start-sec")
        if "timeout-start-sec" in table else None,
    )


def _parse_required_paths(raw: object, name: str) -> tuple[RequiredPath, ...]:
    path = f"{name}: [[startup.readiness.paths]]"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(
            item,
            item_path,
            {"path", "mount-source", "owner", "access"},
        )
        required_path = _string(
            _required(table, "path", item_path),
            f"{item_path}.path",
        )

        mount_source = None
        if "mount-source" in table:
            mount_source = _string(
                table["mount-source"],
                f"{item_path}.mount-source",
            )

        owner = None
        if "owner" in table:
            owner_text = _string(table["owner"], f"{item_path}.owner")
            try:
                owner = RequiredOwner(owner_text)
            except ValueError:
                _fail(
                    f"{item_path}.owner",
                    f"must be {RequiredOwner.SERVICE.value!r}",
                )

        access = []
        for index, access_name in enumerate(
            _string_array(table.get("access", []), f"{item_path}.access"),
            start=1,
        ):
            try:
                path_access = PathAccess(access_name)
            except ValueError:
                _fail(
                    f"{item_path}.access[{index}]",
                    "must be one of read, write, execute",
                )
            access.append(path_access)

        result.append(
            RequiredPath(
                required_path,
                mount_source,
                owner,
                tuple(access),
            )
        )
    return tuple(result)


def _parse_startup(
    raw: object,
    name: str,
) -> StartupSpec:
    if raw is None:
        return StartupSpec()
    path = f"{name}: [startup]"
    table = _table(raw, path, {"readiness", "reject-published-tcp-ports"})
    reject_conflicts = (
        _boolean(
            table["reject-published-tcp-ports"],
            f"{path}.reject-published-tcp-ports",
        )
        if "reject-published-tcp-ports" in table
        else False
    )
    readiness_raw = table.get("readiness")
    if readiness_raw is None:
        return StartupSpec(reject_published_tcp_ports=reject_conflicts)

    readiness_path = f"{name}: [startup.readiness]"
    readiness = _table(
        readiness_raw,
        readiness_path,
        {"marker", "url", "timeout-sec", "interval-sec", "paths"},
    )
    marker_present = "marker" in readiness
    url_present = "url" in readiness
    if marker_present == url_present:
        _fail(readiness_path, "requires exactly one of marker or url")
    timeout_sec = _integer(
        _required(readiness, "timeout-sec", readiness_path),
        f"{readiness_path}.timeout-sec",
    )
    interval_sec = _integer(
        _required(readiness, "interval-sec", readiness_path),
        f"{readiness_path}.interval-sec",
    )
    if marker_present:
        marker = _string(
            readiness["marker"],
            f"{readiness_path}.marker",
        )
        readiness_spec: ReadinessSpec = MarkerReadiness(
            marker,
            timeout_sec,
            interval_sec,
            _parse_required_paths(readiness.get("paths"), name),
        )
    else:
        if "paths" in readiness:
            _fail(
                f"{readiness_path}.paths",
                "is supported only with marker readiness",
            )
        url = _string(readiness["url"], f"{readiness_path}.url")
        readiness_spec = HttpReadiness(url, timeout_sec, interval_sec)
    return StartupSpec(readiness_spec, reject_conflicts)


def load_service(toml_path: Path) -> Service:
    with toml_path.open("rb") as config_file:
        raw = tomllib.load(config_file)
    name = toml_path.name
    top = _table(
        raw,
        name,
        {
            "service",
            "host",
            "container",
            "krun",
            "data",
            "assets",
            "startup",
            "unit",
        },
    )
    for required in ("service", "host", "container"):
        if required not in top:
            _fail(name, f"missing required [{required}] section")
    info = _parse_service_info(top["service"], name)
    host = _parse_host(top["host"], name)
    container = _parse_container(top["container"], name)
    krun = _parse_krun(top.get("krun"), name, container)
    return Service(
        source=toml_path,
        info=info,
        host=host,
        container=container,
        krun=krun,
        data=_parse_data(top.get("data"), name),
        assets=_parse_assets(top.get("assets"), name),
        startup=_parse_startup(top.get("startup"), name),
        unit=_parse_unit(top.get("unit"), name),
    )
