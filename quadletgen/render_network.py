"""Render fleet-wide libkrun TAP networking artifacts."""

from __future__ import annotations

from .headers import generated_header
from .model import Fleet, Service


KRUN_DNS_SERVERS = ("100.100.100.100", "75.75.75.75", "75.75.76.76")
def fleet_header(name: str) -> str:
    return generated_header(name)


def networkd_netdev(service: Service) -> str:
    return f"""{_service_header(service)}
[NetDev]
Name={service.tap_name}
Kind=tap

[Tap]
User={service.host.username}
Group={service.host.username}
VNetHeader=yes
"""


def networkd_network(service: Service) -> str:
    gateway = service.tap_gateway
    return f"""{_service_header(service)}
[Match]
Name={service.tap_name}

[Link]
RequiredForOnline=no

[Network]
Address={gateway}
DHCPServer=yes
ConfigureWithoutCarrier=yes
IPv4RouteLocalnet=yes
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPServer]
PoolOffset=2
PoolSize=1
PersistLeases=runtime
RapidCommit=yes
EmitDNS=yes
DNS={' '.join(KRUN_DNS_SERVERS)}
EmitNTP=no
EmitSIP=no
EmitRouter=yes
Router={gateway.ip}
"""


def nft_filter(fleet: Fleet) -> str:
    taps = fleet.active_taps
    tap_exclusions = " ".join(
        f'iifname != "{service.tap_name}"' for service in taps
    )
    out_exclusions = " ".join(
        f'oifname != "{service.tap_name}"' for service in taps
    )
    by_name = fleet.taps_by_name
    lines = [fleet_header("TAP fleet filter"), "chain nas_krun_input {"]
    for service in taps:
        tap = service.tap_spec
        lines.append(
            f'    iifname "{service.tap_name}" udp sport 68 udp dport 67 accept'
        )
        lines.append(
            f'    iifname "{service.tap_name}" ip saddr != '
            f"{service.tap_guest.ip} drop"
        )
        lines.append(
            f'    iifname "{service.tap_name}" ip saddr '
            f"{service.tap_guest.ip} ct state established,related accept"
        )
        for host_port in tap.host_access:
            lines.append(
                f'    iifname "{service.tap_name}" ip saddr '
                f"{service.tap_guest.ip} ip daddr {service.tap_gateway.ip} "
                f"tcp dport {host_port} accept"
            )
        lines.append(f'    iifname "{service.tap_name}" drop')
    lines += ["}", "", "chain nas_krun_forward {"]
    for service in taps:
        lines.append(
            f'    iifname "{service.tap_name}" ip saddr != '
            f"{service.tap_guest.ip} drop"
        )
        lines.append(
            f'    oifname "{service.tap_name}" ip daddr != '
            f"{service.tap_guest.ip} drop"
        )
    lines.append("    ct state established,related accept")
    for destination in taps:
        ports_by_consumer: dict[str, list[int]] = {}
        for endpoint in destination.container.endpoints:
            for consumer in endpoint.consumers:
                ports_by_consumer.setdefault(consumer, []).append(endpoint.port)
        for consumer, ports in ports_by_consumer.items():
            source = by_name[consumer]
            rendered_ports = ", ".join(str(port) for port in ports)
            lines.append(
                f'    iifname "{source.tap_name}" '
                f'oifname "{destination.tap_name}" '
                f"ip saddr {source.tap_guest.ip} "
                f"ip daddr {destination.tap_guest.ip} "
                f"tcp dport {{ {rendered_ports} }} accept"
            )
    for service in taps:
        for endpoint in service.container.endpoints:
            if str(endpoint.host_address) != "0.0.0.0":
                continue
            lines.append(
                f"    {tap_exclusions} oifname \"{service.tap_name}\" "
                f"ip daddr {service.tap_guest.ip} {endpoint.protocol.value} "
                f"dport {endpoint.port} accept"
            )
    for service in taps:
        lines.append(
            f'    iifname "{service.tap_name}" ip saddr '
            f"{service.tap_guest.ip} {out_exclusions} accept"
        )
    lines += ["}", ""]
    return "\n".join(lines)


def networkd_dependencies(fleet: Fleet) -> str:
    account_units = [
        f"ensure-nas-{service.host.slug}-account.service"
        for service in fleet.active_taps
    ]
    return "\n".join(
        [
            fleet_header("networkd TAP dependencies"),
            "[Unit]",
            f"After={' '.join(account_units)}",
            "Wants=nas-krun-network-policy.service",
            "",
        ]
    )


