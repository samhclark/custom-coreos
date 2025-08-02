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

# Check if ZFS version is compatible with kernel version
check-compatibility:
    #!/usr/bin/env bash
    ZFS_VERSION=$(just zfs-version)
    KERNEL_MAJOR_MINOR=$(just kernel-major-minor)
    
    # Define compatibility matrix for ZFS versions
    # Format: "zfs-version:max-kernel-version"
    declare -A compatibility_matrix=(
        ["zfs-2.2.7"]="6.12"
        ["zfs-2.3.0"]="6.12"
        ["zfs-2.3.1"]="6.13"
        ["zfs-2.3.2"]="6.14"
        ["zfs-2.2.8"]="6.15"
        ["zfs-2.3.3"]="6.15"
    )
    
    # Check if we have compatibility info for this ZFS version
    if [[ -z "${compatibility_matrix[$ZFS_VERSION]}" ]]; then
        echo "ERROR: Unknown ZFS version $ZFS_VERSION"
        echo "This version is not in the compatibility matrix."
        echo "Please update the compatibility matrix in the Justfile to include this version."
        exit 1
    fi
    
    MAX_KERNEL="${compatibility_matrix[$ZFS_VERSION]}"
    
    # Check if current kernel is compatible
    if [[ $(echo "$KERNEL_MAJOR_MINOR $MAX_KERNEL" | tr ' ' '\n' | sort -V | tail -n1) != "$MAX_KERNEL" ]]; then
        echo "ERROR: ZFS $ZFS_VERSION is only compatible with Linux kernels up to $MAX_KERNEL"
        echo "Current kernel: $KERNEL_MAJOR_MINOR"
        echo "Please wait for a newer ZFS release or use an older kernel"
        exit 1
    fi
    
    echo "✓ ZFS $ZFS_VERSION is compatible with kernel $KERNEL_MAJOR_MINOR (max: $MAX_KERNEL)"

# Show all versions that will be used for build
versions:
    #!/usr/bin/env bash
    echo "ZFS Version: $(just zfs-version)"
    echo "Kernel Version: $(just kernel-version)"
    echo "Kernel Major.Minor: $(just kernel-major-minor)"
    echo ""
    just check-compatibility

# Build the image locally for testing
build:
    #!/usr/bin/env bash
    just check-compatibility
    
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
    just check-compatibility
    
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

@butane:
    podman run --rm --interactive         \
              --security-opt label=disable          \
              --volume "${PWD}":/pwd --workdir /pwd \
              quay.io/coreos/butane:release