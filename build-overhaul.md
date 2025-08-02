# Build Overhaul Plan

## Overview

This plan overhauls the custom CoreOS build to use prebuilt ZFS kernel modules from the `fedora-zfs-kmods` project and implements CI/CD with a single `stable` tag approach inspired by CoreOS itself.

## High-Level Goals

1. **Replace Stage 2 ZFS Build**: Use prebuilt ZFS kmods from `ghcr.io/samhclark/fedora-zfs-kmods` instead of building from source
2. **Implement CI/CD**: Create GitHub Actions workflows based on the `fedora-zfs-kmods` approach
3. **Single Tag Strategy**: Maintain only a `stable` tag that gets updated with each successful build
4. **Automated Builds**: Daily scheduled builds with force rebuild options

## Detailed Implementation Steps

### Phase 1: Container Build Overhaul

#### Step 1.1: Update Containerfile Architecture
- **File**: `Containerfile`
- **Action**: Replace Stage 2 (ZFS build from source) with prebuilt RPM consumption
- **Details**:
  - Keep Stage 1 (kernel-query) for version validation
  - Replace ~40 lines of ZFS build with 3-4 lines of RPM installation using bind mounts
  - Uncomment and update Stage 3 (final image assembly)
  - Add proper `depmod` and ZFS module loading configuration
  - Add container labels with parent CoreOS version for future deduplication

#### Step 1.2: Add Required Build Arguments
- **File**: `Containerfile`
- **Action**: Add `ZFS_VERSION` build argument (similar to existing `KERNEL_MAJOR_MINOR`)
- **Details**:
  - Remove hardcoded ZFS version references
  - Ensure all build args are required (no defaults)
  - Format: `ARG ZFS_VERSION` (e.g., "2.3.3")

#### Step 1.3: Update ZFS Integration Pattern
- **File**: `Containerfile`
- **Action**: Implement the bootc integration pattern from `fedora-zfs-kmods`
- **Details**:
  ```dockerfile
  FROM ghcr.io/samhclark/fedora-zfs-kmods:zfs-${ZFS_VERSION}_kernel-${KERNEL_VERSION} as zfs-rpms
  
  FROM quay.io/fedora/fedora-coreos:stable
  COPY overlay-root/ /
  RUN --mount=type=bind,from=zfs-rpms,source=/,target=/zfs-rpms \
      --mount=type=bind,from=kernel-query,source=/kernel-version.txt,target=/kernel-version.txt \
      rpm-ostree install -y \
          tailscale \
          /zfs-rpms/*.$(rpm -qa kernel --queryformat '%{ARCH}').rpm \
          /zfs-rpms/*.noarch.rpm \
          /zfs-rpms/other/zfs-dracut-*.noarch.rpm && \
      depmod -a "$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
      echo "zfs" > /etc/modules-load.d/zfs.conf && \
      rm -rf /var/lib/pcp && \
      systemctl enable tailscaled && \
      ostree container commit
  ```

### Phase 2: Development Tooling

#### Step 2.1: Enhance Justfile with Version Discovery
- **File**: `Justfile`
- **Action**: Add comprehensive version management commands inspired by `fedora-zfs-kmods`
- **Details**:
  - Add `zfs-version` command (latest ZFS 2.3.x)
  - Add `kernel-version` command using skopeo inspection
  - Add `kernel-major-minor` command
  - Add `versions` command showing all versions and compatibility
  - Add `check-compatibility` with ZFS/kernel compatibility matrix
  - Keep existing `butane` command for Ignition file generation

#### Step 2.2: Add Butane Processing
- **File**: `Justfile`
- **Action**: Enhance Butane workflow for Ignition file generation
- **Details**:
  - Keep existing `butane` command for converting butane.yaml to Ignition JSON
  - Add `generate-ignition` command for creating deployable Ignition files
  - Add local build commands with compatibility checking
  - Add `test-build` for quick validation

#### Step 2.3: Add Build Commands
- **File**: `Justfile`
- **Action**: Add comprehensive build workflow alongside existing Butane commands
- **Details**:
  - Add `build` command with automatic version discovery
  - Add `build-force` to override existing containers
  - Add `run-workflow` and `workflow-status` for CI integration

