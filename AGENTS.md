# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Overview

This repository creates a custom CoreOS container image with ZFS, Tailscale, Cockpit management tooling, and encrypted storage support. The project has been **successfully overhauled** from a build-from-source approach to using prebuilt ZFS kernel modules with full CI/CD automation.

**Status**: In production for one personal NAS
**Build Time**: ~2-3 minutes (down from 10+ minutes)
**Container Registry**: `ghcr.io/samhclark/custom-coreos:stable`
**Ignition File**: `https://samhclark.github.io/custom-coreos/ignition.json`

This is an open source reference project, not a general-purpose appliance. The intended deployment is one machine for one user.

## Project Relationship

This project depends on `../fedora-zfs-kmods/` which builds and publishes prebuilt ZFS kernel modules as container images. The architecture uses registry-based compatibility checking - if a ZFS+kernel combination exists in the fedora-zfs-kmods registry, it's compatible.

## Fast Orientation

The quickest accurate mental model is:

1. `Justfile` and `.github/workflows/` decide **what versions to build**
2. `Containerfile` decides **what goes into the bootc image**
3. `overlay-root/` decides **how the installed machine behaves at runtime**
4. `butane.yaml` is intentionally narrow and personal: it handles host identity and root storage setup, not service orchestration

If you need to understand real behavior, prioritize `Containerfile`, `overlay-root/`, and `butane.yaml` over prose docs.

## Runtime Topology

This repo is not just "CoreOS with ZFS". It currently defines a full single-node NAS host profile.

### Active Quadlet Containers

These are considered active and in use on the real machine unless explicitly stated otherwise:
- `caddy.container` - reverse proxy / TLS termination for the user-facing services
- `cockpit-ws.container` - privileged Cockpit web service proxy
- `garage.container` - S3-compatible object storage on ZFS
- `victoria-metrics.container` - metrics storage
- `vmalert.container` - alert rule evaluation; rootless under `etc/containers/systemd/users/51220/`
- `alertmanager.container` - notification fanout
- `grafana.container` - dashboards; rootless under `etc/containers/systemd/users/51210/`

### Supporting Host Units

Important non-container units:
- `age-tpm-identity.service` - creates the TPM-sealed age identity used by the Podman shell secret driver
- `garage-generate-secrets.service` - auto-generates Garage secrets on first boot
- `alertmanager-generate-config.service` - renders Alertmanager config from stored secrets
- `zfs-create-garage-datasets.service` - creates/tunes Garage datasets and applies persistent SELinux labeling
- `zfs-create-victoria-metrics-dataset.service` - same idea for VictoriaMetrics
- `disk-health-metrics.timer` - emits SMART and ZFS metrics for node_exporter
- `zfs-health-check.timer` - periodic pool health checks
- `zfs-snapshots-*@.timer` - rolling snapshot retention for selected datasets

### Storage Layout Assumptions

- Root filesystem is LUKS + btrfs, unlocked by TPM, without PCR binding
- The main data pool is expected to be `tank`
- Garage datasets live under `tank/garage/{meta,data}`
- VictoriaMetrics data lives under `tank/victoria-metrics/data`
- Large ZFS-backed container data paths are labeled persistently with `semanage fcontext` + `restorecon -F -R`; do not casually switch them to Podman `:Z` / `:z`

### Secrets Model

- Podman is configured to use the shell secret driver
- Secret material is encrypted at rest with `age`, using a TPM-sealed `age-plugin-tpm` identity stored in `/var/lib/age-tpm`
- Garage secrets are generated automatically if missing
- Other service secrets are still manual
- Migration scripts may remain in-tree even if they were only needed once

### Manual Bootstrap Reality

This repository intentionally still has some manual host bootstrap:
- non-root LUKS volumes are enrolled with TPM manually after install
- some Podman secrets are created manually over SSH
- `tank` may still need to be imported manually depending on system state

Specifically, expect manual creation/management of secrets such as:
- `cf-api-token`
- `pushover-user-key`
- `pushover-api-token`

This is acceptable because the system has one real user and is published as a reference project, not as a turnkey product.

## Key Commands

### Version Discovery & Compatibility
- `just versions` - Show ZFS, kernel versions and compatibility status
- `just zfs-version` - Get latest ZFS 2.4.x release
- `just kernel-version` - Get current CoreOS kernel version (script-based fallback if labels are missing)
- `just check-zfs-available` - Verify prebuilt ZFS kmods exist for current versions

