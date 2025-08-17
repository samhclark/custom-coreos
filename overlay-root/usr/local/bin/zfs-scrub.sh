#!/bin/bash

# ZFS Scrub Script
# Initiates scrub operations on ZFS pools and monitors completion
# Logs structured output to systemd journal

set -euo pipefail

SCRIPT_NAME="zfs-scrub"

log_info() {
    echo "<6>$SCRIPT_NAME: $1" | systemd-cat -t "$SCRIPT_NAME"
}

log_warn() {
    echo "<4>$SCRIPT_NAME: WARNING: $1" | systemd-cat -t "$SCRIPT_NAME"
}

log_error() {
    echo "<3>$SCRIPT_NAME: ERROR: $1" | systemd-cat -t "$SCRIPT_NAME"
}

check_scrub_status() {
    local pool="$1"
    local status
    
    if ! status=$(zpool status "$pool" 2>/dev/null); then
        log_error "Failed to get status for pool: $pool"
        return 1
    fi
    
    if echo "$status" | grep -q "scrub in progress"; then
        local progress
        if progress=$(echo "$status" | grep -E "scanned|repaired" | head -1); then
            log_info "Pool '$pool' scrub in progress: $progress"
        else
            log_info "Pool '$pool' scrub in progress"
        fi
        return 2  # Scrub already running
    elif echo "$status" | grep -q "scrub completed"; then
        local completion_info
        if completion_info=$(echo "$status" | grep "scrub completed" | head -1); then
            log_info "Pool '$pool' last scrub: $completion_info"
        fi
        return 0  # Can start new scrub
    elif echo "$status" | grep -q "no known data errors"; then
        log_info "Pool '$pool' is clean, ready for scrub"
        return 0
    else
        log_warn "Pool '$pool' status unclear, attempting scrub anyway"
        return 0
    fi
}

start_scrub() {
    local pool="$1"
    
    log_info "Starting scrub for pool: $pool"
    
    if ! zpool scrub "$pool" 2>/dev/null; then
        log_error "Failed to start scrub for pool: $pool"
        return 1
    fi
    
    log_info "Scrub initiated successfully for pool: $pool"
    
    # Wait a moment and check initial status
    sleep 2
    check_scrub_status "$pool" || true
    
    return 0
}

scrub_pools() {
    local pools
    if ! pools=$(zpool list -H -o name 2>/dev/null); then
        log_error "Failed to list ZFS pools - ZFS may not be loaded"
        return 1
    fi
    
    if [[ -z "$pools" ]]; then
        log_info "No ZFS pools found to scrub"
        return 0
    fi
    
    log_info "Starting scrub operations for pools: $(echo "$pools" | tr '\n' ' ')"
    
    local overall_status=0
    local scrub_started=0
    
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        
        case $(check_scrub_status "$pool"; echo $?) in
            0)
                # Pool ready for scrub
                if start_scrub "$pool"; then
                    ((scrub_started++))
                else
                    overall_status=1
                fi
                ;;
            2)
                # Scrub already running
                log_info "Pool '$pool' scrub already in progress, skipping"
                ;;
            *)
                # Error checking status
                overall_status=1
                ;;
        esac
        
    done <<< "$pools"
    
    if [[ $scrub_started -gt 0 ]]; then
        log_info "Scrub operations initiated for $scrub_started pool(s)"
        log_info "Monitor progress with: zpool status"
        log_info "Check completion with: journalctl -t zfs-scrub"
    else
        log_info "No new scrub operations started"
    fi
    
    return $overall_status
}

wait_for_scrubs() {
    local pools="$1"
    local max_wait=300  # 5 minutes max wait for status check
    local wait_time=0
    
    log_info "Checking scrub completion status (max wait: ${max_wait}s)"
    
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            if check_scrub_status "$pool" >/dev/null 2>&1; then
                local status_code=$?
                if [[ $status_code -eq 0 ]]; then
                    # No longer scrubbing
                    break
                elif [[ $status_code -eq 2 ]]; then
                    # Still scrubbing
                    sleep 30
                    waited=$((waited + 30))
                    continue
                fi
            fi
            break
        done
        
        if [[ $waited -ge $max_wait ]]; then
            log_info "Pool '$pool' scrub still running after ${max_wait}s check"
        fi
        
    done <<< "$pools"
}

main() {
    local mode="${1:-scrub}"
    
    log_info "ZFS scrub operation starting (mode: $mode)"
    
    # Check if ZFS kernel module is loaded
    if ! modinfo zfs >/dev/null 2>&1; then
        log_error "ZFS kernel module not available"
        exit 1
    fi
    
    if ! lsmod | grep -q "^zfs "; then
        log_error "ZFS kernel module not loaded"
        exit 1
    fi
    
    case "$mode" in
        "scrub"|"start")
            scrub_pools
            ;;
        "status"|"check")
            # Just check status without starting new scrubs
            local pools
            if pools=$(zpool list -H -o name 2>/dev/null); then
                while IFS= read -r pool; do
                    [[ -n "$pool" ]] || continue
                    check_scrub_status "$pool" || true
                done <<< "$pools"
            fi
            ;;
        *)
            log_error "Unknown mode: $mode. Use 'scrub', 'start', 'status', or 'check'"
            exit 1
            ;;
    esac
    
    local exit_code=$?
    
    log_info "ZFS scrub operation finished with exit code: $exit_code"
    exit $exit_code
}

main "$@"