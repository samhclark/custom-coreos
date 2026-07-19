# Rootless Alertmanager Rollout Checklist

Use this after the NAS boots an image containing the rootless Alertmanager
migration. The expected host identity is `_nas_alertmanager` with UID/GID
`51240`; the user Quadlet lives under
`/etc/containers/systemd/users/51240/alertmanager.container`.

## Success Criteria

- the `_nas_alertmanager` account, subordinate IDs, linger state, and user
  manager are present
- `alertmanager.service` runs in the user manager, not the system manager
- both Pushover runtime files exist with service-only ownership and mode
- the old rootful Podman secrets and plaintext generated config are absent
- `/var/lib/alertmanager/data` retains the existing notification state
- Alertmanager answers its health and metrics endpoints on `127.0.0.1:9093`

## 1. Identity And User Manager

```bash
getent passwd _nas_alertmanager
getent group _nas_alertmanager
grep '^_nas_alertmanager:' /etc/subuid /etc/subgid
loginctl show-user _nas_alertmanager -p Linger -p State
systemctl status user@51240.service --no-pager
```

Expected subordinate-ID entries:

```text
_nas_alertmanager:512400000:65536
```

## 2. Secret Distribution

```bash
systemctl status sops-distribute-secrets.service --no-pager
stat -c '%U:%G %a %n' \
  /run/nas-secrets/alertmanager \
  /run/nas-secrets/alertmanager/pushover-user-key \
  /run/nas-secrets/alertmanager/pushover-api-token
sudo -u _nas_alertmanager test -r /run/nas-secrets/alertmanager/pushover-user-key
sudo -u _nas_alertmanager test -r /run/nas-secrets/alertmanager/pushover-api-token
```

The service directory should be `root:_nas_alertmanager` mode `0710`; secret
files should be `_nas_alertmanager:_nas_alertmanager` mode `0400`. Do not print
their contents during validation.

The distributor should also have removed the retired rootful Podman secrets:

```bash
sudo podman secret inspect pushover-user-key && echo 'unexpected secret remains'
sudo podman secret inspect pushover-api-token && echo 'unexpected secret remains'
```

Both inspect commands should report that the secret does not exist.

## 3. Storage And Legacy Cleanup

```bash
stat -c '%U:%G %a %n' /var/lib/alertmanager /var/lib/alertmanager/data
ls -Zd /usr/share/custom-coreos/alertmanager /var/lib/alertmanager /var/lib/alertmanager/data
test ! -e /var/lib/alertmanager/alertmanager.yml
```

The data paths should be owned by `_nas_alertmanager`, labeled
`container_file_t`, and the obsolete generated config must be absent. Existing
files under `/var/lib/alertmanager/data` should still be present.

## 4. User Service And Container

```bash
systemctl status alertmanager.service --no-pager
systemctl --machine _nas_alertmanager@ --user status alertmanager.service --no-pager
sudo -u _nas_alertmanager env \
  HOME=/var/home/_nas_alertmanager \
  XDG_RUNTIME_DIR=/run/user/51240 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51240/bus \
  bash -lc 'cd / && systemctl --user status alertmanager.service --no-pager && podman ps --no-trunc'
```

The system-manager status should report no such unit. The user-manager status
should be active, and the container should be owned by the rootless service
account.

Check the mounted configuration and secrets without displaying secret values:

```bash
sudo -u _nas_alertmanager env \
  HOME=/var/home/_nas_alertmanager \
  XDG_RUNTIME_DIR=/run/user/51240 \
  bash -lc 'cd / && podman exec alertmanager test -r /etc/alertmanager/alertmanager.yml && podman exec alertmanager test -r /run/secrets/pushover-user-key && podman exec alertmanager test -r /run/secrets/pushover-api-token'
```

## 5. Health And Logs

```bash
curl -fsS http://127.0.0.1:9093/-/healthy
curl -fsS http://127.0.0.1:9093/-/ready
curl -fsS http://127.0.0.1:9093/metrics >/dev/null
journalctl --machine _nas_alertmanager@ --user -u alertmanager.service -b --no-pager
```

Confirm Grafana and VictoriaMetrics still report Alertmanager as available.

## 6. Test Notification

Trigger a short-lived synthetic alert through Alertmanager:

```bash
sudo systemctl start alertmanager-test-alert.service
sudo journalctl -u alertmanager-test-alert.service -n 20 --no-pager
```

The notification is subject to Alertmanager's configured `group_wait` and
expires automatically after five minutes. This verifies Alertmanager routing,
its Pushover credentials, and Pushover delivery; it does not exercise vmalert
rule evaluation.
