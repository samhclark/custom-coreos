"""Typed domain model and fleet-wide invariants for rootless services."""

from __future__ import annotations

import ipaddress
import posixpath
import re
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from types import MappingProxyType
from typing import Literal, Mapping, NoReturn, TypeAlias
from urllib.parse import urlsplit

from .errors import ConfigError
from .storage_model import (
    DirectoryStorage,
    ExistingZfsStorage,
    ManagedZfsStorage,
    StorageSpec,
)


SUBID_COUNT = 65536
TAP_NAME_RE = re.compile(r"^krun-[0-9]{5}$")
NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
USERNAME_RE = re.compile(r"^_nas_[a-z0-9]{1,26}$")
PINNED_IMAGE_RE = re.compile(r"^[^@\s]+:[^@:\s]+@sha256:[0-9a-f]{64}$")
SECRET_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
DISPLAY_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]*$")
ENVIRONMENT_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
PORTABLE_ABSOLUTE_PATH_RE = re.compile(
    r"^/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$"
)
VOLUME_OPTIONS_RE = re.compile(
    r"^[A-Za-z0-9._=-]+(?:,[A-Za-z0-9._=-]+)*$"
)
ZFS_SOURCE_RE = re.compile(r"^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$")
EXEC_RE = re.compile(
    r"^[A-Za-z0-9_./:=,@+-]+(?: [A-Za-z0-9_./:=,@+-]+)*$"
)
MAX_SUBID_START = 2**32 - SUBID_COUNT


class Protocol(str, Enum):
    TCP = "tcp"
    UDP = "udp"


class KrunNetwork(str, Enum):
    TSI = "tsi"
    PASST = "passt"
    TAP = "tap"


class PathAccess(str, Enum):
    READ = "read"
    WRITE = "write"
    EXECUTE = "execute"


class RequiredOwner(str, Enum):
    SERVICE = "service"


@dataclass(frozen=True, slots=True)
class ServiceInfo:
    name: str
    description: str
    documentation: str | None = None


@dataclass(frozen=True, slots=True)
class HostIdentity:
    username: str
    uid: int
    subid_start: int
    display_name: str

    @property
    def slug(self) -> str:
        return self.username.removeprefix("_nas_")


@dataclass(frozen=True, slots=True)
class PublishedPort:
    host_address: ipaddress.IPv4Address | ipaddress.IPv6Address
    host_port: int
    container_port: int
    protocol: Protocol = Protocol.TCP

    @property
    def host(self) -> str:
        address = str(self.host_address)
        if isinstance(self.host_address, ipaddress.IPv6Address):
            address = f"[{address}]"
        return f"{address}:{self.host_port}"


@dataclass(frozen=True, slots=True)
class VolumeMount:
    source: str
    target: str
    options: str | None = None
    comment: str | None = None


@dataclass(frozen=True, slots=True)
class SecretMount:
    name: str
    target: str | None = None


@dataclass(frozen=True, slots=True)
class ContainerSpec:
    image: str
    enabled: bool = True
    network: Literal["host"] | None = None
    container_user: int | None = None
    health_cmd: Literal["none"] | None = None
    dns: tuple[ipaddress.IPv4Address | ipaddress.IPv6Address, ...] = ()
    sysctls: tuple[str, ...] = ()
    environment: tuple[tuple[str, str], ...] = ()
    volumes: tuple[VolumeMount, ...] = ()
    secrets: tuple[SecretMount, ...] = ()
    ports: tuple[PublishedPort, ...] = ()
    exec: str | None = None


@dataclass(frozen=True, slots=True)
class IngressRule:
    source: str
    ports: tuple[int, ...]


@dataclass(frozen=True, slots=True)
class KrunTsi:
    cpus: int
    ram_mib: int
    network: Literal[KrunNetwork.TSI] = field(
        default=KrunNetwork.TSI,
        init=False,
    )


@dataclass(frozen=True, slots=True)
class KrunPasst:
    cpus: int
    ram_mib: int
    network: Literal[KrunNetwork.PASST] = field(
        default=KrunNetwork.PASST,
        init=False,
    )


