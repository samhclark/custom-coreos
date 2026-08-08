"""Strict TOML parsing for rootless service configuration."""

from __future__ import annotations

import ipaddress
import posixpath
import re
import tomllib
from pathlib import Path
from typing import Mapping, NoReturn
from urllib.parse import urlsplit

from .model import (
    AssetsSpec,
    ConfigError,
    ContainerSpec,
    DataSpec,
    HostIdentity,
    HttpReadiness,
    IngressRule,
    KrunDisabled,
    KrunNetwork,
    KrunPasst,
    KrunSpec,
    KrunTap,
    KrunTsi,
    MarkerReadiness,
    Protocol,
    PublishedPort,
    ReadinessSpec,
    RequiredMount,
    SecretMount,
    Service,
    ServiceInfo,
    StartupSpec,
    UnitSpec,
    VolumeMount,
)

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
USERNAME_RE = re.compile(r"^_nas_[a-z0-9]+$")
PINNED_IMAGE_RE = re.compile(r"^[^@\s]+:[^@:\s]+@sha256:[0-9a-f]{64}$")
SECRET_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
SUBDIRECTORY_RE = re.compile(r"^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$")


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
    return value


def _integer(value: object, path: str, *, minimum: int | None = None) -> int:
    if type(value) is not int:
        _fail(path, "must be an integer")
    if minimum is not None and value < minimum:
        _fail(path, f"must be at least {minimum}")
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


def _port_number(value: object, path: str) -> int:
    number = _integer(value, path)
    if not 1 <= number <= 65535:
        _fail(path, "must be between 1 and 65535")
    return number


def _parse_service_info(raw: object, name: str) -> ServiceInfo:
    path = f"{name}: [service]"
    table = _table(raw, path, {"name", "description", "documentation"})
    service_name = _string(_required(table, "name", path), f"{path}.name")
    if not NAME_RE.fullmatch(service_name):
        _fail(f"{path}.name", f"must match {NAME_RE.pattern}")
    return ServiceInfo(
        name=service_name,
        description=_string(
            _required(table, "description", path), f"{path}.description"
        ),
        documentation=_optional_string(table, "documentation", path),
    )


def _parse_host(raw: object, name: str) -> HostIdentity:
    path = f"{name}: [host]"
    table = _table(
        raw,
        path,
        {"username", "uid", "subid-start", "display-name"},
    )
    username = _string(_required(table, "username", path), f"{path}.username")
    if not USERNAME_RE.fullmatch(username):
        _fail(f"{path}.username", f"must match {USERNAME_RE.pattern}")
    uid = _integer(_required(table, "uid", path), f"{path}.uid", minimum=1)
    return HostIdentity(
        username=username,
        uid=uid,
        subid_start=_integer(
            _required(table, "subid-start", path),
            f"{path}.subid-start",
            minimum=1,
        ),
        display_name=_string(
            _required(table, "display-name", path), f"{path}.display-name"
        ),
    )


def _parse_ports(raw: object, name: str) -> tuple[PublishedPort, ...]:
    path = f"{name}: [container].ports"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    seen: set[tuple[str, int, Protocol]] = set()
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
        host_port = _port_number(int(match.group(2)), f"{item_path}.host port")
        container_port = _port_number(
            _required(table, "container", item_path), f"{item_path}.container"
        )
        protocol_text = table.get("protocol", Protocol.TCP.value)
        if protocol_text not in {item.value for item in Protocol}:
            _fail(f"{item_path}.protocol", 'must be "tcp" or "udp"')
        protocol = Protocol(protocol_text)
        key = (host, container_port, protocol)
        if key in seen:
            _fail(item_path, f"duplicate published port {host}:{container_port}/{protocol.value!s}")
        seen.add(key)
        result.append(
            PublishedPort(host, address, host_port, container_port, protocol)
        )
    return tuple(result)


def _parse_dns(raw: object, name: str) -> tuple[ipaddress.IPv4Address | ipaddress.IPv6Address, ...]:
    path = f"{name}: [container].dns"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of IP addresses")
    result = []
    seen = set()
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        text = _string(item, item_path)
        try:
            address = ipaddress.ip_address(text)
        except ValueError:
            _fail(item_path, "must be a valid IP address")
        if address in seen:
            _fail(item_path, f"duplicate DNS server {text!r}")
        seen.add(address)
        result.append(address)
    return tuple(result)


