# Rootless Grafana Rollout Checklist

This checklist is for validating the first rootless Quadlet conversion after the
machine boots into an image containing these changes.

For the design decisions and the reusable pattern behind this rollout, start
with `docs/rootless-quadlet-playbook.md`.

Assumptions:
- the host account is `_nas_grafana`
- the host UID/GID is `51210`
- the rootless Quadlet path is `/etc/containers/systemd/users/51210/grafana.container`
- Grafana mutable state is `/var/lib/grafana`
- Grafana home for rootless Podman state is `/var/home/_nas_grafana`
- image-controlled Grafana provisioning lives under `/usr/share/custom-coreos/grafana`

Note:
- image-managed service accounts reserve `51000-51999`, with `512xx` used for observability services
- this rollout allocates one explicit subordinate ID range for `_nas_grafana`; if more rootless service users are added later, those ranges must stay non-overlapping

## Quick Success Criteria

You are done if all of the following are true:
- `_nas_grafana` exists as a system user with UID `51210`
- `/etc/subuid` and `/etc/subgid` contain a range for `_nas_grafana`
- linger is enabled for `_nas_grafana`
- the `_nas_grafana` user manager is running after boot
- the user unit `grafana.service` is loaded and active
- Grafana is reachable through the usual URL and dashboards load
- Grafana can still talk to VictoriaMetrics

## 1. Check User And Subordinate IDs

Run:

```bash
getent passwd _nas_grafana
getent group _nas_grafana
grep '^_nas_grafana:' /etc/subuid /etc/subgid
```

Expected:
- passwd entry shows UID/GID `51210`
- both `/etc/subuid` and `/etc/subgid` contain `_nas_grafana:512100000:65536`

If this fails, gather:

```bash
cat /usr/lib/sysusers.d/nas-grafana.conf
cat /etc/subuid
cat /etc/subgid
```

## 2. Check Linger And User Manager

Run:

```bash
loginctl show-user _nas_grafana -p Linger -p State
systemctl status user@51210.service
loginctl user-status _nas_grafana
```

Expected:
- `Linger=yes`
- `user@51210.service` is active

If this fails, gather:

```bash
journalctl -b -u user@51210.service
ls -l /var/lib/systemd/linger/_nas_grafana
```

## 3. Check Rootless Podman Environment

Run:

```bash
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman unshare cat /proc/self/uid_map
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman unshare cat /proc/self/gid_map
```

Expected:
- the mappings are not empty
- you see the normal rootless namespace mapping instead of a failure about missing subordinate IDs

If this fails, gather:

```bash
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman unshare cat /proc/self/uid_map
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman info --log-level=debug
```

## 4. Check Paths, Ownership, And SELinux Labels

Run:

```bash
stat -c '%U:%G %a %n' /var/lib/grafana /var/home/_nas_grafana
ls -Zd /usr/share/custom-coreos/grafana /usr/share/custom-coreos/grafana/provisioning /usr/share/custom-coreos/grafana/dashboards /var/lib/grafana
namei -om /usr/share/custom-coreos/grafana/provisioning
namei -om /var/lib/grafana
```

Expected:
- `/var/lib/grafana` is owned by `_nas_grafana:_nas_grafana`
- `/var/home/_nas_grafana` is owned by `_nas_grafana:_nas_grafana`
- `/usr/share/custom-coreos/grafana` exists and is readable
- SELinux context on the shipped Grafana config tree and `/var/lib/grafana` is `container_file_t`

If this fails, gather:

```bash
ls -lR /usr/share/custom-coreos/grafana
ls -ldZ /usr/share/custom-coreos/grafana /usr/share/custom-coreos/grafana/provisioning /usr/share/custom-coreos/grafana/dashboards /var/lib/grafana
```

## 5. Check The User Unit

Run:

```bash
systemctl --machine _nas_grafana@ --user status grafana.service
systemctl --machine _nas_grafana@ --user cat grafana.service
systemctl --machine _nas_grafana@ --user show grafana.service -p LoadState -p ActiveState -p SubState -p FragmentPath
```

