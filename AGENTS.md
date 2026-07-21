# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Overview

This repository creates a custom CoreOS container image with ZFS, Tailscale, and encrypted storage support. The project has been **successfully overhauled** from a build-from-source approach to using prebuilt ZFS kernel modules with full CI/CD automation.

**Status**: In production for one personal NAS
**Build Time**: ~2-3 minutes (down from 10+ minutes)
**Container Registry**: `ghcr.io/samhclark/custom-coreos:stable`
**Ignition File**: `https://samhclark.github.io/custom-coreos/ignition.json`

This is an open source reference project, not a general-purpose appliance. The intended deployment is one machine for one user.

## Project Relationship

This project depends on `../fedora-zfs-kmods/` which builds and publishes prebuilt ZFS kernel modules as container images. The architecture uses registry-based compatibility checking - if a ZFS+kernel combination exists in the fedora-zfs-kmods registry, it's compatible.

## Fast Orientation

The quickest accurate mental model is:

1. `Makefile` and `.github/workflows/` decide **what versions to build**
2. `Containerfile` decides **what goes into the bootc image**
3. `overlay-root/` decides **how the installed machine behaves at runtime**
4. `butane.yaml` is intentionally narrow and personal: it handles host identity and root storage setup, not service orchestration

If you need to understand real behavior, prioritize `Containerfile`, `overlay-root/`, and `butane.yaml` over prose docs.

## Runtime Topology

This repo is not just "CoreOS with ZFS". It currently defines a full single-node NAS host profile.

### Active Quadlet Containers

These are considered active and in use on the real machine unless explicitly stated otherwise:
- `blackbox-exporter.container` - local HTTP/TCP probe exporter for service-availability checks; rootless under `etc/containers/systemd/users/51230/`
- `caddy.container` - reverse proxy / TLS termination for the user-facing services; still rootful after its rootless preflight completed successfully, with the guarded phase-two cutover next
- `garage.container` - S3-compatible object storage on ZFS; rootless under `etc/containers/systemd/users/51110/`, deployed and validated on the NAS
- `victoria-metrics.container` - metrics storage; rootless under `etc/containers/systemd/users/51250/`, deployed and validated on the NAS
- `vmalert.container` - alert rule evaluation; rootless under `etc/containers/systemd/users/51220/`
- `alertmanager.container` - notification fanout; rootless under `etc/containers/systemd/users/51240/`, deployed and validated on the NAS
- `grafana.container` - dashboards; rootless under `etc/containers/systemd/users/51210/`

### Supporting Host Units

Important non-container units:
- `sops-distribute-secrets.service` - decrypts the repo-managed SOPS file and distributes Podman secrets at boot
- `caddy-rootless-preflight.timer` - records the rootful Caddy baseline and verifies its staged rootless identity, runtime secret, and low-port policy
- `zfs-create-garage-datasets.service` - creates/tunes Garage datasets and applies persistent SELinux labeling
- `zfs-create-victoria-metrics-dataset.service` - same idea for VictoriaMetrics
- `disk-health-metrics.timer` - emits SMART and ZFS metrics for node_exporter
- `zfs-health-check.timer` - periodic pool health checks
- `zfs-snapshots-*@.timer` - rolling snapshot retention for selected datasets

### Monitoring Notes

- Garage service availability should be based on the blackbox-exporter probe of `http://127.0.0.1:3903/health`, not on `up{job="garage"}` from the admin `/metrics` scrape
- Garage's `/metrics` endpoint is still useful for internal/storage metrics, but it can respond slowly enough to create false `up == 0` results even when the service is healthy

### Storage Layout Assumptions

- Root filesystem is LUKS + btrfs, unlocked by TPM, without PCR binding
- The main data pool is expected to be `tank`
- Garage datasets live under `tank/garage/{meta,data}`
- VictoriaMetrics data lives under `tank/victoria-metrics/data`
- Large ZFS-backed container data paths are labeled persistently with `semanage fcontext` + `restorecon -F -R`; do not casually switch them to Podman `:Z` / `:z`

