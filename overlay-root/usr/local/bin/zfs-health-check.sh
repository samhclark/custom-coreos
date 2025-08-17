#!/bin/bash

# ZFS Health Check Script
# Monitors ZFS pool status and capacity
# Logs structured output to systemd journal

set -euo pipefail

SCRIPT_NAME="zfs-health-check"

log_info() {
    echo "<6>$SCRIPT_NAME: $1" | systemd-cat -t "$SCRIPT_NAME"
}

log_warn() {
    echo "<4>$SCRIPT_NAME: WARNING: $1" | systemd-cat -t "$SCRIPT_NAME"
}

log_error() {
    echo "<3>$SCRIPT_NAME: ERROR: $1" | systemd-cat -t "$SCRIPT_NAME"
}

check_zfs_pools() {
    local pools
    if ! pools=$(zpool list -H -o name 2>/dev/null); then
        log_error "Failed to list ZFS pools - ZFS may not be loaded"
        return 1
    fi
    
    if [[ -z "$pools" ]]; then
        log_info "No ZFS pools found"
        return 0
    fi
    
    log_info "Starting health check for ZFS pools: $(echo "$pools" | tr '\n' ' ')"
    
    local overall_status=0
    
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        
        # Check pool status
        local status
        if ! status=$(zpool status -x "$pool" 2>/dev/null); then
            log_error "Failed to get status for pool: $pool"
            overall_status=1
            continue
        fi
        
        if [[ "$status" == *"pool '$pool' is healthy"* ]]; then
            log_info "Pool '$pool' is healthy"
        else
            log_warn "Pool '$pool' has issues: $(echo "$status" | head -n 5 | tr '\n' '; ')"
            overall_status=1
        fi
        
        # Check capacity
        local capacity
        if capacity=$(zpool list -H -o capacity "$pool" 2>/dev/null); then
            capacity_num=${capacity%\%}
            if [[ "$capacity_num" -gt 80 ]]; then
                log_warn "Pool '$pool' is ${capacity} full - consider adding storage"
            elif [[ "$capacity_num" -gt 70 ]]; then
                log_info "Pool '$pool' is ${capacity} full - monitoring recommended"
            else
                log_info "Pool '$pool' capacity: ${capacity}"
            fi
        else
            log_warn "Failed to get capacity for pool: $pool"
        fi
        
        # Get basic pool info
        local size used avail
        if pool_info=$(zpool list -H -o size,alloc,free "$pool" 2>/dev/null); then
            read -r size used avail <<< "$pool_info"
            log_info "Pool '$pool' stats: Size=$size, Used=$used, Available=$avail"
        fi
        
    done <<< "$pools"
    
    if [[ $overall_status -eq 0 ]]; then
        log_info "ZFS health check completed successfully - all pools healthy"
    else
        log_warn "ZFS health check completed with warnings - check pool status"
    fi
    
    return $overall_status
}

main() {
    log_info "ZFS health check starting"
    
    # Check if ZFS kernel module is loaded
    if ! modinfo zfs >/dev/null 2>&1; then
        log_error "ZFS kernel module not available"
        exit 1
    fi
    
    if ! lsmod | grep -q "^zfs "; then
        log_error "ZFS kernel module not loaded"
        exit 1
    fi
    
    check_zfs_pools
    local exit_code=$?
    
    log_info "ZFS health check finished with exit code: $exit_code"
    exit $exit_code
}

main "$@"