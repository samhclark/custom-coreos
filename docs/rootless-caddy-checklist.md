# Rootless Caddy Rollout Checklist

Use this after the NAS boots the image containing Caddy's phase-two rootless
cutover. The expected host identity is `_nas_caddy` with UID/GID `51310`; the
user Quadlet lives under
`/etc/containers/systemd/users/51310/caddy.container`.

Status: implemented in the repository, awaiting deployment and production
validation on the NAS.

Deploy this release through the normal reboot-based bootc workflow. A small
first-boot outage is expected. The state-preparation one-shot and Caddy's user
manager intentionally have no cross-manager ordering: if Caddy starts first,
its guards fail closed and `Restart=always` retries 30 seconds later. Rebooting
once more is also a safe recovery after the preparation marker exists.

## Success Criteria

- no system-manager Caddy service or running rootful Caddy container remains
- `_nas_caddy`, its subordinate IDs, linger state, and user manager exist
- the pre-rootless state archive passes its checksum
- both persistent trees are owned by UID/GID `51310`, mode `0750`, and labeled
  `container_file_t:s0`
- the runtime Cloudflare token is readable only by `_nas_caddy`; the rootful
  Podman copy is retired
- Caddy runs in `_nas_caddy`'s Podman store and owns TCP 80/443 and UDP 443
- the existing ACME account and certificates remain present
- metrics, redirects, Garage, S3, VictoriaMetrics, and Grafana routes work
- a second reboot needs no state migration and returns Caddy to service

## 1. Preparation And Rollback Archive

```bash
sudo systemctl status prepare-caddy-rootless-state.service --no-pager
sudo journalctl -u prepare-caddy-rootless-state.service -b --no-pager
sudo test -e \
  /var/lib/nas-migrations/caddy-rootless-ownership-v1/complete
sudo bash -lc '
  cd /var/lib/nas-migrations/caddy-rootless-ownership-v1
  sha256sum --check pre-rootless-state.tar.sha256
  tar --list --file pre-rootless-state.tar | sed -n "1,20p"
'
```

The archive must contain both `var/lib/caddy/` and
`var/lib/caddy-config/`. It is root-readable because it contains certificate
and ACME state. Do not copy or expose its contents unnecessarily.

If preparation failed, Caddy should remain stopped. Inspect the journal before
restarting the one-shot:

```bash
sudo systemctl reset-failed prepare-caddy-rootless-state.service
sudo systemctl start prepare-caddy-rootless-state.service
```

Do not create the completion marker manually.

## 2. Rootful Retirement

```bash
test ! -e /etc/containers/systemd/caddy.container
if systemctl list-unit-files caddy.service --no-legend |
    grep -q '^caddy.service'; then
  echo 'ERROR: retired system Caddy unit still exists' >&2
  exit 1
fi
sudo podman ps --filter name=caddy
if sudo podman secret inspect cf-api-token >/dev/null 2>&1; then
  echo 'ERROR: retired rootful Caddy Podman secret still exists' >&2
  exit 1
fi
```

If the old Quadlet source survived the `/etc` merge, both preparation and the
rootless service refuse to proceed. Confirm that it is the retired
image-managed file, remove it, and reboot. Do not bypass the guards while a
rootful Caddy process is running.

The old stopped rootful container may remain in root's Podman store during the
rollback window. It is harmless and can be removed after validation.

## 3. Identity, State, And SELinux

```bash
getent passwd _nas_caddy
getent group _nas_caddy
grep '^_nas_caddy:' /etc/subuid /etc/subgid
loginctl show-user _nas_caddy -p Linger -p State
systemctl status user@51310.service --no-pager

sudo stat -c '%U:%G %a %C %n' \
  /var/lib/caddy \
  /var/lib/caddy-config
sudo find /var/lib/caddy /var/lib/caddy-config -xdev \
  \( ! -uid 51310 -o ! -gid 51310 \) -print -quit
sudo find /var/lib/caddy /var/lib/caddy-config -xdev \
  ! -context 'system_u:object_r:container_file_t:s0' -print -quit
```

Both `find` commands must print nothing. The state roots should be
`_nas_caddy:_nas_caddy`, mode `0750`, with exactly
`system_u:object_r:container_file_t:s0`; old private MCS categories must be
gone.

## 4. Runtime Secret

```bash
sudo systemctl status sops-distribute-secrets.service --no-pager
sudo stat -c '%U:%G %a %s %n' \
  /run/nas-secrets/caddy \
  /run/nas-secrets/caddy/cf-api-token
sudo -u _nas_caddy \
  test -r /run/nas-secrets/caddy/cf-api-token
```

