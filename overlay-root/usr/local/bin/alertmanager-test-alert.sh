#!/bin/bash
# ABOUTME: Sends a short-lived synthetic alert through the local Alertmanager.

set -euo pipefail

readonly ALERTMANAGER_URL="http://127.0.0.1:9093"

starts_at="$(date --iso-8601=seconds)"
ends_at="$(date --date='+5 minutes' --iso-8601=seconds)"

jq -cn \
    --arg starts_at "${starts_at}" \
    --arg ends_at "${ends_at}" \
    '[{
        labels: {
            alertname: "ManualNotificationTest",
            severity: "critical"
        },
        annotations: {
            summary: "Manual Alertmanager/Pushover test",
            description: "Synthetic alert sent from alertmanager-test-alert.service"
        },
        startsAt: $starts_at,
        endsAt: $ends_at
    }]' | \
    curl --fail --silent --show-error \
        --request POST \
        --header 'Content-Type: application/json' \
        --data-binary @- \
        "${ALERTMANAGER_URL}/api/v2/alerts"

printf 'Submitted ManualNotificationTest; it will expire at %s.\n' "${ends_at}"
