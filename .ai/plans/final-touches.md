# Final Touches Implementation Plan

This plan tracks the remaining NAS monitoring and Cockpit access decisions. ZFS snapshot/health automation is already implemented in the repo.

## Current State Summary

- **ZFS snapshots**: Implemented via systemd template units and scripts in `overlay-root/` and enabled for the `videos` dataset in `butane.yaml`.
- **ZFS health checks**: Implemented (`zfs-health-check.sh` + systemd service/timer) and enabled in `butane.yaml`.
- **ZFS scrub**: Implemented (`zfs-scrub.sh` + systemd service/timer) and enabled in `butane.yaml`.
- **Cockpit tooling**: `cockpit-ostree`, `cockpit-podman`, and `cockpit-system` installed in the Containerfile.
- **Cockpit web service**: `quay.io/cockpit/ws:latest` runs via a Quadlet in `butane.yaml` bound to `127.0.0.1:9090`.

## Remaining Work

### Phase 3: SMART Monitoring (Not Implemented)

#### Step 3.1: Add SMART tooling
- **Containerfile**: Add `smartmontools` to the `rpm-ostree override remove ... --install=...` list.

#### Step 3.2: Create SMART Check Script
- Create `overlay-root/usr/local/bin/smart-check.sh`:
  - Run `smartctl -a` on all drives
  - Parse for error indicators
  - Log structured results to journal

#### Step 3.3: Create SMART Systemd Units
- Create `overlay-root/etc/systemd/system/smart-check.service`
- Create `overlay-root/etc/systemd/system/smart-check.timer` (weekly)

#### Step 3.4: Enable SMART Timer in `butane.yaml`
- Add systemd unit enablement for `smart-check.timer`

### Phase 4: Cockpit Access Model (Decision Needed)

**Current behavior**: Cockpit web service is available only on localhost (`127.0.0.1:9090`). The preferred access path is over Tailscale.

Choose one of the following:

1. **Keep localhost-only** (recommended for Tailscale-only access):
   - Access via `tailscale serve` or SSH port forwarding
   - No firewall changes required

2. **Expose to LAN**:
   - Add a `firewalld` service or rich rule for port 9090
   - Optionally add port 80 → 9090 redirect
   - Consider a login banner and idle timeout in `/etc/cockpit/cockpit.conf`

### Phase 5: Integration & Testing (After Changes)

- `just build` to validate image creation
- Verify timers:
  - `systemctl list-timers`
  - `journalctl -u zfs-health-check`
  - `journalctl -u zfs-scrub`
  - `journalctl -u smart-check` (once implemented)
- Validate Cockpit access per chosen model

## Updated Timer Frequencies (Implemented)

- **ZFS Health Check**: Daily
- **ZFS Scrub**: Monthly
- **SMART Check**: Weekly (planned)

## File Structure (Current + Planned)

```
overlay-root/
├── etc/
│   ├── systemd/system/
│   │   ├── zfs-snapshots-daily@.service
│   │   ├── zfs-snapshots-daily@.timer
│   │   ├── zfs-snapshots-frequently@.service
│   │   ├── zfs-snapshots-frequently@.timer
│   │   ├── zfs-snapshots-hourly@.service
│   │   ├── zfs-snapshots-hourly@.timer
│   │   ├── zfs-snapshots-weekly@.service
│   │   ├── zfs-snapshots-weekly@.timer
│   │   ├── zfs-snapshots-monthly@.service
│   │   ├── zfs-snapshots-monthly@.timer
│   │   ├── zfs-snapshots-yearly@.service
│   │   ├── zfs-snapshots-yearly@.timer
│   │   ├── zfs-health-check.service
│   │   ├── zfs-health-check.timer
│   │   ├── zfs-scrub.service
│   │   ├── zfs-scrub.timer
│   │   ├── smart-check.service          # planned
│   │   └── smart-check.timer            # planned
│   └── containers/systemd/
│       └── cockpit-ws.container
└── usr/local/bin/
    ├── zfs-snapshot-daily.sh
    ├── zfs-snapshot-frequently.sh
    ├── zfs-snapshot-hourly.sh
    ├── zfs-snapshot-weekly.sh
    ├── zfs-snapshot-monthly.sh
    ├── zfs-snapshot-yearly.sh
    ├── zfs-health-check.sh
    ├── zfs-scrub.sh
    └── smart-check.sh                   # planned
```

## Dependencies

- **Existing**: ZFS modules, firewalld, systemd, Cockpit packages, Tailscale
- **Planned**: smartmontools

## Success Criteria

- [ ] SMART monitoring detects drive issues and logs to journal
- [ ] Cockpit access model confirmed and documented
- [ ] Monitoring logs available in journal
- [ ] No security holes introduced for LAN access (if enabled)
