#!/bin/bash
# ABOUTME: Collects SMART disk health and ZFS pool status, writes Prometheus textfile metrics.
# Runs as root (required for smartctl on SATA drives). Output read by node_exporter textfile collector.

set -euo pipefail

TEXTFILE_DIR="/var/lib/prometheus/node-exporter"
PROM_FILE="${TEXTFILE_DIR}/disk_health.prom"
TMP_FILE="${PROM_FILE}.$$"

cleanup() {
    rm -f "${TMP_FILE}"
}
trap cleanup EXIT

# --- SMART metrics ---

# smartctl uses a bitmask exit code. Bits 0-1 are fatal (bad command or device),
# bits 2-7 are informational (disk failing, errors in log, etc.) and we still
# want the JSON output in those cases.
smartctl_exit_ok() {
    local exit_code="$1"
    # Fatal if either of the lowest two bits are set
    (( (exit_code & 3) == 0 ))
}

collect_smart_metrics() {
    local devices
    devices="$(smartctl --scan --json 2>/dev/null)" || return 0

    local device_count
    device_count="$(echo "${devices}" | jq '.devices | length')"

    if [[ "${device_count}" -eq 0 ]]; then
        return 0
    fi

    echo "# HELP smartctl_device_smart_healthy SMART overall health assessment (1=passed, 0=failed)"
    echo "# TYPE smartctl_device_smart_healthy gauge"
    echo "# HELP smartctl_device_temperature_celsius Current drive temperature in Celsius"
    echo "# TYPE smartctl_device_temperature_celsius gauge"
    echo "# HELP smartctl_device_reallocated_sector_ct Count of reallocated sectors (prefail indicator)"
    echo "# TYPE smartctl_device_reallocated_sector_ct gauge"
    echo "# HELP smartctl_device_current_pending_sector_ct Count of current pending sectors (prefail indicator)"
    echo "# TYPE smartctl_device_current_pending_sector_ct gauge"
    echo "# HELP smartctl_device_offline_uncorrectable_ct Count of offline uncorrectable sectors"
    echo "# TYPE smartctl_device_offline_uncorrectable_ct gauge"
    echo "# HELP smartctl_device_power_on_seconds Total power-on time in seconds"
    echo "# TYPE smartctl_device_power_on_seconds gauge"
    echo "# HELP smartctl_device_smartctl_exit_status Exit status bitmask from smartctl"
    echo "# TYPE smartctl_device_smartctl_exit_status gauge"

    local i=0
    while [[ "${i}" -lt "${device_count}" ]]; do
        local dev_name dev_type
        dev_name="$(echo "${devices}" | jq -r ".devices[${i}].name")"
        dev_type="$(echo "${devices}" | jq -r ".devices[${i}].type")"
        i=$((i + 1))

        # smartctl --scan sometimes reports SATA drives as "scsi"; use "auto" instead
        if [[ "${dev_type}" == "scsi" ]]; then
            dev_type="auto"
        fi

        local info exit_code=0
        info="$(smartctl -a --json --tolerance=verypermissive -d "${dev_type}" "${dev_name}" 2>/dev/null)" || exit_code=$?

        if ! smartctl_exit_ok "${exit_code}"; then
            continue
        fi

        local model serial family
        model="$(echo "${info}" | jq -r '.model_name // .scsi_model_name // "unknown"')"
        serial="$(echo "${info}" | jq -r '.serial_number // "unknown"')"
        family="$(echo "${info}" | jq -r '.model_family // "unknown"')"

        local labels="device=\"${dev_name}\",model=\"${model}\",serial=\"${serial}\",family=\"${family}\""

        # Export smartctl exit status so we can see bit flags (disk failing, errors, etc.)
        echo "smartctl_device_smartctl_exit_status{${labels}} ${exit_code}"

        # Overall SMART health (only if smart_status exists in output)
        local healthy
        healthy="$(echo "${info}" | jq '.smart_status.passed // empty' 2>/dev/null)" || true
        if [[ -n "${healthy}" ]]; then
            if [[ "${healthy}" == "true" ]]; then
                echo "smartctl_device_smart_healthy{${labels}} 1"
            else
                echo "smartctl_device_smart_healthy{${labels}} 0"
            fi
        fi

        # Temperature (works for both ATA and NVMe)
        local temp
        temp="$(echo "${info}" | jq '.temperature.current // empty' 2>/dev/null)" || true
        if [[ -n "${temp}" ]]; then
            echo "smartctl_device_temperature_celsius{${labels}} ${temp}"
        fi

        # Power-on time in seconds (Prometheus convention: base units)
        local hours minutes seconds
        hours="$(echo "${info}" | jq '.power_on_time.hours // empty' 2>/dev/null)" || true
        if [[ -n "${hours}" ]]; then
            minutes="$(echo "${info}" | jq '.power_on_time.minutes // 0' 2>/dev/null)" || true
            seconds=$(( hours * 3600 + minutes * 60 ))
            echo "smartctl_device_power_on_seconds{${labels}} ${seconds}"
        fi

        # ATA SMART attributes (SATA drives only — NVMe won't have these)
        local has_attrs
        has_attrs="$(echo "${info}" | jq '.ata_smart_attributes.table // empty | length' 2>/dev/null)" || true
        if [[ -n "${has_attrs}" && "${has_attrs}" -gt 0 ]]; then
            local reallocated pending uncorrectable
            reallocated="$(echo "${info}" | jq '[.ata_smart_attributes.table[] | select(.id == 5)][0].raw.value // empty' 2>/dev/null)" || true
            pending="$(echo "${info}" | jq '[.ata_smart_attributes.table[] | select(.id == 197)][0].raw.value // empty' 2>/dev/null)" || true
            uncorrectable="$(echo "${info}" | jq '[.ata_smart_attributes.table[] | select(.id == 198)][0].raw.value // empty' 2>/dev/null)" || true

            if [[ -n "${reallocated}" ]]; then
                echo "smartctl_device_reallocated_sector_ct{${labels}} ${reallocated}"
            fi
            if [[ -n "${pending}" ]]; then
                echo "smartctl_device_current_pending_sector_ct{${labels}} ${pending}"
            fi
            if [[ -n "${uncorrectable}" ]]; then
                echo "smartctl_device_offline_uncorrectable_ct{${labels}} ${uncorrectable}"
            fi
        fi
    done
}

