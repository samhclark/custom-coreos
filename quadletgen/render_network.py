"""Render fleet-wide libkrun TAP networking artifacts."""

from __future__ import annotations

from .headers import generated_header
from .model import Fleet, MullvadEgress, Service


KRUN_DNS_SERVERS = ("100.100.100.100",)


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


def networkd_network(service: Service, fleet: Fleet) -> str:
    gateway = service.tap_gateway
    lines = [
        _service_header(service),
        "[Match]",
        f"Name={service.tap_name}",
        "",
        "[Link]",
        "RequiredForOnline=no",
        "",
        "[Network]",
        f"Address={gateway}",
        "DHCPServer=yes",
        "ConfigureWithoutCarrier=yes",
        "IPv4RouteLocalnet=yes",
        "LinkLocalAddressing=no",
        "IPv6AcceptRA=no",
        "",
        "[DHCPServer]",
        "PoolOffset=2",
        "PoolSize=1",
        "PersistLeases=runtime",
        "RapidCommit=yes",
        "EmitDNS=yes",
        f"DNS={' '.join(KRUN_DNS_SERVERS)}",
        "EmitNTP=no",
        "EmitSIP=no",
        "EmitRouter=yes",
        f"Router={gateway.ip}",
    ]
    if getattr(service.krun, "egress", None) == "mullvad":
        if fleet.egress is None:
            raise ValueError("Mullvad-selected TAP has no fleet egress")
        guest = f"{service.tap_guest.ip}/32"
        for priority, destination in enumerate(
            ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"),
            start=100,
        ):
            lines += [
                "",
                "[RoutingPolicyRule]",
                f"From={guest}",
                f"To={destination}",
                "Table=main",
                f"Priority={priority}",
            ]
        lines += [
            "",
            "[RoutingPolicyRule]",
            f"From={guest}",
            f"Table={fleet.egress.route_table}",
            "Priority=200",
        ]
    return "\n".join(lines) + "\n"


def wireguard_netdev(egress: MullvadEgress) -> str:
    """Render the host WireGuard device for the fixed fleet egress."""
    allowed_ips = ", ".join(str(network) for network in egress.allowed_ips)
    return f"""{fleet_header("_fleet.toml")}
[NetDev]
Name={egress.interface}
Kind=wireguard

[WireGuard]
PrivateKey=@network.wireguard.private.70-{egress.interface}
FirewallMark={egress.firewall_mark}
RouteTable={egress.route_table}

[WireGuardPeer]
PublicKey={egress.peer_public_key}
Endpoint={egress.endpoint_address}:{egress.endpoint_port}
AllowedIPs={allowed_ips}
"""


def wireguard_network(egress: MullvadEgress) -> str:
    """Render the address-only networkd configuration for wg-arr."""
    return f"""{fleet_header("_fleet.toml")}
[Match]
Name={egress.interface}

[Link]
RequiredForOnline=no

[Network]
Address={egress.address}
LinkLocalAddressing=no
IPv6AcceptRA=no
"""


def tailscale_network() -> str:
    """Keep the Tailscale MagicDNS resolver on the Tailscale interface."""
    return f"""{fleet_header("tailscale0")}
[Match]
Name=tailscale0

[Route]
Destination={KRUN_DNS_SERVERS[0]}/32
Scope=link
"""


def networkmanager_policy(fleet: Fleet) -> str:
    """Keep networkd-owned interfaces unmanaged by NetworkManager."""
    interfaces = ["krun-*"]
    if fleet.egress is not None:
        interfaces.append(fleet.egress.interface)
    unmanaged = ";".join(f"interface-name:{name}" for name in interfaces)
    return f"""{fleet_header("network manager unmanaged devices")}
# The libkrun TAPs and host WireGuard egress are created by systemd-networkd.
# Keep NetworkManager, which owns the physical CoreOS links, away from them.
[keyfile]
unmanaged-devices={unmanaged}
"""


