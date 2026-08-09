"""Typed domain model and fleet-wide invariants for rootless services."""

from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from types import MappingProxyType
from typing import Literal, Mapping, NoReturn, TypeAlias


SUBID_COUNT = 65536
TAP_NAME_RE = re.compile(r"^krun-[0-9]{5}$")


class ConfigError(ValueError):
    """Raised when a service or fleet configuration violates its contract."""


class Protocol(str, Enum):
    TCP = "tcp"
    UDP = "udp"


class KrunNetwork(str, Enum):
    TSI = "tsi"
    PASST = "passt"
    TAP = "tap"


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
class DataSpec:
    path: str
    mode: str = "0750"
    subdirectories: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class AssetsSpec:
    path: str


@dataclass(frozen=True, slots=True)
class RequiredMount:
    path: str
    source: str


@dataclass(frozen=True, slots=True)
class MarkerReadiness:
    marker: str
    timeout_sec: int
    interval_sec: int
    mounts: tuple[RequiredMount, ...] = ()


@dataclass(frozen=True, slots=True)
class HttpReadiness:
    url: str
    timeout_sec: int
    interval_sec: int


ReadinessSpec: TypeAlias = MarkerReadiness | HttpReadiness


@dataclass(frozen=True, slots=True)
class StartupSpec:
    readiness: ReadinessSpec | None = None
    reject_published_tcp_ports: bool = False


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
    data: DataSpec | None = None
    assets: AssetsSpec | None = None
    startup: StartupSpec = field(default_factory=StartupSpec)
    unit: UnitSpec = field(default_factory=UnitSpec)

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


def _validate_fleet(services: tuple[Service, ...]) -> None:
    seen: dict[tuple[str, object], str] = {}
    ranges: list[tuple[int, int, str]] = []
    tap_networks: dict[ipaddress.IPv4Network, str] = {}
    tap_publications: dict[tuple[int, Protocol], str] = {}
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
        if not service.active_tap:
            continue
        tap = service.tap_spec
        network = tap.ipv4.network
        if network in tap_networks:
            _fail(name, f"TAP subnet {network} is also used by {tap_networks[network]}")
        tap_networks[network] = name
        declared_ports = {port.container_port for port in service.container.ports}
        for rule in tap.ingress:
            if rule.source not in tap_names:
                _fail(name, f"unknown TAP source service {rule.source!r}")
            unknown_ports = sorted(set(rule.ports) - declared_ports)
            if unknown_ports:
                _fail(
                    name,
                    "TAP ingress ports must also be declared in "
                    "[[container.ports]]: " + ", ".join(map(str, unknown_ports)),
                )
        for port in service.container.ports:
            publication_key = (port.host_port, port.protocol)
            if publication_key in tap_publications:
                _fail(
                    name,
                    f"host {port.protocol.value} port {port.host_port} is also "
                    f"published by {tap_publications[publication_key]}",
                )
            tap_publications[publication_key] = name
        if not any(
            port.protocol is Protocol.TCP
            and port.container_port == tap.probe_port
            for port in service.container.ports
        ):
            _fail(
                name,
                "[krun].probe-port must reference a declared TCP container port",
            )

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