### Secrets Model

- Podman is configured to use the shell secret driver
- Secret material is encrypted in the repo with SOPS at `/usr/share/custom-coreos/secrets/secrets.sops.yaml`
- The SOPS age private key is expected on the NAS as a `systemd-creds` file at `/var/lib/nas-secrets/age-key.cred`
- Distributed rootful Podman secret material is encrypted at rest with `systemd-creds` in `/var/lib/podman-secrets/*.cred`; rootless services should use per-service runtime files under `/run/nas-secrets/<service>/` instead of Podman `Secret=`
- `nas-secrets` is the admin-facing wrapper for creating, rotating, showing, and deleting those Podman secrets
- `test-podman-secret-driver.sh` is the host-level smoke test for `podman secret create/show/run/rm`; it requires a live TPM-backed host and is not part of CI
- `sops-distribute-secrets.service` is the boot-time source of truth for Garage, Caddy, VictoriaMetrics, and Alertmanager secrets; Caddy intentionally receives both a rootful Podman secret and a staged runtime file during its preflight release
- Rootless Podman secrets are not a validated production path. NAS testing showed rootless Podman's shell secret-driver context cannot use meaningful `systemd-creds` key modes. The selected rootless design is for the rootful SOPS distributor to write per-service runtime files under `/run/nas-secrets/<service>/`; see `docs/plan-sops-and-quadlet-generator.md` Appendix D before adding rootless secrets.

### Manual Bootstrap Reality

This repository intentionally still has some manual host bootstrap:
- non-root LUKS volumes are enrolled with TPM manually after install
- the SOPS age private key credential must be installed manually on the NAS
- `tank` may still need to be imported manually depending on system state

This is acceptable because the system has one real user and is published as a reference project, not as a turnkey product.

## Key Commands

### Version Discovery & Compatibility
- `make versions` - Show ZFS, kernel versions and compatibility status
- `make zfs-version` - Get latest ZFS release
- `make kernel-version` - Get current CoreOS kernel version (script-based fallback if labels are missing)
- `make check` - Verify prebuilt ZFS kmods exist for current versions

### Building
- `make build` - Build image locally with automatic version discovery
- `make deps` - Verify required tools are present (podman, gh, skopeo)

### Ignition File Management
- `make generate-ignition` - Generate Ignition JSON from butane.yaml

### CI/CD Integration
- `make run-workflow` - Trigger main build workflow
- `make run-pages` - Trigger Ignition file generation and GitHub Pages deployment
- `make run-cleanup` - Trigger container cleanup (dry run)
- `make run-cleanup-force` - Trigger container cleanup (actual deletion)
- `make workflow-status` - Check build workflow status
- `make all-workflows` - Check status of all workflows

### Local Testing
- `make cleanup-dry-run RETENTION_DAYS=N` - Test cleanup logic with configurable retention

### Verification
- After changing `butane.yaml`: run `make generate-ignition` to verify the config is valid Butane.
- After changing `Containerfile` or `overlay-root/`: run `make build` to verify the image builds.
- These are independent — the Ignition file and the container image are separate artifacts with separate CI workflows.
- `bootc container lint` warnings about `/var` cache artifacts are currently expected and can be ignored for now. Warnings about `/var/usrlocal` usually mean something was copied into `/usr/local` before this image's overlay replaced Fedora CoreOS's default `/usr/local -> ../var/usrlocal` symlink.

## Architecture (Production)

**2-stage build process** consuming prebuilt ZFS RPMs:

### Stage 1: Pull Prebuilt ZFS Kernel Modules
```dockerfile
FROM ghcr.io/samhclark/fedora-zfs-kmods:zfs-${ZFS_VERSION}_kernel-${KERNEL_VERSION} as zfs-rpms
```

