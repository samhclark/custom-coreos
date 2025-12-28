# custom-coreos

A custom CoreOS container image with ZFS and Tailscale support, featuring automated CI/CD and encrypted storage configuration.

**Note**: Also did this one with Claude Code. I'll add more deets later, but in short, this..whole? conversion from jankiness before to what I got now took $10 and 2 hours?

```
Total cost:            $10.16
Total duration (API):  29m 58.2s
Total duration (wall): 1h 56m 42.8s
Total code changes:    1716 lines added, 311 lines removed
Usage by model:
    claude-3-5-haiku:  82.6k input, 3.2k output, 0 cache read, 0 cache write
       claude-sonnet:  866 input, 71.8k output, 18.4m cache read, 928.1k cache write
```

Might have taken me longer than 2 hours. Probably, tbh. I didn't do a lot of rework. Though, it also wasn't a ton of new lines, just a lot of copy-paste from the other repo. I betcha I would have burned too much time on the Pages setup, cause it's been so long.

## Overview

This project builds a production-ready CoreOS image with:
- **ZFS filesystem support** via prebuilt kernel modules
- **Tailscale VPN** for secure networking
- **LUKS encryption** with TPM2-based unlock
- **Automated CI/CD** with GitHub Actions
- **HTTP-served Ignition files** for easy installation

## Quick Start

### Installation

Use the pre-generated Ignition file during CoreOS installation:

```
https://samhclark.github.io/custom-coreos/ignition.json
```

This configures:
- LUKS encrypted root filesystem with TPM2 unlock (PCR 7)
- Btrfs filesystem on `/dev/mapper/root`
- SSH access for 'core' user
- Hostname set to 'nas'

### Container Image

The latest build is available at:

```
ghcr.io/samhclark/custom-coreos:stable
```

Updated daily with the latest CoreOS and ZFS versions.

## Development

### Prerequisites

- `just` (command runner)
- `podman` or `docker`
- `gh` (GitHub CLI)
- `skopeo`
- `jq`

### Common Commands

```bash
# Show all available commands
just

# Check current versions and compatibility
just versions

# Build locally  
just build

# Test build (removes image after)
just test-build

# Generate Ignition file from butane.yaml
just generate-ignition

# Trigger CI/CD workflows
just run-workflow        # Main build
just run-pages          # Ignition file deployment  
just run-cleanup        # Container cleanup (dry run)

# Check workflow status
just workflow-status    # Main build workflow
just all-workflows     # All workflows
```

### Local Development

```bash
# Check if prebuilt ZFS modules are available
just check-zfs-available

# View version information
just zfs-version         # Latest ZFS 2.3.x
just kernel-version      # Current CoreOS kernel (script-based fallback if labels are missing)
just versions           # All versions + compatibility

# Test cleanup logic locally  
just cleanup-dry-run 30  # 30-day retention test
```

## Architecture

### Build Process

**2-stage container build** using prebuilt ZFS kernel modules:

1. **Pull Prebuilt ZFS Modules**: Extract ZFS RPMs from fedora-zfs-kmods registry
2. **Final Assembly**: Install ZFS + Tailscale with inline kernel validation and service setup

### Dependencies

