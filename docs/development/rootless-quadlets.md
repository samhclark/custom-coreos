# Rootless Quadlet Playbook

This is the repository-specific guide for adding or changing a service. The
platform is compiler-driven: edit a strict TOML source, regenerate, and review
the resulting artifacts. Do not copy old unit templates or hand-maintain the
same service inventory in several files.

## Mental model

The source boundary is `quadlets/<service>.toml`. It describes:

- application/role metadata and an immutable service container image;
- dedicated host identity and subordinate-ID allocation;
- container volumes, named endpoints, environment, secrets, and command;
- libkrun resources and routed-TAP policy;
- simple persistent data and image-controlled assets;
- typed startup readiness and host-port conflict policy.

`make generate-quadlets` loads every source into one typed fleet, checks
cross-service invariants, and emits the complete runtime contract. Generated
files carry a `GENERATED` header and must never be edited directly.

Useful current examples:

- `quadlets/blackbox-exporter.toml`: stateless service with a read-only asset;
- `quadlets/alertmanager.toml`: simple mutable data plus runtime secrets;
- `quadlets/vmalert.toml`: named HTTP readiness for a local dependency;
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

The TOML filename and `[service].name` must match exactly. Service names are
DNS labels because they also become generated peer hostnames. Set
`[service].application` to the user-facing application and `[service].role` to
the component's unique job within it. Application membership is descriptive;
it does not merge identities, storage, networking, lifecycle, or backup policy.
See [`../architecture/applications.md`](../architecture/applications.md).

Use an immutable `name:tag@sha256:<digest>` image. Describe only fields the
service needs. Keep declaration order intentional for environment variables,
volumes, secrets, and endpoints because the renderer preserves it.

The schema deliberately accepts only values the renderer can emit without
another quoting language: environment values are single atoms, `exec` is a
space-separated argument list, and volume sources, targets, and secret targets
are normalized absolute portable paths. Extend the typed schema and renderer
together if a future service needs richer quoting; do not embed raw systemd or
shell syntax in TOML.

Rootless refers to the host account running Podman. `container-user = 0` is
still unprivileged on the host through the rootless user namespace and is valid
only when the image expects container root **and its entrypoint leaves the
effective service process as container root**. An entrypoint that starts as root
and drops to an internal account instead hands writable files to a subordinate
host ID, which conflicts with the storage runtime's service-account ownership
contract.

A positive `container-user` generates a matching `keep-id` user namespace, so
the service host UID appears as that UID inside the container and remains the
owner of declared storage. Prefer this when the image supports a fixed non-root
UID. Treat the effective UID after entrypoint processing, writable paths,
signals, and required entrypoint behavior as a versioned image interface; test
those properties again whenever the image digest changes.

Use digest-pinned upstream or application-supported images while they satisfy
that interface. A locally maintained image is justified when it adds a required
capability, closes an unacceptable provenance gap, or resolves a demonstrated
runtime incompatibility. It is not the default merely because an image was
published for an upstream Compose deployment: owning an image also means owning
its security updates and compatibility release train.

### 3. Allocate the TAP and exposure policy

Production services use a root-managed TAP:

```toml
[krun]
enabled = true
cpus = 1
ram-mib = 256
network = "tap"
ipv4 = "10.253.10.2/30"
probe-endpoint = "http"
```

Allocate a unique `/30`; the guest uses the second usable address and the host
gateway uses the first. Declare every listener in `[[container.endpoints]]`,
give it a stable name, and set `probe-endpoint` to one declared TCP endpoint;
that listener is the post-start guest readiness boundary. The default bounded
wait is 30 seconds; set `probe-timeout-sec` only for components whose reviewed
initialization or migration path genuinely takes longer. For example:

```toml
[[container.endpoints]]
name = "http"
port = 8080
host = "127.0.0.1:8080"
consumers = ["caddy", "blackbox-exporter"]
```

Host publication accepts only:

- `127.0.0.1`: host-loopback access, typically for Caddy or monitoring;
- `0.0.0.0`: all host addresses for intentionally public services.

List service-to-service access in the destination endpoint's `consumers`.
Every consumer must name another active TAP service. Use `[krun].host-access`
only for a guest that must reach a specific TCP listener on its own host
gateway.

The compiler generates TAP ownership, DHCP, peer `*.krun` host entries,
anti-spoofing, explicit ingress, DNAT/SNAT, and outbound NAT. Do not add Podman
`PublishPort=`, pasta, passt, or hand-written nftables rules for a TAP guest.
At least one active TAP service is a fleet invariant because the generated
network policy and its static host consumers are intentionally always present.

### 4. Classify storage and assets

Use `[assets]` for an image-controlled tree under
`/usr/share/custom-coreos/<service>`. The generated asset manifest drives
Containerfile SELinux labeling.

Use `[[storage]]` for mutable application state. A small directory example is:

```toml
[[storage]]
name = "state"
kind = "directory"
host-path = "/var/lib/example"
mode = "0750"
subdirectories = ["cache", "state"]

[[storage.exports]]
subpath = "state"
container-path = "/var/lib/example"
access = "read-write"
```

Managed and required-existing ZFS use the same declaration language. The
compiler derives the container mount, host manifest and unit, SELinux policy,
and readiness checks. Do not add a handwritten preparation unit or a raw
`[[container.volumes]]` source below `/var`. See
[`../architecture/storage.md`](../architecture/storage.md) for the complete
kind and repair contracts. Large storage mounts do not use Podman `:Z` or `:z`.

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
[[startup.dependencies]]
service = "victoria-metrics"
endpoint = "http"
condition = "http"
path = "/-/healthy"
timeout-sec = 300
interval-sec = 2
```

Storage declarations own their generated `/run/nas-storage/<service>/ready`
marker and path checks. Dependency readiness composes with that storage gate,
and several TCP or HTTP dependencies may be declared. The target endpoint must
allow the dependent service in `consumers`; the compiler resolves its TAP
address and port. These are bounded startup checks, not ongoing health checks.

`[startup].require-published-tcp-ports-free = true` is an intentionally
service-specific migration diagnostic. Use it only when a retired or stale
host process could still listen on that service's declared TCP ports, as
retained for the Garage, Jellyfin, and Jellyfin exporter deployments. It is not
a universal TAP requirement or a security boundary: it checks immediately
before startup but cannot prevent a later listener race. The generated unit
invokes fixed host helpers; raw `[unit.extra]` directives are rejected.

### 7. Generate and validate

Install `uv`; the Make targets create and synchronize the locked Python
environment automatically. Then run:

```bash
make generate-quadlets
make check
make test
make build
```

Review both the TOML and generated diff. Commit them together. CI repeats
strict ty checks, all behavioral tests, regeneration, artifact parity, and the
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