### Stage 2: Final Image Assembly

Starts `FROM quay.io/fedora/fedora-coreos:stable`, validates that the
provided `KERNEL_VERSION` matches the base image's actual kernel, then in a
single `RUN`: installs the host packages (nftables, node-exporter,
smartmontools, tailscale, jq) plus the ZFS RPMs from stage 1, runs
`depmod`, and enables the systemd units. See the `Containerfile` itself for
the authoritative package and unit lists — do not duplicate them here.

## CI/CD Workflows

### Main Build (`.github/workflows/build.yaml`)
- **Trigger**: Daily at 9:18 AM UTC + manual
- **Jobs**: query-versions → build
- **Output**: `ghcr.io/samhclark/custom-coreos:stable`
- **Features**: Version discovery, compatibility checking, build attestations

### Ignition Files (`.github/workflows/pages.yaml`)
- **Trigger**: Push to main (butane.yaml changes) + manual
- **Output**: `https://samhclark.github.io/custom-coreos/ignition.json`
- **Features**: Butane→Ignition conversion, GitHub Pages deployment

### Container Cleanup (`.github/workflows/cleanup-images.yaml`)
- **Trigger**: Weekly Sundays 2 AM UTC + manual
- **Retention**: 90 days
- **Safety**: Manual triggers default to dry-run

## Configuration Strategy

**This is a bootc-centric CoreOS system requiring careful separation of configuration approaches.**

### Containerfile Configuration (System Capabilities)
Use the `Containerfile` for configuration that adds **capabilities** to the system:
- **Security**: Sigstore verification for container pulls via `/etc/containers/policy.json` (used by bootc)
- **System Services**: NTP configuration, chronyd settings
- **Package Installation**: ZFS modules, firewalld, Tailscale
- **Service Enablement**: systemd units (timers, tailscaled)

### Butane Configuration (Personal & Runtime)
Use `butane.yaml` for configuration that is **personal** or **cannot be described declaratively**:
- **Personal Settings**: SSH authorized keys, user password hash, hostname
- **Runtime Configuration**: LUKS encryption with TPM2 unlock
- **Dynamic Filesystem**: Encrypted btrfs mounting, partition layouts
- **Boot-time Decisions**: Anything requiring runtime system state

### Current Configuration (`butane.yaml`)
- **Encryption**: LUKS root filesystem with TPM2 unlock, without PCR binding
- **Filesystem**: Btrfs on `/dev/mapper/root`
- **Access**: SSH key and password hash for 'core' user
- **Identity**: Hostname set to 'nas'

### Installation URL
```
https://samhclark.github.io/custom-coreos/ignition.json
```

Use this URL during CoreOS installation to configure encrypted storage, SSH access, and system settings.

## Version Compatibility Strategy

**Registry-Based Compatibility**: No manual compatibility matrix maintenance.

- ✅ **If exists**: `ghcr.io/samhclark/fedora-zfs-kmods:zfs-X.X.X_kernel-Y.Y.Y` → Compatible
- ❌ **If missing**: Build fails early with clear error pointing to fedora-zfs-kmods project

This eliminates duplicate compatibility tracking and provides automatic compatibility validation.

## Container Labels

Images include labels for future deduplication:
- `custom-coreos.zfs-version` - ZFS version used
- `custom-coreos.kernel-version` - Kernel version used

## Key Files

### Core Files
- `Containerfile` - 2-stage build definition
- `butane.yaml` - Fedora CoreOS configuration with host identity + storage
- `Makefile` - Development commands (`make help` to see all targets)
- `ignition.json` - Generated Ignition file (auto-updated)
- `overlay-root/` - Systemd units, ZFS scripts, Quadlets, cosign policy files
- `scripts/query-coreos-kernel.sh` - Kernel version discovery (called by Makefile and CI)
- `scripts/resolve-zfs-version.sh` - ZFS version discovery (called by Makefile and CI)
- `scripts/cleanup-dry-run.sh` - Local dry-run of container image cleanup logic

