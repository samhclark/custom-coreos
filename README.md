# nas

A NAS container image for my personal NAS, open sourced as a reference project rather than a general-purpose distribution.

## Overview

This project builds a bootc image with:
- **ZFS filesystem support** via prebuilt kernel modules
- **Tailscale VPN** for secure networking
- **LUKS encryption** with TPM2-based unlock
- **Automated CI/CD** with GitHub Actions
- **HTTP-served Ignition files** for easy installation

This repository is primarily a record of one working system design. It is useful as a reference, but the checked-in configuration is intentionally machine-specific and not meant to be drop-in for other people.

## Quick Start

### Installation

Use the pre-generated Ignition file during Fedora CoreOS installation:

```
https://samhclark.github.io/nas/ignition.json
```

This configures:
- LUKS encrypted root filesystem with TPM2 unlock, without PCR binding
- Btrfs filesystem on `/dev/mapper/root`
- SSH access for 'core' user
- Hostname set to 'nas'

The published Ignition file and [`butane.yaml`](butane.yaml) are personal
configuration for one machine, not a generic installer profile.

### Container Image

The latest build is available at:

```
ghcr.io/samhclark/nas/bootc:stable
```

Updated daily with the latest Fedora CoreOS and ZFS versions.

### Overall steps to install

1. Install Fedora CoreOS on the machine (using the above Ignition file if you're me)
2. Switch to NAS: `sudo bootc switch ghcr.io/samhclark/nas/bootc:stable`
3. Reboot
4. Switch to _signed_ NAS: `sudo bootc switch --enforce-container-sigpolicy ghcr.io/samhclark/nas/bootc:stable`
5. Reboot
6. Log in to Tailscale, set up SSH access: `sudo tailscale login` and `sudo tailscale set --ssh`
7. Configure auto unlocking for the attached data drives
  a. Set up TPM unlock: `sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-id/wwn-0x5000c500c6ef9bbf`
  b. Test if it worked: `sudo /usr/lib/systemd/systemd-cryptsetup attach ef9bbf_crypt /dev/disk/by-id/wwn-0x5000c500c6ef9bbf none tpm2-device=auto` 
  c. If it worked, add that line to crypttab: `echo "ef9bbf_crypt /dev/disk/by-id/wwn-0x5000c500c6ef9bbf none tpm2-device=auto" | sudo tee -a /etc/crypttab`
8. Reboot; Import the ZFS pool: `sudo zpool import tank` 

### Scope

This is not intended to be a polished appliance for other people. It is my own NAS image, with my own service mix, hostname, and operational assumptions, published mainly so the approach and implementation details are visible.


## Development

### Prerequisites

- `make` (GNU Make, standard on Linux)
- Docker Engine with Buildx (image builds)
- `podman` (repository checks and runtime-oriented tests)
- `gh` (GitHub CLI)
- `skopeo`
- `jq`
- `uv` (Python and the locked development environment are managed automatically)

### Common Commands

```bash
# Show all available commands
make help

# Check static contracts without changing the repository
make check

# Run behavioral tests
make test

# Build locally
make build

# Trigger the production publishing workflow
make publish

# Generate Ignition file from butane.yaml
make generate-ignition

# Trigger CI/CD workflows
make run-workflow        # Main build
make run-pages          # Ignition file deployment
make run-cleanup        # Container cleanup (dry run)

# Check workflow status
make workflow-status    # Main build workflow
make all-workflows      # All workflows
```

`make build` uses the currently selected Buildx builder and loads the result
into Docker for exact-image verification. For the same `docker-container`
driver used by CI, create and select a local builder once:

```bash
docker buildx create --name nas --driver docker-container --use --bootstrap
```

### Local Development

```bash
# Verify current upstream inputs and prebuilt ZFS modules
make check-zfs-available

# View version information
make zfs-version         # Latest ZFS version
make kernel-version      # Current CoreOS kernel (script-based fallback if labels are missing)
make versions            # All versions + compatibility

# Test cleanup logic locally
make cleanup-dry-run RETENTION_DAYS=90
```

## Architecture

### Build Process

**4-stage container build** using prebuilt ZFS kernel modules:

1. **Patched crun builder**: Build the pinned crun release with the narrow
   `krun.tap_name` integration patch.
2. **SOPS binary source**: Import the pinned SOPS binary from the upstream
   image whose signature CI verifies.
3. **Prebuilt ZFS modules**: Pull the matching ZFS RPM image from the
   `fedora-zfs-kmods` registry.
4. **Final image assembly**: Install the host packages and ZFS RPMs, copy the
   runtime overlay, enable units, install SELinux policy, and run bootc lint.

### Dependencies

This project depends on [`fedora-zfs-kmods`](https://github.com/samhclark/fedora-zfs-kmods) for prebuilt ZFS kernel modules. If a compatible ZFS+kernel combination doesn't exist in that registry, the build will fail with a clear error message.

### Compatibility Strategy

**Registry-based compatibility**: No manual compatibility matrices to maintain. If `ghcr.io/samhclark/fedora-zfs-kmods:zfs-X.X.X_kernel-Y.Y.Y` exists, the combination is compatible.

## CI/CD Workflows

### Cosign Signing Keys

The resulting container images are signed by Cosign.
The keys were generated with the following command:

```
$ GITHUB_TOKEN="$(gh auth token)" COSIGN_PASSWORD="$(head -c 33 /dev/urandom | base64)" cosign generate-key-pair github://samhclark/nas --output-file cosign.pub
Password written to COSIGN_PASSWORD github actions secret
Private key written to COSIGN_PRIVATE_KEY github actions secret
Public key written to COSIGN_PUBLIC_KEY github actions secret
Public key also written to cosign.pub
```

The key is included in the image at `/etc/pki/cosign/cosign.pub`. 
You can also download the key with:

```
wget https://raw.githubusercontent.com/samhclark/nas/refs/heads/main/overlay-root/etc/pki/cosign/cosign.pub
```

The SHA-256 checksum of the key that I originally created on August 16, 2025 is

```
$ sha256sum cosign.pub 
7fdb3c2b8159178046596fb49a4e95d42538bb6864595f7a6d789d9bd8837d38  cosign.pub
```

During the repository rename, `/etc/containers/policy.json` retains signed
image rules for both `ghcr.io/samhclark/custom-coreos` and
`ghcr.io/samhclark/nas/bootc`. The existing empty-repository fallback permits the
initial transition pull; once the NAS image is running, pulls from the new
repository match its explicit signed-image rule. Keep the old rule while
rollback to the previous deployment remains necessary.

### Main Build (`build.yaml`)
- **Schedule**: Daily at 9:18 AM UTC
- **Trigger**: Manual via `make run-workflow`
- **Output**: `ghcr.io/samhclark/nas/bootc:stable`
- **Features**: Automatic version discovery, compatibility checking, build attestations

### Ignition Files (`pages.yaml`)
- **Trigger**: Changes to `butane.yaml`, its Make target, or the Pages template + manual
- **Output**: `https://samhclark.github.io/nas/ignition.json`
- **Features**: Butane→Ignition conversion, GitHub Pages deployment

### Container Cleanup (`cleanup-images.yaml`)
- **Schedule**: Weekly on Sundays at 2 AM UTC
- **Retention**: 90 days
- **Targets**: `nas/bootc` and the legacy `custom-coreos` package
- **Safety**: Manual triggers default to dry-run mode

## Configuration

### Butane Configuration (`butane.yaml`)

The Butane configuration keeps host-specific settings and install-time storage setup. Service configuration is baked into the container image.

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
      label: luks-root
      device: /dev/disk/by-partlabel/root
      clevis:
        tpm2: true
      wipe_volume: true
  filesystems:
    - device: /dev/mapper/root
      format: btrfs
      wipe_filesystem: true
      label: root
  files:
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: nas
```

Root unlock is TPM-backed but deliberately not bound to PCR values. Binding only some PCRs turned out to be operationally painful after updates and did not match the actual threat model for this machine.

### Manual Bootstrap

Some parts of the system are still intentionally bootstrapped by hand after installation:
- Additional encrypted data volumes are enrolled with TPM manually.
- The SOPS age private key credential is installed manually on the NAS at `/var/lib/nas-secrets/age-key.cred`.
- Per-service runtime secret files are distributed at boot from the repo-managed SOPS file at `/usr/share/nas/secrets/secrets.sops.yaml`.

### Host Service UIDs

Rootless service accounts use namespaced host usernames and a reserved high UID range so they are easy to recognize and unlikely to collide with random software defaults.

- Reserve `51000-51999` for image-managed service accounts.
- Use `511xx` for storage, `512xx` for observability, and `513xx` for ingress/edge.
- Prefer names such as `_nas_grafana` over upstream defaults such as `grafana`.
- UIDs are allocate-only: never reuse a UID from a retired service, because numeric file ownership (especially inside ZFS snapshots) outlives the user.
- Rootless Quadlets for image-managed service users belong under `/etc/containers/systemd/users/$UID/`, not under `/usr/share/containers/systemd/users/$UID/`.
- `quadlets/*.toml` and `AGENTS.md` are the allocation sources of truth; see
  `docs/development/rootless-quadlets.md` for the compiler-driven service workflow.

That bootstrap path is not especially elegant, but it is acceptable for a single-user personal system.

### Container Labels

Built images include labels for version tracking:
- `nas.bootc.zfs-version` - ZFS version used
- `nas.bootc.kernel-version` - Kernel version used

## Performance

- **Build Time**: ~2-3 minutes (down from 10+ minutes)
- **Size**: ~1.9 GB
- **Update Frequency**: Daily (automated)

## Security Features

- **LUKS Encryption**: Full disk encryption with TPM2-based unlock, without PCR binding
- **SSH Access**: Key-based authentication only
- **Build Attestations**: Container provenance tracking
- **Signed Images**: Container image signing (sigstore)

## Installation Guide

### Fedora CoreOS Installation

1. **Download the Fedora CoreOS ISO** from [Fedora CoreOS](https://fedoraproject.org/coreos/)
2. **Boot from ISO**
3. **Run installer** with Ignition URL:
   ```bash
   sudo coreos-installer install /dev/sda \
     --ignition-url https://samhclark.github.io/nas/ignition.json
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

Additional post-install steps still happen manually over SSH:
- Install the SOPS age private key credential at `/var/lib/nas-secrets/age-key.cred`
- Verify `sops-distribute-secrets.service` populated the per-service files under `/run/nas-secrets/`
- Enroll any non-root LUKS volumes with TPM and add them to `crypttab`
- Import the ZFS pool if it is not imported automatically

### `/usr/local` Note

Fedora CoreOS normally points `/usr/local` at `/var/usrlocal`, but this image intentionally ships image-managed admin scripts and helpers under `overlay-root/usr/local/`. On the deployed NAS, `/usr/local` is a real immutable directory under `/usr`, not a writable `/var` symlink.

## Troubleshooting

### Build Issues

**Problem**: Build fails with "No prebuilt ZFS kmods found"
**Solution**: Check [`fedora-zfs-kmods`](https://github.com/samhclark/fedora-zfs-kmods) - either the ZFS+kernel combination is incompatible or the build hasn't run yet.

**Problem**: Local build fails
**Solution**: Run `make check-zfs-available` to verify ZFS kmod availability

### Workflow Issues

**Problem**: GitHub Actions workflow fails
**Solution**: Check status with `make all-workflows` and review specific job logs

**Problem**: Ignition file not updating
**Solution**: Verify GitHub Pages is enabled in repository settings

### Installation Issues

**Problem**: The NAS image won't boot after installation
**Solution**: Verify TPM2 is enabled in BIOS/UEFI settings

**Problem**: Can't SSH to system
**Solution**: Verify SSH key in `butane.yaml` matches your public key

### SELinux Issues

**Problem**: SELinux denies a service action (AVC in logs)
**Solution**: Capture the AVC and add a minimal policy module to the image.

Capture AVCs:
```bash
sudo ausearch -m avc -ts boot
sudo journalctl -t setroubleshoot -b --no-pager
```

Optional (debug-only) policy generation:
```bash
sudo ausearch -m avc -ts boot | audit2allow -M local-selinux-fix
```

Apply fix declaratively:
1. Add a CIL rule under `overlay-root/usr/share/selinux/targeted/`.
2. Install it in `Containerfile` with `semodule -i /usr/share/selinux/targeted/<name>.cil`.
3. Rebuild (`make build`) and redeploy.

## Contributing

1. **Local development**: Run `make check`, `make test`, and `make build`
2. **Configuration changes**: Update `butane.yaml` and test with `make generate-ignition`
3. **CI/CD changes**: Test workflow changes with manual triggers
4. **Version updates**: The system automatically tracks latest versions

## File Structure

```
├── Containerfile              # Four-stage bootc image build
├── butane.yaml               # Fedora CoreOS configuration
├── Makefile                  # Development commands
├── ignition.json            # Locally generated and gitignored
├── quadlets/                # Declarative service sources
├── quadletgen/              # Typed fleet compiler
├── .github/workflows/       # CI/CD workflows
│   ├── build.yaml          # Main container build
│   ├── pages.yaml          # Ignition file serving  
│   └── cleanup-images.yaml # Container registry cleanup
├── vendored-docs/         # Cached external documentation
└── README.md              # This file
```

## Links

- **Container Registry**: https://github.com/samhclark/nas/pkgs/container/bootc
- **Ignition File**: https://samhclark.github.io/nas/ignition.json
- **GitHub Actions**: https://github.com/samhclark/nas/actions
- **ZFS Kernel Modules**: https://github.com/samhclark/fedora-zfs-kmods
