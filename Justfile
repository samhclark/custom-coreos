# just manual: https://github.com/casey/just/#readme

_default:
    @just --list

# Get the latest ZFS 2.3.x version tag
zfs-version:
    gh release list \
        --repo openzfs/zfs \
        --json tagName \
        -q '.[] | select(.tagName | startswith("zfs-2.3")) | .tagName' \
        --limit 1

# Get kernel version from Fedora CoreOS stable (super fast with remote inspection)
kernel-version:
    skopeo inspect docker://quay.io/fedora/fedora-coreos:stable | jq -r '.Labels."ostree.linux"'

# Get kernel major.minor version
kernel-major-minor:
    #!/usr/bin/env bash
    KERNEL_VERSION=$(skopeo inspect docker://quay.io/fedora/fedora-coreos:stable | jq -r '.Labels."ostree.linux"')
    echo "$KERNEL_VERSION" | cut -d'.' -f1-2

# Check if prebuilt ZFS kmods exist for current versions
check-zfs-available:
    #!/usr/bin/env bash
    ZFS_VERSION=$(just zfs-version | sed 's/^zfs-//')
    KERNEL_VERSION=$(just kernel-version)
    IMAGE="ghcr.io/samhclark/fedora-zfs-kmods:zfs-${ZFS_VERSION}_kernel-${KERNEL_VERSION}"
    
    echo "🔍 Checking availability: $IMAGE"
    
    if skopeo inspect docker://$IMAGE >/dev/null 2>&1; then
        echo "✅ ZFS kmods available for ZFS $ZFS_VERSION + kernel $KERNEL_VERSION"
    else
        echo "❌ No prebuilt ZFS kmods found for this combination"
        echo "   ZFS version: $ZFS_VERSION"
        echo "   Kernel version: $KERNEL_VERSION"
        echo "   Expected image: $IMAGE"
        echo ""
        echo "This likely means either:"
        echo "  1. This ZFS/kernel combination is incompatible"
        echo "  2. The fedora-zfs-kmods build hasn't run yet for these versions"
        echo "  3. The fedora-zfs-kmods build failed for these versions"
        echo ""
        echo "Check https://github.com/samhclark/fedora-zfs-kmods for recent builds"
        exit 1
    fi

# Show all versions that will be used for build
versions:
    #!/usr/bin/env bash
    echo "ZFS Version: $(just zfs-version)"
    echo "Kernel Version: $(just kernel-version)"
    echo "Kernel Major.Minor: $(just kernel-major-minor)"
    echo ""
    just check-zfs-available

# Build the image locally for testing
build:
    #!/usr/bin/env bash
    just check-zfs-available
    
    ZFS_VERSION=$(just zfs-version)
    KERNEL_VERSION=$(just kernel-version)
    KERNEL_MAJOR_MINOR=$(just kernel-major-minor)
    
    # Clean ZFS version (remove zfs- prefix for container tag)
    ZFS_VERSION_CLEAN=${ZFS_VERSION#zfs-}
    
    echo "Building with:"
    echo "  ZFS_VERSION=$ZFS_VERSION"
    echo "  KERNEL_VERSION=$KERNEL_VERSION"
    echo ""
    
    podman build --rm \
        --build-arg ZFS_VERSION="$ZFS_VERSION_CLEAN" \
        --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
        -t "custom-coreos:stable" \
        .

# Quick build test (just verify it builds, don't keep the image)
test-build:
    #!/usr/bin/env bash
    just check-zfs-available
    
    ZFS_VERSION=$(just zfs-version)
    KERNEL_VERSION=$(just kernel-version)
    KERNEL_MAJOR_MINOR=$(just kernel-major-minor)
    
    # Clean ZFS version (remove zfs- prefix for container tag)
    ZFS_VERSION_CLEAN=${ZFS_VERSION#zfs-}
    
    echo "Test building with:"
    echo "  ZFS_VERSION=$ZFS_VERSION"
    echo "  KERNEL_VERSION=$KERNEL_VERSION"
    echo ""
    
    podman build --rm \
        --build-arg ZFS_VERSION="$ZFS_VERSION_CLEAN" \
        --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
        -t "custom-coreos:test" \
        . && podman rmi "custom-coreos:test"

# Generate Ignition file from butane.yaml
generate-ignition:
    #!/usr/bin/env bash
    echo "Generating Ignition file from butane.yaml..."
    just butane < butane.yaml > ignition.json
    echo "✅ Generated ignition.json"

# Trigger GitHub Actions workflow
run-workflow:
    gh workflow run build.yaml

# Check status of GitHub Actions workflow runs  
workflow-status:
    gh run list --workflow=build.yaml --limit=5

@butane:
    podman run --rm --interactive         \
              --security-opt label=disable          \
              --volume "${PWD}":/pwd --workdir /pwd \
              quay.io/coreos/butane:release