### CI/CD Workflows
- `.github/workflows/build.yaml` - Main container build
- `.github/workflows/pages.yaml` - Ignition file serving
- `.github/workflows/cleanup-images.yaml` - Registry maintenance

### Documentation
- `AGENTS.md` - This file
- `README.md` - User documentation
- `docs/rootless-quadlet-playbook.md` - Repo-specific pattern for migrating and creating rootless Quadlets
- `docs/rootless-grafana-checklist.md` - Post-boot validation and troubleshooting checklist for the first rootless Quadlet rollout
- `docs/rootless-alertmanager-checklist.md` - Post-boot validation for the Alertmanager rootless and runtime-secret migration
- `docs/rootless-victoria-metrics-checklist.md` - Post-boot validation for the VictoriaMetrics rootless, ZFS ownership, and runtime-secret migration
- `docs/rootless-garage-preflight.md` - Historical first-stage evidence collection before Garage's rootless ownership migration
- `docs/rootless-garage-checklist.md` - Post-boot validation and rollback steps for the Garage rootless, ZFS ownership, and runtime-secret migration
- `docs/rootless-caddy-preflight.md` - Completed first-stage validation and phase-two handoff for Caddy's rootless identity, runtime secret, low-port policy, persistent state, and guarded cutover
- `vendored-docs/podman-systemd.unit.5.md` - Vendored Quadlet reference, useful for rootless/systemd placement questions
- `docs/garage/configuration.md` - Vendored upstream Garage configuration reference

## Development Patterns

**Registry-First Compatibility**: Let the container registry be the source of truth for ZFS+kernel compatibility rather than maintaining duplicate matrices.

**Local-First CI/CD Development**: Implement workflow logic in Makefile targets and `scripts/` first, then reference those scripts from GitHub Actions for consistency.

## bootc Primer (Tips)

- Treat `/usr` as immutable at runtime; bootc bind-mounts it read-only.
- Only `/var` persists across upgrades; avoid relying on updates to existing `/var` files from new images.
- Standard writable paths are symlinks into `/var` (e.g. `/home` -> `/var/home`, `/opt` -> `/var/opt`).
- Fedora CoreOS normally has `/usr/local -> ../var/usrlocal`, but this image intentionally ships image-managed files under `overlay-root/usr/local/`, so the deployed NAS has `/usr/local` as a real immutable directory.
- Use systemd `tmpfiles.d` or unit `StateDirectory=` to seed `/var` content on first boot.
- Prefer packaging static content into `/usr`; avoid dropping mutable content into `/var` during image builds.

## Host Service Identity Scheme

- Rootless service accounts should use namespaced host usernames such as `_nas_grafana` rather than upstream/vendor defaults like `grafana`
- Reserve `51000-51999` for image-managed service accounts in this repo
- Use category buckets inside that range: `511xx` for storage, `512xx` for observability, `513xx` for ingress/edge
- Current allocation: `_nas_garage` uses host UID/GID `51110`; `_nas_grafana` uses `51210`; `_nas_vmalert` uses `51220`; `_nas_blackbox` uses `51230`; `_nas_alertmanager` uses `51240`; `_nas_victoriametrics` uses `51250`; `_nas_caddy` uses `51310`
- Subordinate ID ranges are a separate allocator, but keep them globally non-overlapping; the current convention is to derive a `65536`-wide range from the host UID for readability, e.g. `_nas_grafana:512100000:65536`
- UIDs are allocate-only: never reuse a UID from a retired service. File ownership is numeric and outlives the user — ZFS snapshots in particular can hand a retired UID's files to whatever service reuses it. `quadlets/*.toml` is the registry of active allocations; when the first service is actually retired, record its UID here as retired and add a `retired-uids` check to `generate-quadlets.py`.

## Rootless Quadlet Note