def network_policy_script(fleet: Fleet) -> str:
    taps = fleet.active_taps
    tap_names = " ".join(f'"{service.tap_name}"' for service in taps)
    gateways = " ".join(f'"{service.tap_gateway}"' for service in taps)
    user_units = " ".join(
        f'"user@{service.host.uid}.service"' for service in taps
    )
    wait_interfaces = " ".join(
        f'--interface="{service.tap_name}:off"' for service in taps
    )
    return fr"""#!/bin/bash
{fleet_header("TAP network policy readiness")}

set -euo pipefail

READY_DIR=/run/nas-krun-network
READY_FILE="${{READY_DIR}}/policy-ready"
TAPS=({tap_names})
GATEWAYS=({gateways})
USER_UNITS=({user_units})

clear_readiness() {{
    rm -f "${{READY_FILE}}" "${{READY_FILE}}.tmp"
}}

quiesce_guests() {{
    clear_readiness
    systemctl stop "${{USER_UNITS[@]}}"
    for unit in "${{USER_UNITS[@]}}"; do
        if systemctl is-active --quiet "${{unit}}"; then
            echo "Refusing to remove krun network policy while ${{unit}} is active" >&2
            return 1
        fi
    done
}}

publish_readiness() {{
    trap 'clear_readiness' ERR
    trap 'clear_readiness; exit 1' HUP INT TERM
    install -d -o root -g root -m 0755 "${{READY_DIR}}"
    clear_readiness

    /usr/lib/systemd/systemd-networkd-wait-online --quiet --timeout=60 \
        --ipv4 {wait_interfaces}

    for index in "${{!TAPS[@]}}"; do
        ip -4 -o address show dev "${{TAPS[$index]}}" \
            | grep -Fq " ${{GATEWAYS[$index]}} "
    done

    nft list chain inet filter nas_krun_input >/dev/null
    nft list chain inet filter nas_krun_forward >/dev/null
    nft list table ip nas_krun_nat >/dev/null

    printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id)" \
        > "${{READY_FILE}}.tmp"
    chown root:root "${{READY_FILE}}.tmp"
    chmod 0644 "${{READY_FILE}}.tmp"
    mv -f "${{READY_FILE}}.tmp" "${{READY_FILE}}"
    systemctl start --no-block "${{USER_UNITS[@]}}"
    trap - ERR HUP INT TERM
}}

case "${{1:-}}" in
    publish)
        publish_readiness
        ;;
    quiesce)
        quiesce_guests
        ;;
    quiesce-and-flush)
        quiesce_guests
        nft flush ruleset
        ;;
    *)
        echo "usage: $0 publish|quiesce|quiesce-and-flush" >&2
        exit 2
        ;;
esac
"""


def network_policy_unit(fleet: Fleet) -> str:
    account_units = [
        f"ensure-nas-{service.host.slug}-account.service"
        for service in fleet.active_taps
    ]
    accounts = " ".join(account_units)
    return "\n".join(
        [
            fleet_header("TAP network policy service"),
            "[Unit]",
            "Description=Publish fail-closed readiness for the libkrun TAP network",
            "Requires=nftables.service systemd-networkd.service",
            f"Requires={accounts}",
            "BindsTo=nftables.service systemd-networkd.service",
            "PartOf=nftables.service systemd-networkd.service",
            f"After=nftables.service systemd-networkd.service {accounts}",
            "",
            "[Service]",
            "Type=oneshot",
            "ExecStart=/usr/local/bin/nas-krun-network-policy.sh publish",
            "ExecStop=/usr/local/bin/nas-krun-network-policy.sh quiesce",
            "RemainAfterExit=yes",
            "TimeoutStartSec=90",
            "TimeoutStopSec=180",
            "",
            "[Install]",
            "WantedBy=multi-user.target",
            "",
        ]
    )


def nftables_policy_dropin() -> str:
    return "\n".join(
        [
            fleet_header("fail-closed nftables shutdown"),
            "[Service]",
            "ExecStop=",
            "ExecStop=/usr/local/bin/nas-krun-network-policy.sh quiesce-and-flush",
            "",
        ]
    )


def nft_nat(fleet: Fleet) -> str:
    taps = fleet.active_taps
    tap_input_exclusions = " ".join(
        f'iifname != "{service.tap_name}"' for service in taps
    )
    tap_output_exclusions = " ".join(
        f'oifname != "{service.tap_name}"' for service in taps
    )
    prerouting = []
    output = []
    for service in taps:
        guest = service.tap_guest.ip
        for endpoint in service.container.endpoints:
            if endpoint.host_address is None or endpoint.host_port is None:
                continue
            destination = f"{guest}:{endpoint.port}"
            if str(endpoint.host_address) == "0.0.0.0":
                prerouting.append(
                    f"        {tap_input_exclusions} fib daddr type local "
                    f"{endpoint.protocol.value} dport {endpoint.host_port} "
                    f"dnat to {destination}"
                )
                output.append(
                    f"        fib daddr type local {endpoint.protocol.value} "
                    f"dport {endpoint.host_port} dnat to {destination}"
                )
            else:
                prerouting.append(
                    f'        iifname "lo" ip daddr {endpoint.host_address} '
                    f"{endpoint.protocol.value} dport {endpoint.host_port} "
                    f"dnat to {destination}"
                )
                output.append(
                    f"        ip daddr {endpoint.host_address} "
                    f"{endpoint.protocol.value} dport {endpoint.host_port} "
                    f"dnat to {destination}"
                )
    lines = [
        fleet_header("TAP fleet NAT"),
        "table ip nas_krun_nat {",
        "    chain prerouting {",
        "        type nat hook prerouting priority dstnat; policy accept;",
        *prerouting,
        "    }",
        "",
        "    chain output {",
        "        type nat hook output priority dstnat; policy accept;",
        *output,
        "    }",
        "",
        "    chain postrouting {",
        "        type nat hook postrouting priority srcnat; policy accept;",
    ]
    for service in taps:
        if any(
            endpoint.publication is not None
            for endpoint in service.container.endpoints
        ):
            lines.append(
                f'        oifname "{service.tap_name}" ip saddr '
                f"127.0.0.0/8 ip daddr {service.tap_guest.ip} "
                f"snat to {service.tap_gateway.ip}"
            )
    for service in taps:
        lines.append(
            f"        ip saddr {service.tap_guest.ip} "
            f"{tap_output_exclusions} masquerade"
        )
    lines += ["    }", "}", ""]
    return "\n".join(lines)


def _service_header(service: Service) -> str:
    return generated_header(service.source.name)