def nft_filter(fleet: Fleet) -> str:
    taps = fleet.active_taps
    selected = tuple(
        service for service in taps
        if getattr(service.krun, "egress", None) == "mullvad"
    )
    egress_interface = None
    if selected:
        if fleet.egress is None:
            raise ValueError("Mullvad-selected TAP has no fleet egress")
        egress_interface = fleet.egress.interface
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
    # Established traffic must not bypass a selected guest's egress policy.
    # In particular, if WireGuard disappears, an existing connection may be
    # rerouted through the physical default route while conntrack still calls
    # it established. Accept only established directions that remain inside
    # the selected policy, then drop every other selected established packet
    # before the fleet-wide return-traffic rule.
    for service in selected:
        guest = service.tap_guest.ip
        lines.append(
            f'    iifname "{service.tap_name}" ip saddr {guest} '
            'ip daddr != 100.100.100.100 '
            f'oifname "{egress_interface}" '
            "ct state established,related accept"
        )
        for protocol in ("tcp", "udp"):
            lines.append(
                f'    iifname "{service.tap_name}" ip saddr {guest} '
                'ip daddr 100.100.100.100 oifname "tailscale0" '
                f"{protocol} dport 53 ct state established,related accept"
            )
        for destination in taps:
            if destination.info.name == service.info.name:
                continue
            lines.append(
                f'    iifname "{service.tap_name}" ip saddr {guest} '
                f'oifname "{destination.tap_name}" '
                "ct state established,related accept"
            )
        lines.append(
            f'    iifname "{service.tap_name}" ip saddr {guest} '
            "ct state established,related drop"
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
        guest = service.tap_guest.ip
        if getattr(service.krun, "egress", None) == "mullvad":
            lines += [
                f'    iifname "{service.tap_name}" ip saddr {guest} '
                'ip daddr 100.100.100.100 oifname "tailscale0" '
                "tcp dport 53 accept",
                f'    iifname "{service.tap_name}" ip saddr {guest} '
                'ip daddr 100.100.100.100 oifname "tailscale0" '
                "udp dport 53 accept",
                f'    iifname "{service.tap_name}" ip saddr {guest} '
                f'ip daddr != 100.100.100.100 oifname "{egress_interface}" '
                "accept",
                f'    iifname "{service.tap_name}" ip saddr {guest} drop',
            ]
        else:
            lines.append(
                f'    iifname "{service.tap_name}" ip saddr '
                f"{guest} {out_exclusions} accept"
            )
    lines += ["}", ""]
    return "\n".join(lines)


def networkd_dependencies(fleet: Fleet) -> str:
    account_units = [
        f"ensure-nas-{service.host.slug}-account.service"
        for service in fleet.active_taps
    ]
    after = list(account_units)
    requires = []
    if fleet.egress is not None:
        after.append("sops-distribute-secrets.service")
        requires.append("sops-distribute-secrets.service")
    lines = [
        fleet_header("networkd TAP and WireGuard dependencies"),
        "[Unit]",
        f"After={' '.join(after)}",
    ]
    if requires:
        lines.append(f"Requires={' '.join(requires)}")
    lines += [
        "Wants=nas-krun-network-policy.service",
    ]
    if fleet.egress is not None:
        lines += [
            "",
            "[Service]",
            "LoadCredential="
            f"network.wireguard.private.70-{fleet.egress.interface}:"
            f"/run/nas-secrets/mullvad/{fleet.egress.secret_name}",
        ]
    lines.append("")
    return "\n".join(lines)


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
    selected = tuple(
        service for service in taps
        if getattr(service.krun, "egress", None) == "mullvad"
    )
    egress_interface = None
    if selected:
        if fleet.egress is None:
            raise ValueError("Mullvad-selected TAP has no fleet egress")
        egress_interface = fleet.egress.interface
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
        guest = service.tap_guest.ip
        if getattr(service.krun, "egress", None) == "mullvad":
            lines += [
                f'        ip saddr {guest} ip daddr 100.100.100.100 '
                'oifname "tailscale0" masquerade',
                f'        ip saddr {guest} ip daddr != 100.100.100.100 '
                f'oifname "{egress_interface}" masquerade',
            ]
        else:
            lines.append(
                f"        ip saddr {guest} "
                f"{tap_output_exclusions} masquerade"
            )
    lines += ["    }", "}", ""]
    return "\n".join(lines)


def _service_header(service: Service) -> str:
    return generated_header(service.source.name)
