# Butane/Ignition Testing Plan

## Overview

Testing CoreOS Ignition files is challenging because they only run during first boot. This plan evaluates testing approaches for single-machine deployment vs building comprehensive test infrastructure.

## Current Situation

- **Target**: Single NAS machine (may expand later)
- **Risk**: Ignition only runs once during initial CoreOS installation
- **Constraint**: Different machines would need different Butane files anyway

## Testing Approaches

### Option 1: Trial-and-Error on Target Hardware (RECOMMENDED)

**Pros**:
- Simplest approach for single-machine deployment
- Tests real hardware/firmware interactions (TPM2, UEFI, storage)
- No additional infrastructure needed
- Fastest to implement

**Cons**:
- Requires physical access for recovery if Ignition fails
- Cannot easily test variations
- Potential for failed installations

**Risk Mitigation**:
- Have CoreOS Live USB ready for recovery
- Backup current system before installation
- Test SSH key access beforehand
- Document recovery procedures

**Process**:
1. Backup existing system
2. Create CoreOS installation media with Ignition URL
3. Boot and install
4. If fails: boot Live USB, debug, regenerate Ignition, retry

### Option 2: VM Testing Infrastructure

**Pros**:
- Safe testing environment
- Can test multiple configurations
- Snapshot/restore capabilities
- Can simulate TPM2 with software TPM

**Cons**:
- Complex setup (QEMU + TPM2 simulation)
- May not match real hardware behavior
- Time investment for single-machine use case
- TPM2 simulation may behave differently than real TPM

**Requirements**:
- QEMU with UEFI support
- Software TPM2 (swtpm)
- Virtual disk partitioning setup
- Mock SSH key testing

### Option 3: Static Validation Only

**Pros**:
- Quick and easy
- Catches syntax errors
- Can validate against Ignition spec

**Cons**:
- Cannot test runtime behavior
- Misses TPM2/hardware-specific issues
- No guarantee of actual boot success

**Tools**:
- `butane` - Already working (syntax validation)
- `ignition-validate` - Validates Ignition JSON structure
- Manual review of generated Ignition

### Option 4: Container-Based Testing (Limited)

**Pros**:
- Can test file creation and basic config
- Fast iteration
- No hardware dependencies

**Cons**:
- Cannot test LUKS/TPM2/filesystem creation
- Missing critical boot-time behavior
- Limited value for storage-heavy configurations

## Recommendation: Hybrid Approach

**For single-machine deployment, recommend Option 1 (trial-and-error) with enhanced preparation:**

### Phase 1: Enhanced Static Validation
1. ✅ Butane syntax validation (already working)
2. Add Ignition JSON structure validation
3. Manual review of all configuration elements
4. Cross-reference with CoreOS documentation

### Phase 2: Preparation & Risk Mitigation
1. Create detailed recovery plan
2. Prepare CoreOS Live USB for debugging
3. Document all configuration choices
4. Test SSH key on existing systems
5. Verify TPM2 is available/enabled on target hardware

### Phase 3: Staged Installation
1. Install with minimal Ignition first (no encryption)
2. Verify basic CoreOS boot and SSH access
3. Reinstall with full encrypted configuration
4. Document any issues encountered

### Phase 4: Post-Installation Validation
1. Verify TPM2 unlock works
2. Test SSH access
3. Confirm hostname and basic config
4. Document successful configuration for future reference

## Future Expansion Considerations

**If expanding to multiple machines later:**
- Each machine likely needs different SSH keys, hostnames, network config
- Consider parameterized Butane templates
- At that scale, VM testing infrastructure becomes worthwhile
- Could build automated testing pipeline

## Implementation Steps

### Immediate (Static Validation)
1. Add `ignition-validate` to validation workflow
2. Document all configuration choices and rationale
3. Create recovery procedures document

### Pre-Installation (Risk Mitigation)
1. Test SSH key access on current system
2. Verify TPM2 status: `systemd-cryptenroll --tpm2-device=list`
3. Create CoreOS Live USB for emergency access
4. Full system backup

### Installation (Staged Approach)
1. Boot CoreOS installer with Ignition URL
2. Monitor installation process
3. Test SSH access immediately after first boot
4. Verify encryption status: `lsblk`, `cryptsetup status root`

## Validation Checklist

**Pre-Installation**:
- [ ] Butane converts to valid Ignition JSON
- [ ] SSH key format verified
- [ ] TPM2 available on target hardware
- [ ] Recovery plan documented
- [ ] System backup completed

**Post-Installation**:
- [ ] System boots successfully
- [ ] SSH access works with provided key
- [ ] Hostname set correctly (`hostname`)
- [ ] Root filesystem encrypted (`lsblk`)
- [ ] TPM2 unlock configured (`systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/root`)
- [ ] No Ignition errors in journal (`journalctl -u ignition-*`)

## Tools and Commands

**Static Validation**:
```bash
# Already working
just generate-ignition

# Add validation
ignition-validate ignition.json

# Check TPM2 on target
systemd-cryptenroll --tpm2-device=list
```

**Post-Installation Debugging**:
```bash
# Check Ignition status
journalctl -u ignition-complete
journalctl -u ignition-files
journalctl -u ignition-disks

# Verify encryption
lsblk
cryptsetup status root
systemd-cryptenroll /dev/disk/by-partlabel/root
```

## Conclusion

For single-machine deployment, **trial-and-error with proper preparation is the most practical approach**. The investment in VM testing infrastructure isn't justified for one machine, especially since each future machine would need different configurations anyway.

The key is thorough preparation, good recovery planning, and staged validation to minimize risk.