### Building & Testing
- `just build` - Build image locally with automatic version discovery
- `just test-build` - Quick build test (builds then removes image)

### Ignition File Management
- `just butane` - Run Butane container to process configuration files
- `just generate-ignition` - Generate Ignition JSON from butane.yaml

### CI/CD Integration
- `just run-workflow` - Trigger main build workflow
- `just run-pages` - Trigger Ignition file generation and GitHub Pages deployment
- `just run-cleanup` - Trigger container cleanup (dry run)
- `just run-cleanup-force` - Trigger container cleanup (actual deletion)
- `just workflow-status` - Check build workflow status
- `just all-workflows` - Check status of all workflows

### Local Testing
- `just cleanup-dry-run DAYS` - Test cleanup logic with configurable retention

### Verification
- After changes, run `just generate-ignition` and `just test-build`.
- `bootc container lint` warnings about `/var` cache artifacts are currently expected and can be ignored for now.

## Architecture (Production)

**2-stage build process** consuming prebuilt ZFS RPMs:

### Stage 1: Pull Prebuilt ZFS Kernel Modules
```dockerfile
FROM ghcr.io/samhclark/fedora-zfs-kmods:zfs-${ZFS_VERSION}_kernel-${KERNEL_VERSION} as zfs-rpms
```

### Stage 2: Final Image Assembly
```dockerfile
FROM quay.io/fedora/fedora-coreos:stable
# Inline kernel version validation
RUN [[ "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" == "${KERNEL_VERSION}" ]]

# Single RUN command for efficiency
RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
    dnf install -y \
        cockpit-ostree \
        cockpit-podman \
        cockpit-system \
        firewalld \
        libnfsidmap \
        sssd-nfs-idmap \
        nfs-utils \
        tailscale \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm \
        /zfs-rpms/*.$(rpm -qa kernel --queryformat '%{ARCH}').rpm && \
    depmod -a "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
    echo "zfs" > /etc/modules-load.d/zfs.conf && \
    systemctl enable tailscaled.service
```

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
- **Package Installation**: ZFS modules, Cockpit tooling, firewalld, Tailscale
- **Service Enablement**: systemd units (timers, cockpit-ws, tailscaled)

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
- `Justfile` - Comprehensive development commands
- `ignition.json` - Generated Ignition file (auto-updated)
- `overlay-root/` - Systemd units, ZFS scripts, cockpit Quadlet, cosign policy files
- `scripts/query-coreos-kernel.sh` - Kernel version discovery helper

### CI/CD Workflows
- `.github/workflows/build.yaml` - Main container build
- `.github/workflows/pages.yaml` - Ignition file serving
- `.github/workflows/cleanup-images.yaml` - Registry maintenance

### Documentation
- `AGENTS.md` - This file
- `README.md` - User documentation
- `docs/rootless-quadlet-playbook.md` - Repo-specific pattern for migrating and creating rootless Quadlets
- `docs/rootless-grafana-checklist.md` - Post-boot validation and troubleshooting checklist for the first rootless Quadlet rollout
- `vendored-docs/podman-systemd.unit.5.md` - Vendored Quadlet reference, useful for rootless/systemd placement questions
- `docs/garage/configuration.md` - Vendored upstream Garage configuration reference

## Development Patterns

**Registry-First Compatibility**: Let the container registry be the source of truth for ZFS+kernel compatibility rather than maintaining duplicate matrices.

**Local-First CI/CD Development**: Implement workflow logic in Justfile commands first, then port to GitHub Actions for fast iteration and testing.

## bootc Primer (Tips)

- Treat `/usr` as immutable at runtime; bootc bind-mounts it read-only.
- Only `/var` persists across upgrades; avoid relying on updates to existing `/var` files from new images.
- Standard writable paths are symlinks into `/var` (e.g. `/home` -> `/var/home`, `/opt` -> `/var/opt`).
- Use systemd `tmpfiles.d` or unit `StateDirectory=` to seed `/var` content on first boot.
- Prefer packaging static content into `/usr`; avoid dropping mutable content into `/var` during image builds.

## Host Service Identity Scheme

