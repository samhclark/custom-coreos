# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## AI Resource Directory Structure

The `.ai/` directory contains AI-specific resources:
- `.ai/instructions/` - Reserved for agent instructions (currently empty; canonical instructions live in `AGENTS.md` at repo root)
- `.ai/plans/` - Development and testing plans (e.g., `butane-testing-plan.md`, `final-touches.md`, `future-enhancements.md`, `PROJECT-STATUS.md`)
- `.ai/vendored-docs/` - Cached external documentation (e.g., `butane-1.6.0-docs.txt`)

## Overview

This repository creates a custom CoreOS container image with ZFS, Tailscale, Cockpit management tooling, and encrypted storage support. The project has been **successfully overhauled** from a build-from-source approach to using prebuilt ZFS kernel modules with full CI/CD automation.

**Status**: ✅ **PRODUCTION READY** - All core functionality implemented and tested
**Build Time**: ~2-3 minutes (down from 10+ minutes)
**Container Registry**: `ghcr.io/samhclark/custom-coreos:stable`
**Ignition File**: `https://samhclark.github.io/custom-coreos/ignition.json`

## Project Relationship

This project depends on `../fedora-zfs-kmods/` which builds and publishes prebuilt ZFS kernel modules as container images. The architecture uses registry-based compatibility checking - if a ZFS+kernel combination exists in the fedora-zfs-kmods registry, it's compatible.

## Key Commands

### Version Discovery & Compatibility
- `just versions` - Show ZFS, kernel versions and compatibility status
- `just zfs-version` - Get latest ZFS 2.3.x release
- `just kernel-version` - Get current CoreOS kernel version
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
    rpm-ostree override remove nfs-utils-coreos \
        --install=cockpit-ostree \
        --install=cockpit-podman \
        --install=cockpit-system \
        --install=firewalld \
        --install=libnfsidmap \
        --install=sssd-nfs-idmap \
        --install=nfs-utils \
        --install=rbw \
        --install=tailscale && \
    rpm-ostree install \
        /zfs-rpms/*.$(rpm -qa kernel --queryformat '%{ARCH}').rpm \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm && \
    depmod -a "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
    echo "zfs" > /etc/modules-load.d/zfs.conf && \
    systemctl unmask firewalld && \
    systemctl enable firewalld.service && \
    systemctl enable tailscaled.service && \
    ostree container commit
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

**This is a hybrid bootc + CoreOS system requiring careful separation of configuration approaches.**

### Containerfile Configuration (System Capabilities)
Use the `Containerfile` for configuration that adds **capabilities** to the system:
- **Security**: Sigstore verification for `rpm-ostree upgrade` operations
- **System Services**: NTP configuration, chronyd settings
- **Package Installation**: ZFS modules, Cockpit tooling, firewalld, NFS utilities, Tailscale, RBW
- **Service Enablement**: firewalld, tailscaled

### Butane Configuration (Personal & Runtime)
Use `butane.yaml` for configuration that is **personal** or **cannot be described declaratively**:
- **Personal Settings**: SSH authorized keys, user password hash, hostname
- **Runtime Configuration**: LUKS encryption with TPM2 binding (PCRs)
- **Dynamic Filesystem**: Encrypted btrfs mounting, partition layouts
- **Boot-time Decisions**: Anything requiring runtime system state
- **Management**: Cockpit web service Quadlet (localhost-only by default)
- **Automation**: ZFS snapshot/health/scrub timers

### Current Configuration (`butane.yaml`)
- **Encryption**: LUKS root filesystem with TPM2 unlock (PCR 7)
- **Filesystem**: Btrfs on `/dev/mapper/root`
- **Access**: SSH key and password hash for 'core' user
- **Identity**: Hostname set to 'nas'
- **Tailscale**: Daemon enabled for primary remote access
- **Cockpit**: Rootful `quay.io/cockpit/ws` container bound to `127.0.0.1:9090` (intended for Tailscale access)
- **ZFS**: Snapshot timers for `videos` dataset, health check + scrub timers enabled

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
- `Containerfile` - 2-stage build definition (60 lines, streamlined)
- `butane.yaml` - Fedora CoreOS configuration with encryption and service setup
- `Justfile` - Comprehensive development commands
- `ignition.json` - Generated Ignition file (auto-updated)
- `overlay-root/` - Systemd units, ZFS scripts, cosign policy files
- `scripts/query-coreos-kernel.sh` - Kernel version discovery helper

### CI/CD Workflows
- `.github/workflows/build.yaml` - Main container build
- `.github/workflows/pages.yaml` - Ignition file serving
- `.github/workflows/cleanup-images.yaml` - Registry maintenance

### Documentation
- `AGENTS.md` - This file
- `README.md` - User documentation
- `.ai/plans/PROJECT-STATUS.md` - Current project status
- `.ai/plans/final-touches.md` - Remaining NAS/monitoring items
- `.ai/plans/future-enhancements.md` - Optional future work

## Development Patterns

**Registry-First Compatibility**: Let the container registry be the source of truth for ZFS+kernel compatibility rather than maintaining duplicate matrices.

**Local-First CI/CD Development**: Implement workflow logic in Justfile commands first, then port to GitHub Actions for fast iteration and testing.

## Build Performance

- **Previous**: 10+ minutes (ZFS compilation from source)
- **Current**: 2-3 minutes (prebuilt RPM consumption)
- **Improvement**: 70%+ reduction in build time

## Security Features

- **Encryption**: LUKS root filesystem with TPM2-based unlock
- **Build Security**: Container image signing and attestations
- **Access Control**: SSH key-based authentication
- **Tailscale**: Daemon enabled (auth/config via runtime)

## Project Status

**Implementation Status**: ✅ **COMPLETE** (core build + CI/CD)

**Production Ready**:
- ✅ Container builds and publishes successfully
- ✅ Ignition files generate and serve over HTTP
- ✅ ZFS snapshot + health automation enabled
- ✅ Local development workflow complete

**Open Items** (see `.ai/plans/final-touches.md`):
- SMART monitoring (smartmontools + timers)
- Decide Cockpit access model (localhost-only vs LAN exposure)

## Quick Start

1. **Build locally**: `just build`
2. **Generate Ignition**: `just generate-ignition`
3. **Trigger CI build**: `just run-workflow`
4. **Install CoreOS**: Use `https://samhclark.github.io/custom-coreos/ignition.json`

## Troubleshooting

**Build failures**: Check `just check-zfs-available` - likely no prebuilt ZFS kmods for current versions
**Workflow failures**: Check `just all-workflows` for status
**Ignition issues**: Verify with `just generate-ignition` locally first