Current state:
- Caddy remains a rootful system Quadlet under `overlay-root/etc/containers/systemd/`; its rootless identity, runtime secret, low-port binding, state inventory, and representative routes were production-validated on 2026-07-21. `quadlets/caddy.toml` remains staged with `enabled = false`; the next task is the guarded phase-two cutover in `docs/rootless-caddy-preflight.md`.
- Grafana, vmalert, blackbox exporter, Alertmanager, VictoriaMetrics, and Garage are deployed and validated as rootless admin-managed user Quadlets
- Rootless-service files are **generated**: edit `quadlets/<service>.toml`, run `python3 generate-quadlets.py`, and commit both. Never hand-edit files with a `GENERATED` header — CI (`build-check.yaml` job `verify-generated`) fails on drift. Adding a new rootless service means: new TOML with a UID from the identity scheme below, run the generator, add `systemctl enable ensure-nas-<slug>-account.service` to the Containerfile, add any secret values to `secrets.sops.yaml`.

Useful reference points for future rootless work:
- The vendored `podman-systemd.unit.5.md` in this repo documents the rootless admin-managed Quadlet search paths under `/etc/containers/systemd/users/$(UID)` and `/etc/containers/systemd/users/`
- In practice, placing a user Quadlet under `/usr/share/containers/systemd/users/${UID}/` caused Fedora 43 with Podman 5.8.1 to generate a system unit in `system.slice`, because that path is still underneath the rootful `/usr/share/containers/systemd/` tree. Use `/etc/containers/systemd/users/${UID}/` for rootless service users in this repo.
- `sysusers.d` configuration belongs in `/usr/lib/sysusers.d` for packaged/vendor config; it is not a `/var` payload
- Rootless Podman expects subordinate ID ranges. This repo now ships explicit `_nas_garage`, `_nas_grafana`, `_nas_vmalert`, `_nas_blackbox`, `_nas_alertmanager`, and `_nas_victoriametrics` ranges in `/etc/subuid` and `/etc/subgid`
- If more rootless service users are added later, keep subordinate ID ranges non-overlapping and treat `/etc/subuid` and `/etc/subgid` as globally coordinated host resources
- Do not assume Podman `Secret=` works for rootless services with the current shell driver. The helper can run inside a user namespace where `systemd-creds` cannot access the host key or TPM device. Rootless services that need secrets should consume per-service runtime files written by the rootful SOPS distributor under `/run/nas-secrets/<service>/`, mounted read-only with `:ro,Z` (validated on the NAS 2026-07-03: rootless Podman can relabel `/run` tmpfs files to `container_file_t`; unrelabeled `var_run_t` files are blocked by SELinux).
- linger state is managed by logind and lives under `/var/lib/systemd/linger`; `loginctl enable-linger` is the canonical interface even if a tmpfiles-based approach is possible
- Rootless user services should not depend directly on system units like `victoria-metrics.service`; cross-manager ordering is fragile, so prefer services that can tolerate starting independently, or use a bounded `ExecStartPre=` readiness loop when startup requires a local dependency to answer first
- Grafana's shipped provisioning and dashboards now live under `/usr/share/custom-coreos/grafana/` so they remain image-controlled rather than service-owned
- vmalert's shipped rules now live under `/usr/share/custom-coreos/vmalert/` so they remain image-controlled rather than service-owned
- Alertmanager's static config lives under `/usr/share/custom-coreos/alertmanager/` and uses native Pushover `user_key_file` / `token_file` settings; do not reintroduce plaintext config generation under `/var`
- VictoriaMetrics' scrape config lives under `/usr/share/custom-coreos/victoria-metrics/`; its large ZFS data path is prepared by `zfs-create-victoria-metrics-dataset.service`, not recursive generator-managed tmpfiles rules
- Garage's config lives under `/usr/share/custom-coreos/garage/`; its two ZFS paths use a fixed recursive rollback snapshot and guarded root-last ownership migration in `zfs-create-garage-datasets.service`. Normal boots check only roots and bounded samples; create `/var/lib/nas-migrations/garage-rootless-ownership-v1/repair-required` before restarting the preparation service when an explicit full recursive ownership and SELinux repair is required.
- Caddy's completed first-stage preflight must not declare its live state paths through the generator's `[data]` section; phase two needs a cutover-specific archive plus guarded descendant-first/root-last ownership and SELinux preparation service
- For rootless Grafana, SELinux access is intended to come from persistent `semanage fcontext` rules plus `restorecon`, not from `SecurityLabelDisable=true`

