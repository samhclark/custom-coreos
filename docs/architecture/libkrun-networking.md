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

NetworkManager ignores `krun-*`; systemd-networkd owns only those generated
interfaces.

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