@dataclass(frozen=True, slots=True)
class KrunTap:
    cpus: int
    ram_mib: int
    ipv4: ipaddress.IPv4Interface
    probe_port: int
    ingress: tuple[IngressRule, ...] = ()
    host_access: tuple[int, ...] = ()
    network: Literal[KrunNetwork.TAP] = field(
        default=KrunNetwork.TAP,
        init=False,
    )


KrunSpec: TypeAlias = KrunTsi | KrunPasst | KrunTap


@dataclass(frozen=True, slots=True)
class AssetsSpec:
    path: str


@dataclass(frozen=True, slots=True)
class RequiredPath:
    path: str
    mount_source: str | None = None
    owner: RequiredOwner | None = None
    access: tuple[PathAccess, ...] = ()


@dataclass(frozen=True, slots=True)
class MarkerReadiness:
    marker: str
    timeout_sec: int
    interval_sec: int
    paths: tuple[RequiredPath, ...] = ()


@dataclass(frozen=True, slots=True)
class HttpReadiness:
    url: str
    timeout_sec: int
    interval_sec: int


ReadinessSpec: TypeAlias = MarkerReadiness | HttpReadiness


@dataclass(frozen=True, slots=True)
class StartupSpec:
    readiness: ReadinessSpec | None = None
    require_published_tcp_ports_free: bool = False


@dataclass(frozen=True, slots=True)
class UnitSpec:
    restart_sec: int = 30
    timeout_start_sec: int | None = None


@dataclass(frozen=True, slots=True)
class Service:
    source: Path
    info: ServiceInfo
    host: HostIdentity
    container: ContainerSpec
    krun: KrunSpec | None = None
    storage: tuple[StorageSpec, ...] = ()
    assets: AssetsSpec | None = None
    startup: StartupSpec = field(default_factory=StartupSpec)
    unit: UnitSpec = field(default_factory=UnitSpec)

    def __post_init__(self) -> None:
        _validate_service(self)

    @property
    def active_tap(self) -> bool:
        return self.container.enabled and isinstance(self.krun, KrunTap)

    @property
    def tap_spec(self) -> KrunTap:
        if not self.active_tap or not isinstance(self.krun, KrunTap):
            raise ConfigError(f"{self.source.name}: service has no active TAP")
        return self.krun

    @property
    def tap_name(self) -> str:
        name = f"krun-{self.host.uid}"
        if not TAP_NAME_RE.fullmatch(name):
            raise ConfigError(f"{self.source.name}: generated invalid TAP name {name!r}")
        return name

    @property
    def tap_guest(self) -> ipaddress.IPv4Interface:
        return self.tap_spec.ipv4

    @property
    def tap_gateway(self) -> ipaddress.IPv4Interface:
        guest = self.tap_guest
        gateway = ipaddress.ip_interface(
            f"{guest.network.network_address + 1}/{guest.network.prefixlen}"
        )
        assert isinstance(gateway, ipaddress.IPv4Interface)
        return gateway


@dataclass(frozen=True, slots=True)
class Fleet:
    services: tuple[Service, ...]

    def __post_init__(self) -> None:
        if any(not isinstance(service, Service) for service in self.services):
            _fail("fleet.services", "must contain only Service instances")
        ordered = tuple(sorted(self.services, key=lambda service: service.host.uid))
        object.__setattr__(self, "services", ordered)
        _validate_fleet(ordered)

    @classmethod
    def build(cls, services: list[Service] | tuple[Service, ...]) -> Fleet:
        return cls(tuple(services))

    @property
    def active_taps(self) -> tuple[Service, ...]:
        return tuple(service for service in self.services if service.active_tap)

    @property
    def taps_by_name(self) -> Mapping[str, Service]:
        return MappingProxyType(
            {service.info.name: service for service in self.active_taps}
        )


def _fail(path: str, message: str) -> NoReturn:
    raise ConfigError(f"{path}: {message}")