### Phase 3: GitHub Actions CI/CD

#### Step 3.1: Create Main Build Workflow
- **File**: `.github/workflows/build.yaml`
- **Action**: Create 2-job workflow based on `fedora-zfs-kmods` pattern
- **Details**:
  - **Job 1 (query-versions)**: Discover ZFS and kernel versions using skopeo and GitHub API
  - **Job 2 (build)**: Build and push with attestations, single `stable` tag
  - Include ZFS/kernel compatibility matrix (identical to Justfile)
  - Fail build if no suitable fedora-zfs-kmods image exists for ZFS+kernel combination
  - Add force rebuild option via `workflow_dispatch`

#### Step 3.2: Configure Container Registry Settings
- **File**: `.github/workflows/build.yaml`
- **Action**: Set up GitHub Container Registry integration
- **Details**:
  - Registry: `ghcr.io`
  - Image name: `${{ github.repository }}` (resolves to `samhclark/custom-coreos`)
  - Single tag: `stable` (overwrites on each successful build)
  - Enable build attestations with proper permissions

#### Step 3.3: Add Scheduled Builds
- **File**: `.github/workflows/build.yaml`
- **Action**: Configure automated daily builds
- **Details**:
  - Schedule: Daily at 6 AM UTC (same as `fedora-zfs-kmods`)
  - Manual override: `force_rebuild` input parameter

### Phase 4: Container Image Management

#### Step 4.1: Create Image Cleanup Workflow
- **File**: `.github/workflows/cleanup-images.yaml`
- **Action**: Weekly cleanup to maintain registry hygiene
- **Details**:
  - Schedule: Weekly on Sundays at 2 AM UTC
  - Retention: Keep last 90 days of images
  - Simple cleanup logic since only one `stable` tag exists

#### Step 4.2: Add Ignition File Generation Workflow
- **File**: `.github/workflows/pages.yaml`
- **Action**: Generate and publish Ignition files for CoreOS installation
- **Details**:
  - Generate Ignition JSON from butane.yaml on push to main
  - Publish to GitHub Pages for HTTP access during CoreOS installation
  - Use same pattern as gh-pages branch deployment

### Phase 5: Ignition File Management

#### Step 5.1: Butane Configuration Maintenance
- **File**: `butane.yaml`
- **Action**: Ensure Butane configuration remains functional
- **Details**:
  - Verify encrypted LUKS root filesystem configuration
  - Maintain TPM2 unlock configuration
  - Ensure SSH key and hostname settings are preserved
  - Test Butane to Ignition conversion process

#### Step 5.2: HTTP Ignition Serving
- **Action**: Set up HTTP serving of Ignition files for CoreOS installation
- **Details**:
  - Use GitHub Pages pattern for serving generated Ignition files
  - Ensure Ignition files are accessible via HTTP during CoreOS installation
  - Document the installation process using the hosted Ignition file

### Phase 6: Documentation and Configuration

#### Step 6.1: Update CLAUDE.md
- **File**: `CLAUDE.md`
- **Action**: Update architecture documentation to reflect new build process
- **Details**:
  - Document the 2-stage build (vs previous 3-stage)
  - Explain prebuilt ZFS RPM consumption
  - Update key commands section with new Justfile recipes
  - Document CI/CD workflow and single tag strategy
  - Document Butane/Ignition workflow and HTTP serving pattern

#### Step 6.2: Update README.md
- **File**: `README.md`
- **Action**: Expand documentation for new build process
- **Details**:
  - Explain relationship with `fedora-zfs-kmods` dependency
  - Document version compatibility requirements (ZFS + kernel, not Fedora)
  - Add CI/CD usage instructions
  - Document CoreOS installation process using HTTP-served Ignition files
  - Include troubleshooting section for compatibility issues

#### Step 6.3: Create GitHub Repository Settings
- **Action**: Configure repository for CI/CD
- **Details**:
  - Enable GitHub Actions
  - Configure container registry permissions
  - Set up automated security updates
  - Configure branch protection if needed

### Phase 7: Setup and Validation

#### Step 7.1: Dependencies Verification
- **Action**: Ensure all required tools are available for development
- **Details**:
  - Verify `just`, `podman`, `gh`, `skopeo`, `jq` availability
  - Verify `butane` is available for Ignition file generation
  - Test GitHub CLI authentication
  - Validate container registry access
  - Test GitHub Pages deployment permissions

