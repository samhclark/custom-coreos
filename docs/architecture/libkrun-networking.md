# Routed libkrun networking

## Decision

Every active libkrun service has one root-managed TAP and one routed IPv4
`/30`. The guest uses its ordinary network stack; the host kernel owns DHCP,
routing, filtering, publication, and outbound NAT.

No Podman publisher, pasta, passt, gvproxy, low-port sysctl, or userspace TCP
terminator is part of the production service data path.

## Declarative source

`quadlets/*.toml` is authoritative:

- `[krun].ipv4` assigns the guest address; the first usable address is the host
  gateway.
- Each `[[container.endpoints]]` declaration names a listener and its allowed
  `consumers`; the compiler turns those relationships into TCP allowlists.
- `[krun].host-access` allowlists guest access to selected host-gateway ports.
- An endpoint's optional `host` declares host publication. For TAP guests, the
  compiler renders nftables DNAT rather than `PublishPort=`.
- Disabled services keep their allocated identity but disappear from active
  TAP, peer, and policy output.

The compiler rejects undeclared peers, port mismatches, duplicate subnets,
unsupported bind addresses, spoofable topology, and overlapping identities.

## Generated data plane

For each active service the compiler emits:

- `krun-<uid>.netdev`, owned by the service account with `VNetHeader=yes`;
- a matching networkd configuration with the gateway and one-address DHCP
  pool using Rapid Commit;
- `AddDevice=/dev/net/tun` and `Annotation=krun.tap_name=...` in its Quadlet;
- stable `*.krun` peer names;
- nftables anti-spoofing, declared ingress, host publication, and outbound NAT.

NetworkManager ignores both `krun-*` and `wg-arr`; systemd-networkd owns those
generated interfaces. The host-side Mullvad interface is the separate,
generated `wg-arr` WireGuard device; it is not a TAP and is not placed inside
any guest.

## Mullvad-selected services

The fleet declaration in `quadlets/_fleet.toml` selects Mullvad egress for the
four media-automation services:

| Service | TAP guest address | Guest listener |
| --- | --- | --- |
| Sonarr | `10.253.14.2/30` | `sonarr.krun:8989` |
| Radarr | `10.253.15.2/30` | `radarr.krun:7878` |
| Prowlarr | `10.253.16.2/30` | `prowlarr.krun:9696` |
| SABnzbd | `10.253.17.2/30` | `sabnzbd.krun:8080` |

The host creates `wg-arr` from the typed `[egress.mullvad]` declaration. Its
address, peer public key, endpoint, `0.0.0.0/0` AllowedIPs, route table, and
firewall mark are generated from that declaration. The private key is supplied
to systemd-networkd through a `LoadCredential=` drop-in from
`/run/nas-secrets/mullvad/mullvad-private-key`; the encrypted SOPS value is not
embedded in the network unit or in a container.

Selected guests use policy routing for their public traffic and have explicit
nftables rules for two destinations:

- DNS to `100.100.100.100` (Tailscale MagicDNS), only when the route exits via
  `tailscale0` and only for TCP/UDP port 53;
- all other traffic, only when it exits via `wg-arr`.

Each selected guest has constrained established-traffic rules before the
fleet-wide conntrack acceptance rule, followed by an explicit final drop for
new traffic. If the WireGuard route, Tailscale route, interface, NAT rule, or
required policy chain disappears, neither a new nor an already-established
guest connection can fall through to the ordinary Comcast/WAN path. The generated
readiness unit publishes `/run/nas-egress/mullvad/ready` only after the
interface, routes, nftables chains, and selected-service rules are present.
That readiness check intentionally does not prove a WireGuard handshake or
successful Internet egress; those remain deployment checks.

The DNS boundary is deliberate: guests are configured only with the Tailscale
MagicDNS address `100.100.100.100`. The Tailnet is configured to override
device DNS defaults and forward public resolution through Quad9's configured
resolver boundary (including its DoH path where enabled). The guests do not
query Comcast resolvers directly, and Mullvad's private DNS address is not
used. The generated selected-service policy also prevents DNS from leaving by
any interface other than Tailscale.

The four management UIs are not published by the individual Quadlets. Caddy
is the only ingress path, using `sonarr.i.samhclark.com`,
`radarr.i.samhclark.com`, `prowlarr.i.samhclark.com`, and
`sabnzbd.i.samhclark.com`. The reusable Caddy private-ingress handler permits
LAN private ranges and Tailscale's `100.64.0.0/10`, and returns `403` for
other clients. This is an application-layer guard in addition to the host
publication topology; it is not a WAN exposure contract.

## Fail-closed lifecycle

`nas-krun-network-policy.service` is the current-boot readiness boundary. It
publishes readiness only after:

1. every service identity exists;
2. networkd has configured every active TAP and gateway;
3. the required nftables chains exist.

Only then does it start the dedicated service user managers. Each TAP Quadlet
also verifies its declared guest TCP listener after startup so a lost one-shot
DHCP exchange forces a bounded restart instead of leaving a false-positive
running state.

Known deferred lifecycle gap (2026-08-15): if the container exits while that
post-start listener probe is running, the probe can consume its full timeout
and leave the unit in `activating` before systemd restarts it. A generic
early-exit check needs a disposable systemd-user test of the tracked main PID
across Podman, conmon, and libkrun; do not infer that relationship in the
renderer without that evidence.

Stopping networkd or nftables first removes readiness and stops the service
user managers. The nftables shutdown drop-in refuses to flush policy while a
guest manager remains active.

Do not weaken this into TAP-exists checks or direct cross-manager service
dependencies.

## Publication semantics

- `127.0.0.1:<port>` is loopback-only DNAT.
- `0.0.0.0:<port>` accepts any host address.
- Other bind addresses are rejected until interface-specific policy is
  modeled and tested.
- Inter-service traffic is denied unless the destination's named endpoint
  allows the source service as a consumer.
- Guest-to-host traffic is denied unless represented by typed host access.

The narrow `nas-krun-tun` SELinux module grants only the TUN operations needed
by the patched crun/libkrun path. Broad container SELinux disablement is not an
acceptable substitute.
