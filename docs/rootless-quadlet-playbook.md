# Rootless Quadlet Playbook

This is the repository-specific guide for adding or changing a service. The
platform is compiler-driven: edit a strict TOML source, regenerate, and review
the resulting artifacts. Do not copy old unit templates or hand-maintain the
same service inventory in several files.

## Mental model

The source boundary is `quadlets/<service>.toml`. It describes:

- service metadata and immutable container image;
- dedicated host identity and subordinate-ID allocation;
- container volumes, ports, environment, secrets, and command;
- libkrun resources and routed-TAP policy;
- simple persistent data and image-controlled assets;
- typed startup readiness and host-port conflict policy.

`python3 generate-quadlets.py` loads every source into one typed fleet, checks
cross-service invariants, and emits the complete runtime contract. Generated
files carry a `GENERATED` header and must never be edited directly.

Useful current examples:

- `quadlets/blackbox-exporter.toml`: stateless service with a read-only asset;
- `quadlets/alertmanager.toml`: simple mutable data plus runtime secrets;
- `quadlets/vmalert.toml`: bounded HTTP readiness for a local dependency;
- `quadlets/garage.toml`: multiple ZFS mounts and exact mount readiness;
- `quadlets/caddy.toml`: public TCP/UDP ingress and inter-service edges.

## Add a service

### 1. Allocate identity once

Choose a namespaced username such as `_nas_example`, an unused UID in the
`51000-51999` range, and a non-overlapping 65,536-ID subordinate range. Follow
the category buckets and allocation registry in `AGENTS.md`.

UIDs are allocate-only. Never give a retired UID to another service: numeric
ownership survives account deletion and can return through ZFS snapshots.

Put the identity only in `[host]`. The compiler derives sysusers, tmpfiles,
subuid/subgid entries, account repair units, linger state, and fleet account
enablement.

### 2. Pin the container contract

Use an immutable `name:tag@sha256:<digest>` image. Describe only fields the
service needs. Keep declaration order intentional for environment variables,
volumes, secrets, ports, and ingress rules because the renderer preserves it.

Rootless refers to the host account running Podman. `container-user = 0` is
still unprivileged on the host through the rootless user namespace and is valid
when the image expects container root.

### 3. Allocate the TAP and exposure policy

Production services use a root-managed TAP:

```toml
[krun]
enabled = true
cpus = 1
ram-mib = 256
network = "tap"
ipv4 = "10.253.10.2/30"
```

Allocate a unique `/30`; the guest uses the second usable address and the host
gateway uses the first. Declare every listener in `[[container.ports]]` even
when it is loopback-only. The first TCP declaration is also the post-start
guest-listener probe.

Host publication accepts only:

- `127.0.0.1`: host-loopback access, typically for Caddy or monitoring;
- `0.0.0.0`: all host addresses for intentionally public services.

Use `[[krun.ingress]]` for service-to-service access. `from` names another
active TOML service; its allowed destination ports must also be declared by the
destination. Use `[krun].host-access` only for a guest that must reach a
specific TCP listener on its own host gateway.

The compiler generates TAP ownership, DHCP, peer `*.krun` host entries,
anti-spoofing, explicit ingress, DNAT/SNAT, and outbound NAT. Do not add Podman
`PublishPort=`, pasta, passt, or hand-written nftables rules for a TAP guest.

### 4. Classify storage and assets

Use `[assets]` for an image-controlled tree under
`/usr/share/custom-coreos/<service>`. The generated asset manifest drives
Containerfile SELinux labeling.

Use `[data]` for a simple mutable directory that tmpfiles can own and label:

```toml
[data]
path = "/var/lib/example"
mode = "0750"
subdirectories = ["cache", "state"]
```

Large or multi-dataset ZFS state needs a dedicated host preparation unit. It
must verify the exact mount, ownership, mode, access, and persistent SELinux
policy without recursively scanning healthy trees on every boot. Large ZFS
mounts do not use Podman `:Z` or `:z`.

Small root-owned config and per-service runtime-secret files may use `:Z`.
Shared files use `:z`; do not use private relabeling for a host file mounted by
multiple containers.

### 5. Declare secrets, not routing code

Add each secret as `[[container.secrets]]` and add the encrypted value to
`overlay-root/usr/share/custom-coreos/secrets/secrets.sops.yaml`. The compiler
emits `fleet/secrets.tsv`; the root-owned distributor decrypts once at boot and
writes a service-owned file below `/run/nas-secrets/<service>/`.

Do not parse TOML in shell and do not use rootless Podman `Secret=`. The
runtime-file model is the production-validated path.

### 6. Model startup requirements explicitly

Rootless user units do not depend directly on system units. If startup needs a
local dependency, use typed readiness:

```toml
[startup.readiness]
url = "http://127.0.0.1:8428/-/healthy"
timeout-sec = 300
interval-sec = 2
```

Host preparation units publish current-boot markers under `/run`. ZFS-backed
services can additionally require exact mount sources:

```toml
[startup.readiness]
marker = "/run/example-storage/ready"
timeout-sec = 300
interval-sec = 2

[[startup.readiness.mounts]]
path = "/var/lib/example"
source = "tank/example"
```

Use `[startup].reject-published-tcp-ports = true` when migration or stale host
processes could already own the service's declared TCP ports. The generated
unit invokes fixed host helpers; raw `[unit.extra]` directives are rejected.

### 7. Generate and validate

Install the pinned development dependency, then run:

```bash
python3 -m pip install --requirement requirements-dev.txt
python3 generate-quadlets.py
make verify-generated
make build
```

Review both the TOML and generated diff. Commit them together. CI repeats
strict mypy, all behavioral tests, regeneration, artifact parity, and the
container build before publication.

## What the compiler owns

For each service, the compiler can emit:

- `/etc/containers/systemd/users/<uid>/<service>.container`;
- sysusers and tmpfiles entries;
- the account-repair script and system unit;
- `/etc/subuid` and `/etc/subgid` fleet files;
- TAP `.netdev`/`.network` files and fleet policy drop-ins;
- nftables filter and NAT fragments.

It also emits purpose-specific consumer manifests:

- `fleet/account-units.list`: every declared identity, including disabled
  services;
- `fleet/active-taps.tsv`: active TAPs and exact user/account units;
- `fleet/secrets.tsv`: every declared secret route, including disabled
  services;
- `fleet/assets.list`: every declared image asset tree.

Membership carries policy. Consumers must not reconstruct unit names, parse
TOML, or reinterpret `enabled` flags.

## Operational invariants

- Rootless admin Quadlets live under
  `/etc/containers/systemd/users/<uid>/`; the superficially similar
  `/usr/share/containers/systemd/users/<uid>/` path generated a rootful system
  unit on the validated Fedora/Podman combination.
- Generated provisioning keeps PAM-compatible, non-interactive service
  accounts, repairs subordinate IDs, and creates the linger marker before
  logind starts.
- The network policy's current-boot marker is the fail-closed guest boundary.
  Loss of nftables or networkd removes readiness and stops the dedicated user
  managers before policy is flushed.
- Disabled services retain identity, secret routing, and asset labeling, but
  produce no Quadlet or TAP runtime artifacts.
- `/usr` is immutable at runtime. New image content does not overwrite existing
  `/var`; migrations and preparation units must account for persisted state.
- Agents never connect to the production NAS. Prepare the smallest reviewed
  operator command and wait for returned evidence when live validation is
  required.

If a new service requires hand-editing generated files, duplicating a fleet
list, or adding untyped systemd fragments, stop and extend the compiler model.