#### Step 7.2: Compatibility Matrix Setup
- **Action**: Initialize ZFS/kernel compatibility tracking
- **Details**:
  - Start with current compatibility matrix from `fedora-zfs-kmods`
  - Document update process for new ZFS releases
  - Test compatibility checking logic locally

#### Step 7.3: Initial CI/CD Testing
- **Action**: Validate workflow functionality before production use
- **Details**:
  - Test version discovery job locally using Justfile commands
  - Perform dry-run builds to verify container integration
  - Test manual workflow trigger and force rebuild options
  - Validate Butane to Ignition conversion workflow
  - Test GitHub Pages deployment of Ignition files

### Phase 8: Migration and Cleanup

#### Step 8.1: Remove Obsolete Build Components
- **File**: `Containerfile`
- **Action**: Clean up old ZFS build artifacts
- **Details**:
  - Remove `zfs-reproducible.patch` (no longer needed)
  - Remove ZFS build dependencies from Stage 2
  - Verify overlay-root structure still correct

#### Step 8.2: Validate Final Build Output
- **Action**: Ensure feature parity with previous build approach
- **Details**:
  - Verify ZFS modules load correctly
  - Test Tailscale installation and service enablement
  - Confirm Butane configuration processes correctly to Ignition JSON
  - Test CoreOS installation using generated Ignition file
  - Validate bootc compatibility and encrypted storage setup

### Phase 9: Optional Enhancements (Future)

#### Step 9.1: Advanced Duplicate Detection
- **File**: `.github/workflows/build.yaml`
- **Action**: Implement sophisticated build deduplication (optional future enhancement)
- **Details**:
  - Check for existing containers based on CoreOS version + ZFS version combination
  - Extract CoreOS version from container labels (not tags)
  - Skip builds when identical CoreOS+ZFS combination already exists
  - Add container labeling to track parent CoreOS image versions
  - **Note**: This is not critical for initial implementation and can be added later

## Expected Outcomes

### Build Performance
- **Speed**: Reduce build time from ~10+ minutes to ~2-3 minutes
- **Reliability**: Eliminate ZFS compilation failures and dependency issues
- **Caching**: Leverage prebuilt RPMs for consistent builds across versions

### CI/CD Benefits
- **Automation**: Daily builds with automated triggering
- **Consistency**: Single `stable` tag matching CoreOS approach
- **Security**: Build attestations and provenance tracking
- **Maintenance**: Automated cleanup of old container images
- **Ignition Serving**: Automated generation and serving of CoreOS installation files

### Development Experience
- **Local Testing**: Rich Justfile commands for version discovery and compatibility
- **Debugging**: Clear error messages for version mismatches
- **Flexibility**: Manual override options for testing and emergency builds

## Risk Mitigation

### Version Compatibility
- **Risk**: ZFS/kernel version mismatches causing boot failures
- **Mitigation**: Compatibility matrix validation in both local and CI builds
- **Fallback**: Manual build with force options if automated compatibility fails

### Dependency Management
- **Risk**: `fedora-zfs-kmods` container unavailable or incompatible
- **Mitigation**: Early version validation and clear error messages
- **Fallback**: Can temporarily revert to source builds if needed

### CI/CD Reliability
- **Risk**: GitHub Actions failures disrupting daily builds
- **Mitigation**: Comprehensive error handling and manual trigger options
- **Monitoring**: Workflow status tracking and notification setup

## Success Criteria

1. ✅ **Containerfile builds successfully** with prebuilt ZFS RPMs
2. ✅ **Local development workflow** with version discovery and compatibility checking  
3. ✅ **CI/CD pipeline** with daily builds and single tag management
4. ✅ **Butane/Ignition workflow** maintained for CoreOS installation
5. ✅ **Build performance** improved by 70%+ (2-3 min vs 10+ min)
6. ✅ **Feature parity** with current custom CoreOS image (ZFS + Tailscale + encryption)
7. ✅ **Documentation updated** reflecting new architecture and workflows
8. ✅ **HTTP serving** of Ignition files for CoreOS installation