The directory should be `root:_nas_caddy` mode `0710`; the token should be
`_nas_caddy:_nas_caddy` mode `0400`. Do not print its value.

## 5. Rootless Service And Preserved State

```bash
systemctl status caddy.service --no-pager
sudo -u _nas_caddy env \
  HOME=/var/home/_nas_caddy \
  XDG_RUNTIME_DIR=/run/user/51310 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51310/bus \
  bash -lc 'cd / && systemctl --user status caddy.service --no-pager && podman ps --no-trunc && podman exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile'

sudo -u _nas_caddy env \
  HOME=/var/home/_nas_caddy \
  XDG_RUNTIME_DIR=/run/user/51310 \
  podman exec caddy sh -c \
  'test -d /data/caddy && find /data/caddy -mindepth 1 -maxdepth 3 -type f -print -quit'

sudo journalctl _UID=51310 -b --no-pager
```

The system-manager status should find no unit. The user service and rootless
container should be active. Compare the state inventory with
`/var/lib/nas-migrations/caddy-rootless-preflight-v1/state-inventory.txt`;
certificate or ACME state should not have been recreated from scratch.

## 6. Listeners, Metrics, And Routes

```bash
sudo ss -ltnp | grep -E ':(80|443)\b'
sudo ss -lunp | grep -E ':443\b'
curl -fsS http://127.0.0.1:2019/metrics >/dev/null
curl -fsSI http://127.0.0.1/ | grep -i '^location: https://'
curl -fsS https://garage.i.samhclark.com/health
curl -fsS https://metrics.i.samhclark.com/-/healthy
curl -fsS https://visualize.i.samhclark.com/api/health | jq .
```

Also exercise an existing S3 object through
`https://s3.i.samhclark.com` if a configured client is convenient. The
existing blackbox probe, VictoriaMetrics Caddy scrape, and Grafana dashboards
should continue receiving fresh samples.

## 7. Second Reboot And Cleanup

Reboot once more after the first validation. The preparation unit should be
skipped because its durable completion marker exists, and Caddy should return
through its lingering user manager:

```bash
sudo systemctl reboot
```

After reconnecting, repeat the service, listener, route, ownership, and label
checks above. Once the rollback window is closed, remove the stopped rootful
container:

```bash
sudo podman rm --ignore caddy
```

The empty `/var/lib/caddy/secrets` directory may be removed after confirming
it remains unused. Keep the migration archive until the rootless deployment
has been stable for as long as desired.

The shell secret-driver implementation is intentionally retained in the
cutover image for easy bootc rollback. Remove it, `nas-secrets`, and the smoke
test in a later cleanup release.

## Rollback

The safest rollback restores the exact archived ownership and labels before
booting the previous rootful deployment. Run this while still on the new image:

```bash
sudo -u _nas_caddy env \
  HOME=/var/home/_nas_caddy \
  XDG_RUNTIME_DIR=/run/user/51310 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51310/bus \
  bash -lc 'cd / && systemctl --user stop caddy.service'
sudo systemctl stop prepare-caddy-rootless-state.service

sudo bash -euxo pipefail <<'EOF'
migration=/var/lib/nas-migrations/caddy-rootless-ownership-v1
cd "${migration}"
sha256sum --check pre-rootless-state.tar.sha256

stamp="$(date +%Y%m%d-%H%M%S)"
mv /var/lib/caddy "/var/lib/caddy.rootless-failed-${stamp}"
mv /var/lib/caddy-config "/var/lib/caddy-config.rootless-failed-${stamp}"

semanage fcontext -d '/var/lib/caddy(/.*)?' || true
semanage fcontext -d '/var/lib/caddy-config(/.*)?' || true
tar --extract \
  --file pre-rootless-state.tar \
  --acls \
  --xattrs \
  --selinux \
  --numeric-owner \
  --directory /
rm -f complete
EOF

sudo bootc rollback
sudo systemctl reboot
```

The failed rootless trees are retained under timestamped names rather than
deleted. The previous image's rootful secret manifest recreates the Podman
secret during boot, and rootful Caddy's `:Z` mounts reapply its private
container labels.

If `bootc rollback` fails before the reboot, do not start Caddy against the
restored root-owned trees. Either finish the rollback or restart
`prepare-caddy-rootless-state.service` to migrate them forward again.
