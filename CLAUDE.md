# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository creates a custom CoreOS container image with ZFS and Tailscale support. It is currently undergoing a major architectural overhaul to use prebuilt ZFS kernel modules and implement CI/CD workflows.

**Current State**: Traditional build-from-source approach with ~10+ minute build times
**Future State**: Streamlined build using prebuilt RPMs with ~2-3 minute build times

## Project Relationship

This project has a sibling dependency on `../fedora-zfs-kmods/` which builds and publishes prebuilt ZFS kernel modules as container images. The overhaul plan transitions this project from building ZFS from source to consuming those prebuilt RPMs.

## Key Commands (Current)

- `just` - Show available commands (default recipe)
- `just butane` - Run Butane to process configuration files using podman
- `podman build --build-arg ZFS_VERSION=<version> .` - Build the custom CoreOS image

## Key Commands (Planned)

- `just versions` - Show ZFS, kernel versions and compatibility status
- `just check-compatibility` - Verify ZFS/kernel compatibility matrix
- `just build` - Build with automatic version discovery
- `just generate-ignition` - Generate Ignition files for CoreOS installation
- `just run-workflow` - Trigger GitHub Actions build

## Architecture (Current)

The project consists of three main components:

1. **Multi-stage Containerfile build process:**
   - Stage 1: Query CoreOS kernel version and validate compatibility
   - Stage 2: Build ZFS kernel modules from source using Fedora base image (10+ minutes)
   - Stage 3: Final image assembly (currently commented out)

2. **Butane configuration (butane.yaml):**
   - Configures encrypted LUKS root filesystem with TPM2 unlock
   - Sets up btrfs filesystem
   - Configures SSH keys for 'core' user
   - Sets hostname to 'nas'

3. **Overlay filesystem (overlay-root/):**
   - Tailscale repository configuration
   - GPG key for package verification

## Architecture (Planned)

**2-stage build process** consuming prebuilt ZFS RPMs:

1. **Stage 1 (kernel-query)**: Validate CoreOS kernel version and compatibility
2. **Stage 2 (final-image)**: Install prebuilt ZFS RPMs from `ghcr.io/samhclark/fedora-zfs-kmods`

**Integration Pattern:**
```dockerfile
FROM ghcr.io/samhclark/fedora-zfs-kmods:zfs-${ZFS_VERSION}_kernel-${KERNEL_VERSION} as zfs-rpms

FROM quay.io/fedora/fedora-coreos:stable
RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
    rpm-ostree install -y \
        tailscale \
        /zfs-rpms/*.$(rpm -qa kernel --queryformat '%{ARCH}').rpm \
        /zfs-rpms/*.noarch.rpm \
        /zfs-rpms/other/zfs-dracut-*.noarch.rpm
```

## Butane and Ignition Workflow

**Critical Requirement**: CoreOS requires Ignition files for installation. This project must maintain:

1. **butane.yaml**: Human-readable CoreOS configuration
2. **Ignition generation**: Convert Butane to Ignition JSON
3. **HTTP serving**: Serve Ignition files via GitHub Pages for installation access

**Installation Pattern**: CoreOS installer fetches Ignition file over HTTP during installation.

## Version Compatibility

**Compatibility Matrix**: ZFS versions have maximum supported kernel versions:
- Must validate ZFS + kernel compatibility before builds
- Fedora version is not a concern for this project
- Build should fail if no suitable `fedora-zfs-kmods` image exists

**Example Compatibility**:
```bash
declare -A compatibility_matrix=(
    ["zfs-2.3.3"]="6.15"
    ["zfs-2.3.2"]="6.14"
    # ... additional mappings
)
```

## CI/CD Strategy (Planned)

**Single Tag Approach**: Maintain only `stable` tag (no versioned tags)
- Daily builds at 6 AM UTC
- Single `stable` tag overwrites on each successful build
- Build attestations for security verification
- 90-day image retention policy

**Workflow Jobs**:
1. **query-versions**: Discover current ZFS and kernel versions
2. **build**: Build and push with single `stable` tag

## Deduplication Strategy

**Current Plan**: No immediate deduplication (simplified initial implementation)
**Future Enhancement**: Check CoreOS version + ZFS version combination
- Extract CoreOS version from container labels (not tags)
- Skip builds when identical combination already exists
- Add container labeling to track parent image versions

## Key Files

### Current Files
- `Containerfile` - Multi-stage build definition
- `butane.yaml` - Fedora CoreOS configuration 
- `Justfile` - Task runner configuration
- `zfs-reproducible.patch` - Ensures reproducible ZFS builds (will be removed)
- `overlay-root/` - Files to overlay onto the final image

### Planned Files
- `.github/workflows/build.yaml` - Main CI/CD workflow
- `.github/workflows/pages.yaml` - Ignition file generation and serving
- `.github/workflows/cleanup-images.yaml` - Container registry cleanup
- `build-overhaul.md` - Detailed implementation plan

## Development Patterns

**Local-First CI/CD Development**: Implement workflow logic in Justfile commands first, then port to GitHub Actions. This enables:
- Fast iteration without expensive Actions runs
- Local testing and debugging of complex logic
- Immediate feedback on command syntax and API responses

## Build Performance Goals

- **Current**: 10+ minutes (ZFS compilation from source)
- **Target**: 2-3 minutes (prebuilt RPM consumption)
- **Improvement**: 70%+ reduction in build time

## Security Considerations

- Build attestations with GitHub Actions
- Container image signing and verification
- Encrypted storage with TPM2 unlock
- SSH key management for 'core' user access

## Project Status

**Phase**: Planning and architectural overhaul
**Documentation**: Complete implementation plan in `build-overhaul.md`
**Dependencies**: Requires `fedora-zfs-kmods` project for prebuilt RPMs
**Timeline**: 8-phase implementation plan with 25+ discrete steps