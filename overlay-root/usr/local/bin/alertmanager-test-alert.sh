#!/bin/bash
# ABOUTME: Sends a short-lived synthetic alert through the local Alertmanager.

set -euo pipefail

readonly ALERTMANAGER_URL="http://127.0.0.1:9093"
readonly CONTAINER_NAME="alertmanager"

ends_at="$(date --date='+5 minutes' --iso-8601=seconds)"

podman exec "${CONTAINER_NAME}" /bin/amtool \
    --alertmanager.url="${ALERTMANAGER_URL}" \
    alert add \
    'alertname="ManualNotificationTest"' \
    'severity="critical"' \
    '--annotation=summary="Manual Alertmanager/Pushover test"' \
    '--annotation=description="Synthetic alert sent from alertmanager-test-alert.service"' \
    --end="${ends_at}"

printf 'Submitted ManualNotificationTest; it will expire at %s.\n' "${ends_at}"