# --- ZFS pool metrics ---

collect_zpool_metrics() {
    if ! command -v zpool &>/dev/null; then
        return 0
    fi

    if ! lsmod | grep -q "^zfs "; then
        return 0
    fi

    local pools
    pools="$(zpool list -H -o name 2>/dev/null)" || return 0

    if [[ -z "${pools}" ]]; then
        return 0
    fi

    echo "# HELP zpool_healthy ZFS pool health (1=healthy, 0=degraded/faulted)"
    echo "# TYPE zpool_healthy gauge"
    echo "# HELP zpool_state ZFS pool state (1 for the current state label)"
    echo "# TYPE zpool_state gauge"

    while IFS= read -r pool; do
        [[ -n "${pool}" ]] || continue

        local health
        health="$(zpool list -H -o health "${pool}" 2>/dev/null)" || continue

        if [[ "${health}" == "ONLINE" ]]; then
            echo "zpool_healthy{pool=\"${pool}\"} 1"
        else
            echo "zpool_healthy{pool=\"${pool}\"} 0"
        fi

        # Emit state labels for each possible state
        for state in ONLINE DEGRADED FAULTED OFFLINE REMOVED UNAVAIL SUSPENDED; do
            if [[ "${health}" == "${state}" ]]; then
                echo "zpool_state{pool=\"${pool}\",state=\"${state}\"} 1"
            else
                echo "zpool_state{pool=\"${pool}\",state=\"${state}\"} 0"
            fi
        done
    done <<< "${pools}"
}

# --- Main ---

main() {
    mkdir -p "${TEXTFILE_DIR}"

    {
        collect_smart_metrics
        collect_zpool_metrics
    } > "${TMP_FILE}"

    # Atomic replace so node_exporter never reads a partial file
    mv "${TMP_FILE}" "${PROM_FILE}"
    chmod 644 "${PROM_FILE}"
}

main "$@"