def _validate_string(value: str, path: str, *, allow_empty: bool = False) -> None:
    if not isinstance(value, str) or (not allow_empty and not value):
        _fail(path, "must be a string")
    if any(not character.isprintable() for character in value):
        _fail(path, "cannot contain control characters")


def _validate_unit_line(value: str, path: str) -> None:
    _validate_string(value, path)
    if any(character in '\\%"' for character in value):
        _fail(path, "cannot contain double quotes, backslashes, or percent signs")


def _validate_unit_atom(
    value: str,
    path: str,
    *,
    allow_empty: bool = False,
) -> None:
    _validate_string(value, path, allow_empty=allow_empty)
    if any(character.isspace() for character in value) or any(
        character in "\"'$\\%" for character in value
    ):
        _fail(
            path,
            "cannot contain whitespace, quotes, dollar signs, backslashes, "
            "or percent signs",
        )


def _validate_absolute_path(value: str, path: str) -> None:
    _validate_string(value, path)
    if (
        not PORTABLE_ABSOLUTE_PATH_RE.fullmatch(value)
        or posixpath.normpath(value) != value
    ):
        _fail(
            path,
            "must be a normalized absolute path with portable path segments",
        )


def _validate_http_url(value: str, path: str) -> None:
    _validate_unit_atom(value, path)
    try:
        parsed_url = urlsplit(value)
        hostname = parsed_url.hostname
        _ = parsed_url.port
    except ValueError:
        _fail(path, "must be a valid HTTP(S) URL")
    if (
        parsed_url.scheme not in {"http", "https"}
        or hostname is None
        or parsed_url.username is not None
        or parsed_url.password is not None
    ):
        _fail(path, "must be an HTTP(S) URL with a host and no credentials")


def _validate_integer(
    value: int,
    path: str,
    *,
    minimum: int,
    maximum: int | None = None,
) -> None:
    if type(value) is not int or value < minimum:
        _fail(path, f"must be at least {minimum}")
    if maximum is not None and value > maximum:
        _fail(path, f"must be at most {maximum}")


def _validate_port(value: int, path: str) -> None:
    _validate_integer(value, path, minimum=1, maximum=65535)


def _validate_service_info(service: Service) -> None:
    info = service.info
    path = f"{service.source.name}: [service]"
    _validate_string(info.name, f"{path}.name")
    if not NAME_RE.fullmatch(info.name):
        _fail(f"{path}.name", f"must match {NAME_RE.pattern}")
    _validate_unit_line(info.description, f"{path}.description")
    if info.documentation is not None:
        _validate_http_url(info.documentation, f"{path}.documentation")
    expected_filename = f"{info.name}.toml"
    if service.source.name != expected_filename:
        _fail(
            service.source.name,
            f"filename must be {expected_filename!r} for service {info.name!r}",
        )


def _validate_host(service: Service) -> None:
    host = service.host
    path = f"{service.source.name}: [host]"
    _validate_string(host.username, f"{path}.username")
    if not USERNAME_RE.fullmatch(host.username):
        _fail(f"{path}.username", f"must match {USERNAME_RE.pattern}")
    _validate_integer(host.uid, f"{path}.uid", minimum=51000, maximum=51999)
    _validate_integer(
        host.subid_start,
        f"{path}.subid-start",
        minimum=1,
        maximum=MAX_SUBID_START,
    )
    _validate_string(host.display_name, f"{path}.display-name")
    if not DISPLAY_NAME_RE.fullmatch(host.display_name):
        _fail(f"{path}.display-name", f"must match {DISPLAY_NAME_RE.pattern}")


