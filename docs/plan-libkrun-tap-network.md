# Routed libkrun TAP network

> Historical implementation and deployment record. The routed TAP design and
> narrow SELinux module are deployed; use the generated files and `AGENTS.md`
> for current behavior rather than treating the evidence below as a runbook.

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
- a networkd service drop-in that waits for every generated TAP owner account
  and pulls the policy service on every start, including automatic restarts;
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
  ruleset. Networkd also pulls the policy service on restart so it can republish
  readiness and restart the dedicated user managers;
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

## First production boot evidence (2026-08-08)

The first complete deployment validated the host-side TAP construction but
found three lifecycle and confinement gaps:

1. All nine persistent TAPs were created with the intended owner, VNET header,
   `/30` gateway, DHCP server, and `RequiredForOnline=no`. The policy's
   explicit per-TAP wait, address checks, and nftables checks completed in
   roughly 250 milliseconds and published a current-boot readiness marker.
2. Enabling `systemd-networkd.service` also enabled its generic wait-online
   service. NetworkManager owns the physical links, while networkd deliberately
   ignores those links and excludes every TAP from the generic online target,
   so the generic service had no eligible interface and timed out after 120
   seconds. The policy then timed out while synchronously starting service user
   managers that were ordered behind the delayed boot transaction. The image
   now disables only the generic wait-online unit; the policy retains its
   explicit TAP-scoped wait and queues user-manager starts without blocking.
3. The policy's `ERR` trap did not run when systemd sent `SIGTERM`, leaving its
   readiness marker behind after the unit failed. Readiness cleanup now handles
   `HUP`, `INT`, and `TERM`, including the temporary marker file.

Once the user managers finally started, every attempted microVM failed at
libkrun's `open("/dev/net/tun", O_RDWR)` with an enforcing SELinux denial from
`container_kvm_t` to `tun_tap_device_t`. Device injection, mode `0666`, and TAP
ownership were all correct. Fedora's container policy already permits the
remaining inherited TUN descriptor operations for `container_kvm_t`; the image
therefore installs a local CIL module granting only the missing `open`
permission. It intentionally does not enable the broad `container_use_devices`
boolean or disable container labeling.

The first single-service validation passed that original `open` check and then
exposed the next SELinux hook: a persistent TAP retains its creator's internal
`tun_socket` label (`systemd_networkd_t`) until the opener attaches it. The
kernel requires the opener to relabel that socket to its own domain. Fedora
already grants `container_kvm_t` the required self-domain `relabelto` and
`attach_queue` permissions, so the local module adds only cross-domain
`relabelfrom` for `systemd_networkd_t:tun_socket`. The TAP owner and the VMM's
real, effective, saved, and filesystem UID/GID were all the intended service
identity, ruling out the kernel's owner check as the source of `EACCES`.

The second single-service validation installed the resulting two-permission
module on the NAS with SELinux enforcing. Blackbox exporter attached to
`krun-51230`, started its microVM listener at `10.253.5.2:9115`, passed the
Quadlet's direct guest-listener check, and served its loopback metrics endpoint
without a new TUN device or `tun_socket` AVC. This validates the complete
host-to-guest TAP attachment path for one representative service.

The one-off live-policy validation helper used during this investigation has
been retired. The image now installs the exact reviewed module during the
build. Removing that module on a running host is not a safe rollback: it breaks
the confinement contract required by active TAP guests and can leave service
user managers stopped.

## Deployment outcome

The representative SELinux validation passed, and the corrected image became
the deployed platform for the generated service fleet. Current operational
status and remaining service-specific validation work are tracked in
`AGENTS.md` and `docs/roadmap.md`.
