# Future Enhancements

This document contains optional improvements that can be implemented after the core functionality is complete and stable.

## Phase 9: Advanced Container Optimization

### Step 9.1: Advanced Duplicate Detection

**File**: `.github/workflows/build.yaml`  
**Action**: Implement sophisticated build deduplication (optional future enhancement)

**Details**:
- Check for existing containers based on CoreOS version + ZFS version combination
- Extract CoreOS version from container labels (not tags)
- Skip builds when identical CoreOS+ZFS combination already exists
- Add container labeling to track parent CoreOS image versions
- **Note**: This is not critical for initial implementation and can be added later

**Benefits**:
- Reduces unnecessary builds when CoreOS version hasn't changed
- Saves CI/CD resources and build time
- Provides more granular build tracking

**Implementation Strategy**:
1. Add container labels during build:
   ```dockerfile
   LABEL custom-coreos.coreos-version="${COREOS_VERSION}"
   LABEL custom-coreos.zfs-version="${ZFS_VERSION}"
   LABEL custom-coreos.kernel-version="${KERNEL_VERSION}"
   ```

2. Query existing containers before build:
   ```bash
   # Check if combination already exists
   existing=$(gh api /user/packages/container/custom-coreos/versions \
     --jq '.[] | select(.metadata.container.tags[] == "stable") | .metadata.container.labels."custom-coreos.coreos-version"')
   ```

3. Skip build if identical versions found

**Prerequisites**:
- Core build system must be stable and tested
- Container registry API access configured
- Build deduplication logic thoroughly tested

## Future Considerations

Additional enhancements that may be valuable:

### Multi-Architecture Support
- Build ARM64 variants for broader compatibility
- Add architecture-specific compatibility matrices

### Enhanced Monitoring
- Build success/failure notifications
- Performance metrics tracking
- Automated testing of built images

### Security Enhancements
- Vulnerability scanning integration
- Automated security updates
- Enhanced attestation workflows