## Build Performance

- **Previous**: 10+ minutes (ZFS compilation from source)
- **Current**: 2-3 minutes (prebuilt RPM consumption)
- **Improvement**: 70%+ reduction in build time

## Security Features

- **Encryption**: LUKS root filesystem with TPM2-based unlock, without PCR binding
- **Build Security**: Container image signing and attestations
- **Access Control**: SSH key-based authentication
- **Tailscale**: Daemon enabled (auth/config via runtime)

### Threat Model

This is a single-admin homelab NAS. The primary threats are:
- A malicious or compromised container image (e.g. a supply chain attack on Garage or VictoriaMetrics)
- Malware running on the host as an unprivileged user

We are **not** defending against: an attacker with root on the host (game over regardless) or a compromised container reading its own data (unavoidable).

### SELinux and Quadlet Containers

SELinux runs in enforcing mode (Fedora default). The main value for containers is **type enforcement**: files labeled `container_file_t` are only accessible to processes in the `container_t` domain, so host-level malware running as an unprivileged user cannot read container data. Mount namespaces provide the primary isolation between containers — each container only sees its explicitly declared volume mounts.

#### Volume labeling strategy

- **Small files on the root filesystem** (configs, secrets): use `:Z` (private MCS label) or `:z` (shared label) on the volume mount. Podman relabels these on every start, which is fine because they're tiny.
- **The same host file shared between containers**: use `:z` (shared). Using `:Z` causes the last container to start to steal the private label, breaking the other container. Separate per-service runtime-secret copies are not shared files and can each use `:Z`.
- **Large ZFS-backed data directories**: do **not** use `:Z` or `:z` on the volume mount. Podman's recursive SELinux relabeling runs on every container start and will hang or timeout on large directories. Instead, label these at dataset creation time using `semanage fcontext` (with `-r s0` to specify the MCS range) to set a persistent policy rule, then `restorecon -F -R` to apply it. The `-F` flag is critical — without it, `restorecon` only resets the SELinux type (e.g. `container_file_t`) but does **not** clear MCS categories (e.g. `s0:c148,c350` left behind by a previous `:Z` mount). The ZFS creation scripts check a sample file inside each directory on every boot and only run the full recursive relabel when labels are actually wrong.

#### ZFS snapshots and SELinux

SELinux labels are stored as xattrs on files. ZFS snapshots capture xattrs. Rolling back a snapshot restores old labels, which may not match the current policy. After any ZFS rollback, run `restorecon -F -R` on the affected mountpoints to reapply the `semanage fcontext` policy (the `-F` ensures the full context including MCS range is reset). The policy itself lives in the SELinux policy store on the root filesystem, not on the ZFS dataset, so it survives rollbacks. Same applies to `zfs send/receive` — the receiving machine needs its own `semanage fcontext` rules.

## Quick Start

- **Build the container image**: `make build`
- **Update the Ignition file** (after editing `butane.yaml`): `make generate-ignition`
- **Trigger CI build**: `make run-workflow`
- **Install CoreOS**: Use `https://samhclark.github.io/custom-coreos/ignition.json`

## Troubleshooting

**Build failures**: Check `make check` - likely no prebuilt ZFS kmods for current versions
**Workflow failures**: Check `make all-workflows` for status
**Ignition issues**: Verify with `make generate-ignition` locally first