- Rootless service accounts should use namespaced host usernames such as `_nas_grafana` rather than upstream/vendor defaults like `grafana`
- Reserve `51000-51999` for image-managed service accounts in this repo
- Use category buckets inside that range: `511xx` for storage, `512xx` for observability, `513xx` for ingress/edge
- Current allocation: `_nas_grafana` uses host UID/GID `51210`; `_nas_vmalert` uses host UID/GID `51220`
- Subordinate ID ranges are a separate allocator, but keep them globally non-overlapping; the current convention is to derive a `65536`-wide range from the host UID for readability, e.g. `_nas_grafana:512100000:65536`

## Rootless Quadlet Note

Current state:
- Most active Quadlets in this repo are rootful system units under `overlay-root/etc/containers/systemd/`
- Grafana and vmalert are the current exceptions: they are defined as rootless admin-managed user Quadlets under `overlay-root/etc/containers/systemd/users/51210/grafana.container` and `overlay-root/etc/containers/systemd/users/51220/vmalert.container`

Useful reference points for future rootless work:
- The vendored `podman-systemd.unit.5.md` in this repo documents the rootless admin-managed Quadlet search paths under `/etc/containers/systemd/users/$(UID)` and `/etc/containers/systemd/users/`
- In practice, placing a user Quadlet under `/usr/share/containers/systemd/users/${UID}/` caused Fedora 43 with Podman 5.8.1 to generate a system unit in `system.slice`, because that path is still underneath the rootful `/usr/share/containers/systemd/` tree. Use `/etc/containers/systemd/users/${UID}/` for rootless service users in this repo.
- `sysusers.d` configuration belongs in `/usr/lib/sysusers.d` for packaged/vendor config; it is not a `/var` payload
- Rootless Podman expects subordinate ID ranges. This repo now ships explicit `_nas_grafana` and `_nas_vmalert` ranges in `/etc/subuid` and `/etc/subgid`
- If more rootless service users are added later, keep subordinate ID ranges non-overlapping and treat `/etc/subuid` and `/etc/subgid` as globally coordinated host resources
- linger state is managed by logind and lives under `/var/lib/systemd/linger`; `loginctl enable-linger` is the canonical interface even if a tmpfiles-based approach is possible
- Rootless user services should not depend directly on system units like `victoria-metrics.service`; cross-manager ordering is fragile, so prefer services that can tolerate starting independently, or use a bounded `ExecStartPre=` readiness loop when startup requires a local dependency to answer first
- Grafana's shipped provisioning and dashboards now live under `/usr/share/custom-coreos/grafana/` so they remain image-controlled rather than service-owned
- vmalert's shipped rules now live under `/usr/share/custom-coreos/vmalert/` so they remain image-controlled rather than service-owned
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
- **Files shared between containers** (e.g. `metrics_token` mounted by both Garage and VictoriaMetrics): use `:z` (shared). Using `:Z` causes the last container to start to steal the private label, breaking the other container.
- **Large ZFS-backed data directories**: do **not** use `:Z` or `:z` on the volume mount. Podman's recursive SELinux relabeling runs on every container start and will hang or timeout on large directories. Instead, label these at dataset creation time using `semanage fcontext` (with `-r s0` to specify the MCS range) to set a persistent policy rule, then `restorecon -F -R` to apply it. The `-F` flag is critical — without it, `restorecon` only resets the SELinux type (e.g. `container_file_t`) but does **not** clear MCS categories (e.g. `s0:c148,c350` left behind by a previous `:Z` mount). The ZFS creation scripts check a sample file inside each directory on every boot and only run the full recursive relabel when labels are actually wrong.

#### ZFS snapshots and SELinux

SELinux labels are stored as xattrs on files. ZFS snapshots capture xattrs. Rolling back a snapshot restores old labels, which may not match the current policy. After any ZFS rollback, run `restorecon -F -R` on the affected mountpoints to reapply the `semanage fcontext` policy (the `-F` ensures the full context including MCS range is reset). The policy itself lives in the SELinux policy store on the root filesystem, not on the ZFS dataset, so it survives rollbacks. Same applies to `zfs send/receive` — the receiving machine needs its own `semanage fcontext` rules.

## Quick Start

1. **Build locally**: `just build`
2. **Generate Ignition**: `just generate-ignition`
3. **Trigger CI build**: `just run-workflow`
4. **Install CoreOS**: Use `https://samhclark.github.io/custom-coreos/ignition.json`

## Troubleshooting

**Build failures**: Check `just check-zfs-available` - likely no prebuilt ZFS kmods for current versions
**Workflow failures**: Check `just all-workflows` for status
**Ignition issues**: Verify with `just generate-ignition` locally first