def _validate_published_ports(service: Service) -> None:
    path = f"{service.source.name}: [container].ports"
    seen = set()
    for index, port in enumerate(service.container.ports, start=1):
        item_path = f"{path}[{index}]"
        if not isinstance(
            port.host_address,
            (ipaddress.IPv4Address, ipaddress.IPv6Address),
        ):
            _fail(f"{item_path}.host", "must contain an IP address")
        _validate_port(port.host_port, f"{item_path}.host port")
        _validate_port(port.container_port, f"{item_path}.container")
        if not isinstance(port.protocol, Protocol):
            _fail(f"{item_path}.protocol", 'must be "tcp" or "udp"')
        key = (port.host_address, port.host_port, port.protocol)
        if key in seen:
            _fail(item_path, f"duplicate published port {port.host}")
        seen.add(key)


def _validate_container(service: Service) -> None:
    container = service.container
    path = f"{service.source.name}: [container]"
    _validate_unit_atom(container.image, f"{path}.image")
    if not PINNED_IMAGE_RE.fullmatch(container.image):
        _fail(f"{path}.image", "must use an immutable name:tag@sha256 digest")
    if type(container.enabled) is not bool:
        _fail(f"{path}.enabled", "must be a boolean")
    if container.network not in {None, "host"}:
        _fail(f"{path}.network", 'currently supports only "host"')
    if container.container_user is not None:
        _validate_integer(
            container.container_user,
            f"{path}.container-user",
            minimum=0,
        )
    if container.health_cmd not in {None, "none"}:
        _fail(f"{path}.health-cmd", 'currently supports only "none"')

    if len(set(container.dns)) != len(container.dns):
        _fail(f"{path}.dns", "contains duplicate DNS servers")
    for index, server in enumerate(container.dns, start=1):
        if not isinstance(
            server,
            (ipaddress.IPv4Address, ipaddress.IPv6Address),
        ):
            _fail(f"{path}.dns[{index}]", "must be an IP address")

    seen_sysctls = set()
    for sysctl in container.sysctls:
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)=([^=]+)", sysctl)
        if match is None:
            _fail(f"{path}.sysctls", f"{sysctl!r} must use name=value format")
        _validate_unit_atom(match.group(2), f"{path}.sysctls")
        if sysctl in seen_sysctls:
            _fail(f"{path}.sysctls", f"duplicate sysctl {sysctl!r}")
        seen_sysctls.add(sysctl)

    environment_path = f"{service.source.name}: [container.environment]"
    seen_environment = set()
    for name, value in container.environment:
        if not ENVIRONMENT_NAME_RE.fullmatch(name):
            _fail(
                f"{environment_path} key",
                f"must match {ENVIRONMENT_NAME_RE.pattern}",
            )
        _validate_unit_atom(
            value,
            f"{environment_path}.{name}",
            allow_empty=True,
        )
        if name in seen_environment:
            _fail(environment_path, f"duplicate variable {name!r}")
        seen_environment.add(name)

    for index, volume in enumerate(container.volumes, start=1):
        item_path = f"{path}.volumes[{index}]"
        _validate_absolute_path(volume.source, f"{item_path}.source")
        _validate_absolute_path(volume.target, f"{item_path}.target")
        if volume.source.startswith("/var/"):
            _fail(
                f"{item_path}.source",
                "mutable /var volumes must use [[storage]]",
            )
        if volume.options is not None:
            _validate_string(volume.options, f"{item_path}.options")
            if not VOLUME_OPTIONS_RE.fullmatch(volume.options):
                _fail(
                    f"{item_path}.options",
                    f"must match {VOLUME_OPTIONS_RE.pattern}",
                )
        if volume.comment is not None:
            _validate_string(volume.comment, f"{item_path}.comment")

    seen_secrets = set()
    for index, secret in enumerate(container.secrets, start=1):
        item_path = f"{path}.secrets[{index}]"
        _validate_string(secret.name, f"{item_path}.name")
        if not SECRET_NAME_RE.fullmatch(secret.name):
            _fail(f"{item_path}.name", f"must match {SECRET_NAME_RE.pattern}")
        if secret.name in seen_secrets:
            _fail(item_path, f"duplicate secret {secret.name!r}")
        seen_secrets.add(secret.name)
        if secret.target is not None:
            _validate_absolute_path(secret.target, f"{item_path}.target")

    _validate_published_ports(service)
    if container.exec is not None:
        _validate_string(container.exec, f"{path}.exec")
        if not EXEC_RE.fullmatch(container.exec):
            _fail(
                f"{path}.exec",
                "must be a space-separated list of safe argument atoms",
            )


