# Routed libkrun TAP network

## Decision

Use one root-managed TAP and one routed IPv4 `/30` per libkrun microVM. The
guest runs its normal Linux TCP/IP stack; the host kernel performs routing,
filtering, DNAT, and outbound masquerading. This removes passt, gvproxy, pasta,
and Podman's port proxy from the service data path.

libkrun's TAP backend still copies Ethernet frames in the VMM process. This is
not a vhost-net design. The important semantic difference is that no userspace
component terminates and recreates the media TCP connection.

## Generated model

`quadlets/*.toml` is the source of truth:

- `[krun].ipv4` assigns the guest's stable second usable address in a dedicated
  `/30`; the first usable address is the host gateway.
- `[[krun.ingress]]` declares a source microVM and allowed destination TCP
  ports.
- `[krun].host-access` declares TCP ports that a guest may reach on its own host
  gateway. VictoriaMetrics uses this for node_exporter on 9100.
- `[[container.ports]]` retains its existing meaning as a host publication.
  The generator renders nftables DNAT instead of `PublishPort=` for TAP guests.
  `127.0.0.1` remains loopback-only; `0.0.0.0` means any local host address.
  Other bind addresses are rejected because the generated policy does not yet
  model interface-specific publication.
- Disabled containers retain their host identity artifacts but are excluded
  from TAP creation, peer names, ingress validation, and nftables policy.

The generator emits:

- a `krun-<uid>` `.netdev` owned by the rootless service account, with
  `VNetHeader=yes`;
- a matching `.network` with the gateway and a one-address DHCP server using
  Rapid Commit;
- a networkd service drop-in that waits for every generated TAP owner account;
- `AddDevice=/dev/net/tun`, `Annotation=krun.tap_name=...`, stable `*.krun`
  `/etc/hosts` entries, and no Podman publisher in every Quadlet;
- nftables anti-spoofing, explicit inter-guest edges, public ingress, loopback
  DNAT with per-TAP loopback routing and SNAT, VM-to-host restrictions, and
  outbound masquerading;
- a root-owned policy service that publishes a current-boot readiness marker
  only after networkd has configured every TAP gateway and the generated
  nftables chains exist. Every TAP Quadlet waits for this marker;
- fail-closed shutdown ordering: loss or shutdown of networkd/nftables first
  removes readiness and synchronously stops the dedicated service user
  managers. The nftables stop override quiesces the guests before flushing the
  ruleset, while dependency restarts propagate back to the policy service so it
  can republish readiness and restart the dedicated user managers;
- a post-start TCP check against each guest's first published TCP service. A
  missed one-shot libkrun DHCP exchange therefore fails startup, and the
  Quadlet's restart policy boots a fresh guest for another DHCP attempt.

NetworkManager continues to manage physical links and ignores `krun-*`.
systemd-networkd is enabled only to match and manage the generated TAPs.

## Local evidence (Fedora Silverblue 44)

Validated on 2026-08-07/08 without modifying the host network:

1. `/dev/kvm` and `/dev/net/tun` are usable by the local user.
2. A persistent TAP with `IFF_VNET_HDR` can be created and reopened inside an
   unprivileged user/network namespace.
3. The pinned crun 1.28 source builds with the `krun.tap_name` patch against
   Fedora's libkrun 1.19.0.
4. A disposable Alpine OCI rootfs booted as a libkrun microVM through the
   patched crun. libkrun's embedded DHCP client obtained `10.254.254.2` through
   the TAP using DHCP Rapid Commit, and host `curl` reached a TCP HTTP responder
   in the guest.
5. Starting the same VM before its DHCP server confirmed libkrun 1.19 does not
   recover inside that boot: the workload remained running but unreachable.
   Starting with DHCP ready produced a discover/ack exchange. This is why the
   generated lifecycle gates initial startup and treats failed TCP reachability
   as a startup failure that must restart the guest; ICMP is not used as the
   application-readiness signal.
6. The complete generated nftables ruleset parses successfully in an isolated
   network namespace.
7. The complete bootc image builds successfully with the patched crun,
   `systemd-networkd` subpackage, generated network files, and nftables policy;
   repository tests include a real loopback-DNAT round trip across isolated
   host and guest network namespaces.

The first boot attempt also established why `AddDevice=/dev/net/tun` is
required: without it, libkrun reached the TAP backend but failed with
`OpenNetTun(ENOENT)` after crun entered the container mount namespace.

## Remaining deployment evidence

Local testing does not prove NetworkManager/systemd-networkd coexistence during
a real CoreOS boot, SELinux access for each lingering rootless service account,
or behavior with the complete nine-service ruleset under real traffic. Before
calling the migration operational, validate TAP ownership/addressing, one
representative loopback publication, Caddy HTTP/1.1/2/3, service-to-service
denials and allows, outbound DNS/ACME, and Jellyfin seek/rewind on the NAS.
