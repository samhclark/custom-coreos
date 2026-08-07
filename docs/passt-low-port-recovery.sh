#!/usr/bin/env bash
# ABOUTME: Applies or removes the temporary Caddy private-network low-port
# sysctl override. Applying restarts only the rootless Caddy service.

set -euo pipefail

dropin_dir=/etc/containers/systemd/users/51310/caddy.container.d
dropin_path=$dropin_dir/90-private-passt-low-ports.conf
base_quadlet=/etc/containers/systemd/users/51310/caddy.container
expected_content=$'[Container]\nSysctl=net.ipv4.ip_unprivileged_port_start=80'

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root (for example, with sudo)." >&2
    exit 1
fi

run_caddy() {
    (
        cd /
        sudo -u _nas_caddy env \
            HOME=/var/home/_nas_caddy \
            XDG_RUNTIME_DIR=/run/user/51310 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51310/bus \
            "$@"
    )
}

verify_caddy() {
    local attempt=0 pid ready=0
    pid=$(run_caddy podman inspect caddy --format '{{.State.Pid}}')

    echo "private namespace low-port threshold:"
    nsenter -t "$pid" -n sysctl -n net.ipv4.ip_unprivileged_port_start
    echo "private namespace low-port listeners:"
    nsenter -t "$pid" -n ss -H -ltnup \
        '( sport = :80 or sport = :443 )'

    while (( attempt < 30 )); do
        if curl --noproxy '*' --fail --silent --show-error --max-time 2 \
            --resolve jellyfin.i.samhclark.com:443:127.0.0.1 \
            https://jellyfin.i.samhclark.com/health | grep -qx Healthy; then
            ready=1
            break
        fi
        (( attempt += 1 ))
        sleep 1
    done
    if [[ $ready -ne 1 ]]; then
        echo "Caddy did not pass the loopback HTTPS health check." >&2
        return 1
    fi
    echo "Caddy loopback HTTPS health check: OK"
}

apply_override() {
    local tmp
    if [[ -e $dropin_path ]]; then
        if [[ $(<"$dropin_path") != "$expected_content" ]]; then
            echo "Refusing to replace unexpected existing drop-in: $dropin_path" >&2
            exit 1
        fi
        echo "Exact temporary drop-in already exists; reusing it."
    else
        install -d -m 0755 "$dropin_dir"
        tmp=$(mktemp)
        trap 'rm -f "$tmp"' RETURN
        printf '%s\n' "$expected_content" >"$tmp"
        install -m 0644 -o root -g root "$tmp" "$dropin_path"
        rm -f "$tmp"
        trap - RETURN
        echo "Installed temporary drop-in: $dropin_path"
    fi

    run_caddy systemctl --user daemon-reload
    run_caddy systemctl --user restart caddy.service
    verify_caddy
    echo "Temporary recovery is active. Remove it only after the permanent image is deployed."
}

remove_override() {
    if ! grep -qx 'Sysctl=net.ipv4.ip_unprivileged_port_start=80' "$base_quadlet"; then
        echo "Refusing removal: the deployed base Quadlet lacks the permanent Sysctl." >&2
        exit 1
    fi
    if [[ ! -e $dropin_path ]]; then
        echo "Temporary drop-in is already absent."
        exit 0
    fi
    if [[ $(<"$dropin_path") != "$expected_content" ]]; then
        echo "Refusing to remove unexpected drop-in content: $dropin_path" >&2
        exit 1
    fi

    rm -f -- "$dropin_path"
    rmdir --ignore-fail-on-non-empty "$dropin_dir"
    run_caddy systemctl --user daemon-reload
    run_caddy systemctl --user restart caddy.service
    verify_caddy
    echo "Temporary drop-in removed; the deployed image now supplies the setting."
}

case ${1:-} in
    --apply)
        apply_override
        ;;
    --remove)
        remove_override
        ;;
    *)
        cat >&2 <<EOF
Usage: $0 --apply|--remove

  --apply   Install the exact temporary sysctl drop-in and restart Caddy.
  --remove  After the permanent image is deployed, remove the exact drop-in
            and restart Caddy. Refuses unless the base Quadlet has the fix.
EOF
        exit 2
        ;;
esac