def _validate_krun(service: Service) -> None:
    krun = service.krun
    if krun is None:
        return
    path = f"{service.source.name}: [krun]"
    _validate_integer(krun.cpus, f"{path}.cpus", minimum=1)
    _validate_integer(krun.ram_mib, f"{path}.ram-mib", minimum=128)
    if service.container.network == "host":
        for server in service.container.dns:
            if server.is_loopback:
                _fail(
                    path,
                    'network = "host" cannot use loopback DNS server '
                    f"{str(server)!r}",
                )
    if isinstance(krun, KrunPasst):
        if service.container.network == "host":
            _fail(
                path,
                'network = "passt" requires a private container network namespace',
            )
        return
    if isinstance(krun, KrunTsi):
        return
    if not isinstance(krun, KrunTap):
        _fail(path, "has an unsupported network implementation")
    if service.container.network != "host":
        _fail(path, 'network = "tap" requires [container].network = "host"')
    if not isinstance(krun.ipv4, ipaddress.IPv4Interface):
        _fail(f"{path}.ipv4", "must be an IPv4 interface address")
    if krun.ipv4.network.prefixlen != 30:
        _fail(f"{path}.ipv4", "must use a dedicated IPv4 /30")
    if krun.ipv4.ip != krun.ipv4.network.network_address + 2:
        _fail(f"{path}.ipv4", "must be the second usable /30 address")
    _validate_port(krun.probe_port, f"{path}.probe-port")
    if not any(
        port.protocol is Protocol.TCP
        and port.container_port == krun.probe_port
        for port in service.container.ports
    ):
        _fail(
            f"{path}.probe-port",
            "must reference a declared TCP container port",
        )
    for port in service.container.ports:
        if str(port.host_address) not in {"127.0.0.1", "0.0.0.0"}:
            _fail(
                path,
                'TAP host publications support only "127.0.0.1" or '
                '"0.0.0.0" addresses',
            )

    seen_ingress = set()
    declared_tcp_ports = {
        port.container_port
        for port in service.container.ports
        if port.protocol is Protocol.TCP
    }
    for index, rule in enumerate(krun.ingress, start=1):
        item_path = f"{path}.ingress[{index}]"
        if not NAME_RE.fullmatch(rule.source):
            _fail(f"{item_path}.from", "must be a service name")
        if not rule.ports:
            _fail(f"{item_path}.ports", "must contain TCP ports")
        for port in rule.ports:
            _validate_port(port, f"{item_path}.ports")
        if len(set(rule.ports)) != len(rule.ports):
            _fail(f"{item_path}.ports", "contains duplicates")
        key = (rule.source, rule.ports)
        if key in seen_ingress:
            _fail(item_path, "duplicate ingress rule")
        seen_ingress.add(key)
        unknown_ports = sorted(set(rule.ports) - declared_tcp_ports)
        if unknown_ports:
            _fail(
                item_path,
                "TAP ingress ports must also be declared TCP ports in "
                "[[container.ports]]: " + ", ".join(map(str, unknown_ports)),
            )
    for port in krun.host_access:
        _validate_port(port, f"{path}.host-access")
    if len(set(krun.host_access)) != len(krun.host_access):
        _fail(f"{path}.host-access", "contains duplicates")


def _validate_assets(service: Service) -> None:
    if service.assets is not None:
        path = f"{service.source.name}: [assets].path"
        _validate_absolute_path(service.assets.path, path)
        expected = f"/usr/share/custom-coreos/{service.info.name}"
        if service.assets.path != expected:
            _fail(path, f"must be exactly {expected}")