def _parse_sysctls(raw: object, name: str) -> tuple[str, ...]:
    path = f"{name}: [container].sysctls"
    if raw is None:
        return ()
    values = _string_array(raw, path)
    seen = set()
    for value in values:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+=[^\s=]+", value):
            _fail(path, f"{value!r} must use name=value format")
        if value in seen:
            _fail(path, f"duplicate sysctl {value!r}")
        seen.add(value)
    return values


def _parse_environment(raw: object, name: str) -> tuple[tuple[str, str], ...]:
    path = f"{name}: [container.environment]"
    if raw is None:
        return ()
    if not isinstance(raw, dict):
        _fail(path, "must be a table")
    return tuple(
        (_string(key, f"{path} key"), _string(value, f"{path}.{key}", nonempty=False))
        for key, value in raw.items()
    )


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
        result.append(
            VolumeMount(
                source=_string(_required(table, "source", item_path), f"{item_path}.source"),
                target=_string(_required(table, "target", item_path), f"{item_path}.target"),
                options=_optional_string(table, "options", item_path),
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
    seen = set()
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(item, item_path, {"name", "target"})
        secret_name = _string(_required(table, "name", item_path), f"{item_path}.name")
        if not SECRET_NAME_RE.fullmatch(secret_name):
            _fail(f"{item_path}.name", f"must match {SECRET_NAME_RE.pattern}")
        if secret_name in seen:
            _fail(item_path, f"duplicate secret {secret_name!r}")
        seen.add(secret_name)
        result.append(
            SecretMount(secret_name, _optional_string(table, "target", item_path))
        )
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
    if not PINNED_IMAGE_RE.fullmatch(image):
        _fail(f"{path}.image", "must use an immutable name:tag@sha256 digest")
    health_cmd = _optional_string(table, "health-cmd", path)
    if health_cmd is not None and health_cmd != "none":
        _fail(f"{path}.health-cmd", 'currently supports only "none"')
    return ContainerSpec(
        image=image,
        enabled=_boolean(table["enabled"], f"{path}.enabled") if "enabled" in table else True,
        network=_optional_string(table, "network", path),
        container_user=_integer(table["container-user"], f"{path}.container-user", minimum=0)
        if "container-user" in table else None,
        health_cmd=health_cmd,
        dns=_parse_dns(table.get("dns"), name),
        sysctls=_parse_sysctls(table.get("sysctls"), name),
        environment=_parse_environment(table.get("environment"), name),
        volumes=_parse_volumes(table.get("volumes"), name),
        secrets=_parse_secrets(table.get("secrets"), name),
        ports=_parse_ports(table.get("ports"), name),
        exec=_optional_string(table, "exec", path),
    )


def _parse_ingress(raw: object, name: str) -> tuple[IngressRule, ...]:
    path = f"{name}: [[krun.ingress]]"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    seen = set()
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(item, item_path, {"from", "ports"})
        source = _string(_required(table, "from", item_path), f"{item_path}.from")
        if not NAME_RE.fullmatch(source):
            _fail(f"{item_path}.from", "must be a service name")
        ports_raw = _required(table, "ports", item_path)
        if not isinstance(ports_raw, list) or not ports_raw:
            _fail(f"{item_path}.ports", "must contain TCP ports")
        ports = tuple(
            _port_number(port, f"{item_path}.ports[{index}]")
            for index, port in enumerate(ports_raw, start=1)
        )
        if len(set(ports)) != len(ports):
            _fail(f"{item_path}.ports", "contains duplicates")
        key = (source, ports)
        if key in seen:
            _fail(item_path, "duplicate ingress rule")
        seen.add(key)
        result.append(IngressRule(source, ports))
    return tuple(result)


def _parse_host_access(raw: object, name: str) -> tuple[int, ...]:
    path = f"{name}: [krun].host-access"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of TCP ports")
    ports = tuple(
        _port_number(port, f"{path}[{index}]")
        for index, port in enumerate(raw, start=1)
    )
    if len(set(ports)) != len(ports):
        _fail(path, "contains duplicates")
    return ports


def _parse_krun(raw: object, name: str, container: ContainerSpec) -> KrunSpec | None:
    if raw is None:
        return None
    path = f"{name}: [krun]"
    table = _table(
        raw,
        path,
        {"enabled", "cpus", "ram-mib", "network", "ipv4", "ingress", "host-access"},
    )
    enabled = _boolean(_required(table, "enabled", path), f"{path}.enabled")
    if not enabled:
        extra = sorted(set(table) - {"enabled"})
        if extra:
            _fail(path, f"fields are not allowed when disabled: {', '.join(extra)}")
        return KrunDisabled()
    cpus = _integer(_required(table, "cpus", path), f"{path}.cpus", minimum=1)
    ram_mib = _integer(_required(table, "ram-mib", path), f"{path}.ram-mib", minimum=128)
    network_text = table.get("network", KrunNetwork.TSI.value)
    if network_text not in {item.value for item in KrunNetwork}:
        _fail(f"{path}.network", 'must be "tsi", "passt", or "tap"')
    network = KrunNetwork(network_text)
    if network is KrunNetwork.PASST and container.network == "host":
        _fail(path, 'network = "passt" requires a private container network namespace')
    tap_only_present = any(key in table for key in ("ipv4", "ingress", "host-access"))
    if network is KrunNetwork.TAP:
        if container.network != "host":
            _fail(path, 'network = "tap" requires [container].network = "host"')
        try:
            ipv4_text = _string(_required(table, "ipv4", path), f"{path}.ipv4")
            parsed = ipaddress.ip_interface(ipv4_text)
        except (TypeError, ValueError):
            _fail(f"{path}.ipv4", "must be an IPv4 interface address")
        if not isinstance(parsed, ipaddress.IPv4Interface) or parsed.network.prefixlen != 30:
            _fail(f"{path}.ipv4", "must use a dedicated IPv4 /30")
        ipv4 = parsed
        if parsed.ip != parsed.network.network_address + 2:
            _fail(f"{path}.ipv4", "must be the second usable /30 address")
        for port in container.ports:
            if str(port.host_address) not in {"127.0.0.1", "0.0.0.0"}:
                _fail(path, 'TAP host publications support only "127.0.0.1" or "0.0.0.0" addresses')
    elif tap_only_present:
        _fail(path, 'TAP-only fields require network = "tap"')
    if container.network == "host":
        for server in container.dns:
            if server.is_loopback:
                _fail(path, f"network = \"host\" cannot use loopback DNS server {str(server)!r}")
    if network is KrunNetwork.TAP:
        return KrunTap(
            cpus,
            ram_mib,
            ipv4,
            _parse_ingress(table.get("ingress"), name),
            _parse_host_access(table.get("host-access"), name),
        )
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
    for subdirectory in subdirectories:
        if (
            not SUBDIRECTORY_RE.fullmatch(subdirectory)
            or any(part in {".", ".."} for part in subdirectory.split("/"))
        ):
            _fail(
                f"{path}.subdirectories",
                f"contains unsafe relative path {subdirectory!r}",
            )
    if len(set(subdirectories)) != len(subdirectories):
        _fail(f"{path}.subdirectories", "contains duplicates")
    return DataSpec(
        _string(_required(table, "path", path), f"{path}.path"),
        _string(table.get("mode", "0750"), f"{path}.mode"),
        subdirectories,
    )


def _parse_assets(raw: object, name: str) -> AssetsSpec | None:
    if raw is None:
        return None
    path = f"{name}: [assets]"
    table = _table(raw, path, {"path"})
    asset_path = _string(_required(table, "path", path), f"{path}.path")
    if "\t" in asset_path or "\n" in asset_path:
        _fail(f"{path}.path", "cannot contain tabs or newlines")
    return AssetsSpec(asset_path)


def _parse_unit(raw: object, name: str) -> UnitSpec:
    if raw is None:
        return UnitSpec()
    path = f"{name}: [unit]"
    table = _table(raw, path, {"restart-sec", "timeout-start-sec"})
    return UnitSpec(
        restart_sec=_integer(table.get("restart-sec", 30), f"{path}.restart-sec", minimum=0),
        timeout_start_sec=_integer(table["timeout-start-sec"], f"{path}.timeout-start-sec", minimum=1)
        if "timeout-start-sec" in table else None,
    )


def _parse_required_mounts(raw: object, name: str) -> tuple[RequiredMount, ...]:
    path = f"{name}: [[startup.readiness.mounts]]"
    if raw is None:
        return ()
    if not isinstance(raw, list):
        _fail(path, "must be an array of tables")
    result = []
    seen = set()
    for index, item in enumerate(raw, start=1):
        item_path = f"{path}[{index}]"
        table = _table(item, item_path, {"path", "source"})
        mount_path = _string(
            _required(table, "path", item_path),
            f"{item_path}.path",
        )
        source = _string(
            _required(table, "source", item_path),
            f"{item_path}.source",
        )
        for value, field in ((mount_path, "path"), (source, "source")):
            if any(character.isspace() for character in value) or "=" in value:
                _fail(
                    f"{item_path}.{field}",
                    "cannot contain whitespace or equals signs",
                )
        if not mount_path.startswith("/") or posixpath.normpath(mount_path) != mount_path:
            _fail(f"{item_path}.path", "must be an absolute normalized path")
        key = (mount_path, source)
        if key in seen:
            _fail(item_path, "duplicates an earlier mount requirement")
        seen.add(key)
        result.append(RequiredMount(mount_path, source))
    return tuple(result)


def _parse_startup(
    raw: object,
    name: str,
    container: ContainerSpec,
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
    if reject_conflicts and not any(
        port.protocol is Protocol.TCP for port in container.ports
    ):
        _fail(
            f"{path}.reject-published-tcp-ports",
            "requires at least one published TCP port",
        )
    readiness_raw = table.get("readiness")
    if readiness_raw is None:
        return StartupSpec(reject_published_tcp_ports=reject_conflicts)

    readiness_path = f"{name}: [startup.readiness]"
    readiness = _table(
        readiness_raw,
        readiness_path,
        {"marker", "url", "timeout-sec", "interval-sec", "mounts"},
    )
    marker_present = "marker" in readiness
    url_present = "url" in readiness
    if marker_present == url_present:
        _fail(readiness_path, "requires exactly one of marker or url")
    timeout_sec = _integer(
        _required(readiness, "timeout-sec", readiness_path),
        f"{readiness_path}.timeout-sec",
        minimum=1,
    )
    interval_sec = _integer(
        _required(readiness, "interval-sec", readiness_path),
        f"{readiness_path}.interval-sec",
        minimum=1,
    )
    if interval_sec > timeout_sec:
        _fail(
            f"{readiness_path}.interval-sec",
            "cannot exceed timeout-sec",
        )
    if marker_present:
        marker = _string(readiness["marker"], f"{readiness_path}.marker")
        if (
            not marker.startswith("/run/")
            or posixpath.normpath(marker) != marker
            or any(character.isspace() for character in marker)
        ):
            _fail(
                f"{readiness_path}.marker",
                "must be a normalized path below /run without whitespace",
            )
        readiness_spec: ReadinessSpec = MarkerReadiness(
            marker,
            timeout_sec,
            interval_sec,
            _parse_required_mounts(readiness.get("mounts"), name),
        )
    else:
        if "mounts" in readiness:
            _fail(
                f"{readiness_path}.mounts",
                "is supported only with marker readiness",
            )
        url = _string(readiness["url"], f"{readiness_path}.url")
        try:
            parsed_url = urlsplit(url)
            hostname = parsed_url.hostname
        except ValueError:
            _fail(
                f"{readiness_path}.url",
                "must be a valid HTTP(S) URL",
            )
        if (
            parsed_url.scheme not in {"http", "https"}
            or hostname is None
            or parsed_url.username is not None
            or parsed_url.password is not None
            or any(character.isspace() for character in url)
        ):
            _fail(
                f"{readiness_path}.url",
                "must be an HTTP(S) URL with a host and no credentials or whitespace",
            )
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
    if (
        container.ports
        and container.network == "host"
        and not isinstance(krun, KrunTap)
    ):
        _fail(name, '[container].ports cannot be used with network = "host"')
    return Service(
        source=toml_path,
        info=info,
        host=host,
        container=container,
        krun=krun,
        data=_parse_data(top.get("data"), name),
        assets=_parse_assets(top.get("assets"), name),
        startup=_parse_startup(top.get("startup"), name, container),
        unit=_parse_unit(top.get("unit"), name),
    )
