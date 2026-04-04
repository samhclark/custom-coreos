#!/bin/bash
# ABOUTME: One-time migration script. Reads existing plaintext secrets and stores
# them as podman secrets using the age + TPM shell driver.
#
# Run once after upgrading to the new image:
#   sudo /usr/local/bin/migrate-secrets-to-podman.sh
#
# Prerequisites:
# - age-tpm-identity.service has run (TPM identity exists)
# - The containers.conf.d shell driver config is in place

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

secret_exists() {
    podman secret inspect "$1" &>/dev/null
}

migrate_file_to_secret() {
    local file="$1"
    local name="$2"

    if secret_exists "$name"; then
        log "Secret '$name' already exists, skipping"
        return 0
    fi

    if [[ ! -f "$file" ]]; then
        log "WARNING: $file not found, skipping $name"
        return 1
    fi

    log "Migrating $file -> podman secret '$name'"
    podman secret create "$name" "$file"
}

log "Starting secret migration..."
log ""

# Garage secrets
migrate_file_to_secret /var/lib/garage/rpc_secret garage-rpc-secret
migrate_file_to_secret /var/lib/garage/admin_token garage-admin-token
migrate_file_to_secret /var/lib/garage/metrics_token garage-metrics-token

# Alertmanager/Pushover secrets
migrate_file_to_secret /var/lib/alertmanager/pushover_user_key pushover-user-key
migrate_file_to_secret /var/lib/alertmanager/pushover_api_token pushover-api-token

# Caddy CF API token
# The old secret was created with the default file driver. After switching to the
# shell driver, we need to recreate it. The token value is in /etc/caddy/cf-api-token
# (baked into the image) or in the old podman secret store.
if secret_exists "cf-api-token"; then
    log "cf-api-token already exists in current driver, skipping"
else
    if [[ -f /etc/caddy/cf-api-token ]]; then
        log "Migrating /etc/caddy/cf-api-token -> podman secret 'cf-api-token'"
        podman secret create cf-api-token /etc/caddy/cf-api-token
    else
        log "WARNING: cf-api-token not found. You may need to recreate it manually:"
        log "  echo 'your-cloudflare-api-token' | sudo podman secret create cf-api-token -"
    fi
fi

log ""
log "Migration complete. Verify with: sudo nas-secrets list"
log ""
log "After verifying secrets work correctly, you can remove plaintext files:"
log "  sudo rm -f /var/lib/garage/rpc_secret /var/lib/garage/admin_token /var/lib/garage/metrics_token"
log "  sudo rm -f /var/lib/alertmanager/pushover_user_key /var/lib/alertmanager/pushover_api_token"