Expected:
- `grafana.service` is loaded from the generated user unit
- the unit is `active`

If this fails, gather:

```bash
journalctl --machine _nas_grafana@ --user -u grafana.service -b
journalctl -b | grep -Ei 'grafana|quadlet|podman|conmon'
```

## 6. Check The Actual Container

Run:

```bash
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman ps -a
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman logs grafana
```

Expected:
- a container named `grafana` exists and is running
- logs do not show permission, plugin install, or database initialization errors

If this fails, gather:

```bash
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman ps -a --no-trunc
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman inspect grafana
sudo -u _nas_grafana HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 podman logs grafana
```

## 7. Check Network And App Behavior

Run:

```bash
curl -I http://127.0.0.1:3000
curl -s http://127.0.0.1:3000/api/health
curl -s http://127.0.0.1:3000/api/datasources | head
```

Expected:
- Grafana answers locally on port `3000`
- `/api/health` returns a healthy response
- the VictoriaMetrics datasource is present

Also verify manually in the browser:
- Grafana loads through Caddy at the usual URL
- dashboards render
- panels backed by VictoriaMetrics return data

If this fails, gather:

```bash
curl -v http://127.0.0.1:3000/api/health
curl -v http://127.0.0.1:3000/api/datasources
```

## Common Failure Patterns

### Fully locked service account

Symptoms:
- `user@51210.service` fails with `status=224/PAM`
- journal mentions `_nas_grafana has expired` or `User account has expired`

Check:

```bash
sudo passwd -S _nas_grafana
sudo chage -l _nas_grafana
```

### Quadlet installed in a rootful search path

Symptoms:
- `grafana.service` is active, but it runs in `system.slice`
- `sudo -u _nas_grafana ... podman ps` shows no Grafana container
- `systemctl --user list-unit-files` for `_nas_grafana` does not include `grafana.service`

Check:

```bash
sudo systemctl status grafana.service --no-pager
sudo ls -l /etc/containers/systemd/users/51210/grafana.container /usr/share/containers/systemd/users/51210/grafana.container 2>/dev/null
```

### Missing subordinate IDs

Symptoms:
- `podman unshare` fails
- user service logs mention `newuidmap`, `newgidmap`, or user namespace setup

Check:

```bash
grep '^_nas_grafana:' /etc/subuid /etc/subgid
```

### Linger did not take effect

Symptoms:
- `user@51210.service` is not running after boot
- `systemctl --machine _nas_grafana@ --user ...` cannot connect

Check:

```bash
loginctl show-user _nas_grafana -p Linger -p State
ls -l /var/lib/systemd/linger/_nas_grafana
```

### SELinux denial on config or data

Symptoms:
- container starts then immediately exits
- Grafana logs show permission denied
- journal shows AVC denials

Check:

```bash
journalctl -b | grep -i avc
ls -Zd /usr/share/custom-coreos/grafana /var/lib/grafana
```

### VictoriaMetrics datasource is broken

Symptoms:
- Grafana starts, but dashboards have no data

Check:

```bash
curl -s http://127.0.0.1:3000/api/datasources
curl -s http://127.0.0.1:8428/health
```

## Minimal Failure Bundle To Save

If something fails and you want one compact set of diagnostics, gather:

```bash
getent passwd _nas_grafana
grep '^_nas_grafana:' /etc/subuid /etc/subgid
loginctl show-user _nas_grafana -p Linger -p State
systemctl status user@51210.service
sudo systemctl --machine _nas_grafana@ --user status grafana.service
journalctl -b -u user@51210.service
journalctl --machine _nas_grafana@ --user -u grafana.service -b
sudo -u _nas_grafana env HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51210/bus bash -lc 'cd / && podman ps -a --no-trunc'
sudo -u _nas_grafana env HOME=/var/home/_nas_grafana XDG_RUNTIME_DIR=/run/user/51210 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51210/bus bash -lc 'cd / && podman logs grafana'
ls -Zd /usr/share/custom-coreos/grafana /var/lib/grafana
```