def _validate_startup(service: Service) -> None:
    startup = service.startup
    path = f"{service.source.name}: [startup]"
    if type(startup.require_published_tcp_ports_free) is not bool:
        _fail(f"{path}.require-published-tcp-ports-free", "must be a boolean")
    if startup.require_published_tcp_ports_free and not any(
        port.protocol is Protocol.TCP for port in service.container.ports
    ):
        _fail(
            f"{path}.require-published-tcp-ports-free",
            "requires at least one published TCP port",
        )
    readiness = startup.readiness
    if readiness is None:
        return
    readiness_path = f"{service.source.name}: [startup.readiness]"
    _validate_integer(
        readiness.timeout_sec,
        f"{readiness_path}.timeout-sec",
        minimum=1,
    )
    _validate_integer(
        readiness.interval_sec,
        f"{readiness_path}.interval-sec",
        minimum=1,
    )
    if readiness.interval_sec > readiness.timeout_sec:
        _fail(f"{readiness_path}.interval-sec", "cannot exceed timeout-sec")
    if isinstance(readiness, HttpReadiness):
        _validate_http_url(readiness.url, f"{readiness_path}.url")
        return
    if not isinstance(readiness, MarkerReadiness):
        _fail(readiness_path, "has an unsupported readiness implementation")
    _validate_absolute_path(readiness.marker, f"{readiness_path}.marker")
    if not readiness.marker.startswith("/run/"):
        _fail(f"{readiness_path}.marker", "must be below /run")
    seen_paths = set()
    for index, required_path in enumerate(readiness.paths, start=1):
        item_path = (
            f"{service.source.name}: [[startup.readiness.paths]][{index}]"
        )
        _validate_absolute_path(required_path.path, f"{item_path}.path")
        if required_path.path in seen_paths:
            _fail(item_path, "duplicates an earlier path requirement")
        seen_paths.add(required_path.path)
        if required_path.mount_source is not None:
            _validate_string(
                required_path.mount_source,
                f"{item_path}.mount-source",
            )
            if not ZFS_SOURCE_RE.fullmatch(required_path.mount_source):
                _fail(
                    f"{item_path}.mount-source",
                    "must be a portable filesystem source name",
                )
        if required_path.owner not in {None, RequiredOwner.SERVICE}:
            _fail(f"{item_path}.owner", "must be 'service'")
        if any(not isinstance(access, PathAccess) for access in required_path.access):
            _fail(
                f"{item_path}.access",
                "must contain only read, write, or execute",
            )
        if len(set(required_path.access)) != len(required_path.access):
            _fail(f"{item_path}.access", "contains duplicates")


def _validate_unit(service: Service) -> None:
    path = f"{service.source.name}: [unit]"
    _validate_integer(service.unit.restart_sec, f"{path}.restart-sec", minimum=0)
    if service.unit.timeout_start_sec is not None:
        _validate_integer(
            service.unit.timeout_start_sec,
            f"{path}.timeout-start-sec",
            minimum=1,
        )