This project depends on [`fedora-zfs-kmods`](https://github.com/samhclark/fedora-zfs-kmods) for prebuilt ZFS kernel modules. If a compatible ZFS+kernel combination doesn't exist in that registry, the build will fail with a clear error message.

### Compatibility Strategy

**Registry-based compatibility**: No manual compatibility matrices to maintain. If `ghcr.io/samhclark/fedora-zfs-kmods:zfs-X.X.X_kernel-Y.Y.Y` exists, the combination is compatible.

## CI/CD Workflows

### Cosign Signing Keys

The resulting container images are signed by Cosign.
The keys were generated with the following command:

```
$ GITHUB_TOKEN="$(gh auth token)" COSIGN_PASSWORD="$(head -c 33 /dev/urandom | base64)" cosign generate-key-pair github://samhclark/custom-silverblue --output-file cosign.pub
Password written to COSIGN_PASSWORD github actions secret
Private key written to COSIGN_PRIVATE_KEY github actions secret
Public key written to COSIGN_PUBLIC_KEY github actions secret
Public key also written to cosign.pub
```

The key is included in the image at `/etc/pki/cosign/cosign.pub`. 
You can also download the key with:

```
wget https://raw.githubusercontent.com/samhclark/custom-coreos/refs/heads/main/overlay-root/etc/pki/cosign/cosign.pub
```

The SHA-256 checksum of the key that I originally created on August 16, 2025 is

```
$ sha256sum cosign.pub 
7fdb3c2b8159178046596fb49a4e95d42538bb6864595f7a6d789d9bd8837d38  cosign.pub
```

### Main Build (`build.yaml`)
- **Schedule**: Daily at 9:18 AM UTC
- **Trigger**: Manual via `just run-workflow` 
- **Output**: `ghcr.io/samhclark/custom-coreos:stable`
- **Features**: Automatic version discovery, compatibility checking, build attestations

### Ignition Files (`pages.yaml`)
- **Trigger**: Changes to `butane.yaml` + manual
- **Output**: `https://samhclark.github.io/custom-coreos/ignition.json`
- **Features**: Butane→Ignition conversion, GitHub Pages deployment

### Container Cleanup (`cleanup-images.yaml`)
- **Schedule**: Weekly on Sundays at 2 AM UTC
- **Retention**: 90 days
- **Safety**: Manual triggers default to dry-run mode

## Configuration

### Butane Configuration (`butane.yaml`)

The CoreOS configuration keeps host-specific settings and install-time storage setup. Service configuration is baked into the container image.

```yaml
variant: fcos
version: 1.6.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - [SSH key]
storage:
  luks:
    - name: root
      device: /dev/disk/by-partlabel/root
      clevis:
        custom:
          pin: tpm2
          config: '{"pcr_bank":"sha256","pcr_ids":"7"}'
  filesystems:
    - device: /dev/mapper/root
      format: btrfs
  files:
    - path: /etc/hostname
      contents:
        inline: nas
```

### Container Labels

Built images include labels for version tracking:
- `custom-coreos.zfs-version` - ZFS version used
- `custom-coreos.kernel-version` - Kernel version used

## Performance

- **Build Time**: ~2-3 minutes (down from 10+ minutes)
- **Size**: ~1.9 GB
- **Update Frequency**: Daily (automated)

## Security Features

- **LUKS Encryption**: Full disk encryption with TPM2-based unlock
- **SSH Access**: Key-based authentication only
- **Build Attestations**: Container provenance tracking
- **Signed Images**: Container image signing (sigstore)

## Installation Guide

### CoreOS Installation

1. **Download CoreOS ISO** from [Fedora CoreOS](https://fedoraproject.org/coreos/)
2. **Boot from ISO**
3. **Run installer** with Ignition URL:
   ```bash
   sudo coreos-installer install /dev/sda \
     --ignition-url https://samhclark.github.io/custom-coreos/ignition.json
   ```
4. **Reboot** - System will automatically configure encryption and services

### Post-Installation

The system will boot with:
- ✅ ZFS filesystem support loaded
- ✅ Tailscale daemon enabled (needs `tailscale up`)
- ✅ LUKS encryption with TPM2 unlock
- ✅ SSH access via provided key
- ✅ Hostname set to 'nas'

Configure Tailscale:
```bash
sudo tailscale up
```

Access Cockpit over Tailscale (localhost-only service):
```bash
# Option 1: SSH port-forward
ssh -L 9090:127.0.0.1:9090 core@nas

# Option 2: Tailscale serve (HTTPS on your tailnet)
sudo tailscale serve https / http://127.0.0.1:9090
```

## Troubleshooting

### Build Issues

**Problem**: Build fails with "No prebuilt ZFS kmods found"
**Solution**: Check [`fedora-zfs-kmods`](https://github.com/samhclark/fedora-zfs-kmods) - either the ZFS+kernel combination is incompatible or the build hasn't run yet.

**Problem**: Local build fails
**Solution**: Run `just check-zfs-available` to verify dependencies

### Workflow Issues

**Problem**: GitHub Actions workflow fails
**Solution**: Check status with `just all-workflows` and review specific job logs

**Problem**: Ignition file not updating
**Solution**: Verify GitHub Pages is enabled in repository settings

### Installation Issues

**Problem**: CoreOS won't boot after installation
**Solution**: Verify TPM2 is enabled in BIOS/UEFI settings

**Problem**: Can't SSH to system
**Solution**: Verify SSH key in `butane.yaml` matches your public key

## Contributing

1. **Local development**: Use `just build` and `just test-build`
2. **Configuration changes**: Update `butane.yaml` and test with `just generate-ignition`
3. **CI/CD changes**: Test workflow changes with manual triggers
4. **Version updates**: The system automatically tracks latest versions

## File Structure

```
├── Containerfile              # 2-stage build definition
├── butane.yaml               # CoreOS configuration
├── Justfile                  # Development commands
├── ignition.json            # Generated Ignition file (auto-updated)
├── .github/workflows/       # CI/CD workflows
│   ├── build.yaml          # Main container build
│   ├── pages.yaml          # Ignition file serving  
│   └── cleanup-images.yaml # Container registry cleanup
├── .ai/                    # AI assistant resources
│   ├── instructions/       # Agent instructions and guides
│   ├── plans/             # Development and testing plans
│   └── vendored-docs/     # Cached external documentation
└── README.md              # This file
```

## Links

- **Container Registry**: https://github.com/samhclark/custom-coreos/pkgs/container/custom-coreos
- **Ignition File**: https://samhclark.github.io/custom-coreos/ignition.json
- **GitHub Actions**: https://github.com/samhclark/custom-coreos/actions
- **ZFS Kernel Modules**: https://github.com/samhclark/fedora-zfs-kmods
