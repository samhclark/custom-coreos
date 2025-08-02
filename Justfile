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

# Trigger Ignition file generation and GitHub Pages deployment
run-pages:
    gh workflow run pages.yaml

# Trigger container cleanup (dry run by default)
run-cleanup:
    gh workflow run cleanup-images.yaml

# Trigger container cleanup (actual deletion)
run-cleanup-force:
    gh workflow run cleanup-images.yaml -f dry_run=false

# Check status of GitHub Actions workflow runs  
workflow-status:
    gh run list --workflow=build.yaml --limit=5

# Check status of all workflows
all-workflows:
    #!/usr/bin/env bash
    echo "🔧 Build Workflow:"
    gh run list --workflow=build.yaml --limit=3
    echo ""
    echo "🗑️  Cleanup Workflow:"  
    gh run list --workflow=cleanup-images.yaml --limit=3
    echo ""
    echo "📄 Pages Workflow:"
    gh run list --workflow=pages.yaml --limit=3

# Test cleanup logic locally with configurable retention period
cleanup-dry-run RETENTION_DAYS:
    #!/usr/bin/env bash
    echo "🧪 Testing cleanup logic (DRY RUN)"
    echo "📅 Retention period: {{RETENTION_DAYS}} days"
    echo ""
    
    # Calculate cutoff date
    cutoff_date=$(date -d "{{RETENTION_DAYS}} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "📅 Cutoff date: $cutoff_date"
    echo ""
    
    # Query all package versions
    echo "🔍 Querying all package versions..."
    versions_json=$(gh api "/user/packages/container/custom-coreos/versions" --paginate)
    
    if [[ -z "$versions_json" || "$versions_json" == "[]" ]]; then
        echo "📦 No container images found"
        exit 0
    fi
    
    # Parse and display versions
    total_versions=$(echo "$versions_json" | jq length)
    echo "📦 Found $total_versions total versions:"
    echo "$versions_json" | jq -r '.[] | "  \(.metadata.container.tags[]? // "<untagged>") - \(.created_at) - ID: \(.id)"' | sort
    echo ""
    
    # Find versions older than cutoff
    old_versions=$(echo "$versions_json" | jq -r --arg cutoff "$cutoff_date" '
        .[] | select(.created_at < $cutoff) | "  \(.metadata.container.tags[]? // "<untagged>") - \(.created_at) - ID: \(.id)"'
    )
    
    if [[ -z "$old_versions" ]]; then
        echo "✅ No versions older than {{RETENTION_DAYS}} days found"
        echo ""
        echo "📊 Summary:"
        echo "  - Total versions: $total_versions"
        echo "  - Versions to delete: 0"
        echo "  - Versions to keep: $total_versions"
    else
        deletion_count=$(echo "$old_versions" | wc -l)
        remaining_count=$((total_versions - deletion_count))
        
        echo "🗑️  Versions that would be deleted (older than {{RETENTION_DAYS}} days):"
        echo "$old_versions"
        echo ""
        echo "📊 Summary:"
        echo "  - Total versions: $total_versions"
        echo "  - Versions to delete: $deletion_count"
        echo "  - Versions to keep: $remaining_count"
        echo ""
        echo "🔒 This was a dry run - no actual deletion performed"
    fi

@butane:
    podman run --rm --interactive         \
              --security-opt label=disable          \
              --volume "${PWD}":/pwd --workdir /pwd \
              quay.io/coreos/butane:release