def _validate_service(service: Service) -> None:
    """Validate every local invariant required by compilers and renderers."""
    if not isinstance(service.source, Path):
        _fail("service.source", "must be a pathlib.Path")
    for field_name, value, expected_type in (
        ("info", service.info, ServiceInfo),
        ("host", service.host, HostIdentity),
        ("container", service.container, ContainerSpec),
        ("startup", service.startup, StartupSpec),
        ("unit", service.unit, UnitSpec),
    ):
        if not isinstance(value, expected_type):
            _fail(f"service.{field_name}", f"must be {expected_type.__name__}")
    if not isinstance(service.storage, tuple) or any(
        not isinstance(
            storage,
            (DirectoryStorage, ManagedZfsStorage, ExistingZfsStorage),
        )
        for storage in service.storage
    ):
        _fail("service.storage", "must contain only supported storage contracts")
    if service.storage and service.startup.readiness is not None:
        _fail(
            service.source.name,
            "[[storage]] owns startup readiness; remove [startup.readiness]",
        )
    if service.assets is not None and not isinstance(service.assets, AssetsSpec):
        _fail("service.assets", "must be AssetsSpec")
    if service.krun is not None and not isinstance(
        service.krun,
        (KrunTsi, KrunPasst, KrunTap),
    ):
        _fail("service.krun", "must be a supported krun specification")
    _validate_service_info(service)
    for storage in service.storage:
        if isinstance(storage, ManagedZfsStorage):
            expected_prefix = f"tank/{service.info.name}/"
            if not storage.dataset.startswith(expected_prefix):
                _fail(
                    f"{service.source.name}: storage[{storage.name}].dataset",
                    f"managed datasets must be below {expected_prefix}",
                )
        elif isinstance(storage, ExistingZfsStorage):
            if storage.dataset != "tank/videos":
                _fail(
                    f"{service.source.name}: storage[{storage.name}].dataset",
                    "the only allowed shared existing dataset is tank/videos",
                )
        for export in storage.exports:
            if any(
                volume.target == export.container_path
                for volume in service.container.volumes
            ):
                _fail(
                    f"{service.source.name}: storage[{storage.name}].exports",
                    f"container path {export.container_path!r} is also a raw volume",
                )
    _validate_host(service)
    _validate_container(service)
    _validate_krun(service)
    if (
        service.container.ports
        and service.container.network == "host"
        and not isinstance(service.krun, KrunTap)
    ):
        _fail(
            service.source.name,
            '[container].ports cannot be used with network = "host"',
        )
    _validate_assets(service)
    _validate_startup(service)
    _validate_unit(service)


def _validate_fleet(services: tuple[Service, ...]) -> None:
    seen: dict[tuple[str, object], str] = {}
    ranges: list[tuple[int, int, str]] = []
    tap_networks: dict[ipaddress.IPv4Network, str] = {}
    host_publications: dict[tuple[int, Protocol], str] = {}
    tap_names = {service.info.name for service in services if service.active_tap}

    for service in services:
        name = service.source.name
        for key, value in (
            ("service name", service.info.name),
            ("username", service.host.username),
            ("uid", service.host.uid),
        ):
            identity = (key, value)
            if identity in seen:
                _fail(
                    name,
                    f"duplicate {key} {value!r} (also in {seen[identity]})",
                )
            seen[identity] = name
        ranges.append(
            (service.host.subid_start, service.host.subid_start + SUBID_COUNT, name)
        )
        for storage in service.storage:
            for resource_kind, resource_value in (
                ("storage host path", storage.host_path),
                (
                    "ZFS dataset",
                    storage.dataset
                    if isinstance(
                        storage,
                        (ManagedZfsStorage, ExistingZfsStorage),
                    )
                    else None,
                ),
            ):
                if resource_value is None:
                    continue
                resource = (resource_kind, resource_value)
                if resource in seen:
                    _fail(
                        name,
                        f"duplicate {resource_kind} {resource_value!r} "
                        f"(also in {seen[resource]})",
                    )
                seen[resource] = name
        if service.container.enabled:
            for port in service.container.ports:
                publication_key = (port.host_port, port.protocol)
                if publication_key in host_publications:
                    _fail(
                        name,
                        f"host {port.protocol.value} port {port.host_port} is also "
                        f"published by {host_publications[publication_key]}",
                    )
                host_publications[publication_key] = name
        if not service.active_tap:
            continue
        tap = service.tap_spec
        network = tap.ipv4.network
        if network in tap_networks:
            _fail(name, f"TAP subnet {network} is also used by {tap_networks[network]}")
        tap_networks[network] = name
        for rule in tap.ingress:
            if rule.source not in tap_names:
                _fail(name, f"unknown TAP source service {rule.source!r}")

    ranges.sort()
    for (_, previous_end, previous_name), (
        current_start,
        _,
        current_name,
    ) in zip(ranges, ranges[1:]):
        if current_start < previous_end:
            _fail(
                "fleet",
                "subordinate ID ranges overlap between "
                f"{previous_name} and {current_name}",
            )
    if not tap_names:
        _fail("fleet", "must contain at least one active TAP service")
