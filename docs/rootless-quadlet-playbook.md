# Rootless Quadlet Playbook

This document captures the working pattern established while moving Grafana
from a rootful system Quadlet to a rootless user Quadlet in this repo.

It is intended for two cases:
- adapting an existing rootful Quadlet to run rootless
- adding a new rootless service from scratch

This is not a generic Podman guide. It is the repo-specific playbook for a
bootc-based Fedora CoreOS image where `/usr` is image-controlled and `/var`
persists across upgrades.

## Reference Implementation

The repo now has two concrete rootless examples:

- Grafana is the fuller migration example with persistent service data:
  - `overlay-root/etc/containers/systemd/users/51210/grafana.container`
  - `overlay-root/usr/lib/sysusers.d/nas-grafana.conf`
  - `overlay-root/usr/lib/tmpfiles.d/nas-grafana-rootless.conf`
  - `overlay-root/etc/subuid`
  - `overlay-root/etc/subgid`
  - `overlay-root/usr/local/bin/ensure-nas-grafana-account.sh`
  - `overlay-root/etc/systemd/system/ensure-nas-grafana-account.service`

- vmalert is the lower-state example with only image-controlled rules:
  - `overlay-root/etc/containers/systemd/users/51220/vmalert.container`
  - `overlay-root/usr/share/custom-coreos/vmalert/alert-rules.yml`
  - `overlay-root/usr/lib/sysusers.d/nas-vmalert.conf`
  - `overlay-root/usr/lib/tmpfiles.d/nas-vmalert-rootless.conf`
  - `overlay-root/usr/local/bin/ensure-nas-vmalert-account.sh`
  - `overlay-root/etc/systemd/system/ensure-nas-vmalert-account.service`

Read those first if you want the exact concrete implementation.

## Decisions We Made

### 1. Rootless host service, not necessarily non-root inside the container

In this repo, "rootless" means Podman runs the container under an unprivileged
host account such as `_nas_grafana`.

That does not require the process inside the container to run as a non-root
container UID. Grafana still uses `User=0` in the Quadlet. Inside a rootless
user namespace, container root maps back to the unprivileged host account, not
to host root.

Use this mental model:
- host identity controls what the service can do on the machine
- container `User=` controls what the process sees inside the container

Do not couple those two decisions unless the image actually requires it.

### 2. The working user Quadlet path in this repo is `/etc`, not `/usr/share`

We wanted an immutable Quadlet path under `/usr/share/containers/systemd/`.
That did not work for this setup.

With Fedora 43 and Podman 5.8.1, placing Grafana at
`/usr/share/containers/systemd/users/51210/grafana.container` caused Podman to
generate a system unit in `system.slice`. The service ran rootfully even though
the file was under a `users/$UID/` subdirectory.

The working path is:

```text
/etc/containers/systemd/users/$UID/$SERVICE.container
```

That is persistent rather than immutable, but it is the path that actually
generates a user unit for this repo.

### 3. The service account must not be fully locked

The first attempt used `u!` in `sysusers.d`. That broke the lingering user
manager:

```text
user@51210.service -> status=224/PAM
User account has expired
```

For a rootless service account that needs `user@$UID.service`, use:
- `u`, not `u!`
- `/sbin/nologin` as the shell
- an invalid password marker such as `*` if you need to repair an existing host

The account should be non-interactive, but still acceptable to PAM for the
lingering user manager.

### 4. Subordinate IDs are part of the contract

Rootless Podman needs `subuid` and `subgid` ranges. In this repo we ship them
explicitly:

```text
_nas_grafana:512100000:65536
```

The convention is:
- reserve `51000-51999` for image-managed service accounts
- keep `511xx` for storage, `512xx` for observability, `513xx` for ingress
- derive a readable subordinate range from the host UID where practical

### 5. Separate image-controlled inputs from mutable service state

The split that worked for Grafana was:
- `/usr/share/custom-coreos/<service>` for image-controlled config, dashboards, provisioning, scripts, or other read-only assets
- `/var/lib/<service>` for persistent mutable service data
- `/var/home/<user>` for the rootless Podman home and user-scoped runtime state

Do not put mutable data under `/usr`. Do not expect new images to repair stale
files already living under `/var`.

### 6. Prefer persistent SELinux labeling for large service data

For large or long-lived data directories, do not rely on `:Z` or `:z` mounts on
every start. Use:
- `semanage fcontext -a|-m`
- `restorecon -F -R`

That avoids recursive relabel work on each start and survives container restarts
cleanly.

For small config mounts, `:Z` or `:z` can still be fine.

### 7. Treat cross-manager dependencies as fragile

A rootless user unit should not directly depend on system units like
`victoria-metrics.service`. Keep the user service able to start independently
and let the application retry if its upstream is not ready yet.

### 8. Boot-time repair may be necessary on upgrades

bootc upgrades preserve `/var`, which means old account metadata, missing
subordinate IDs, or stale SELinux rules can outlive the image change.

Grafana needed a repair service because the persisted host state from earlier
attempts was not guaranteed to match the new image.

Use a repair service when either of these is true:
- you are migrating an already-deployed service
- correctness depends on persisted account metadata in `/etc`, `/var`, or the SELinux policy store

For a brand-new service on a brand-new machine, you may not need one.

## Required File Set

For a new rootless service in this repo, plan on these files:

```text
overlay-root/etc/containers/systemd/users/$UID/$SERVICE.container
overlay-root/usr/lib/sysusers.d/$SERVICE.conf
overlay-root/usr/lib/tmpfiles.d/$SERVICE-rootless.conf
overlay-root/etc/subuid
overlay-root/etc/subgid
```

Often you will also want:

```text
overlay-root/usr/share/custom-coreos/$SERVICE/...
overlay-root/usr/local/bin/ensure-$SERVICE-account.sh
overlay-root/etc/systemd/system/ensure-$SERVICE-account.service
```

And if you ship read-only assets or persistent data, add the corresponding
`semanage fcontext` / `restorecon` calls in `Containerfile`.

## How To Adapt An Existing Rootful Quadlet

Start from the existing system Quadlet under `overlay-root/etc/containers/systemd/`.

### 1. Decide whether the service is a good rootless candidate

Good candidates:
- use host networking or high ports without privileged bind requirements
- write only to a small number of known directories
- do not need broad host privileges
- can tolerate starting before their dependencies are fully ready

Bad candidates:
- need direct device access
- need privileged mounts or broad host filesystem access
- rely heavily on ordering against system units

### 2. Allocate a host identity

Pick:
- a namespaced host username such as `_nas_<service>`
- a UID/GID in the reserved service range
- a `65536`-wide subordinate ID range
- a home under `/var/home/<user>`

Do not reuse upstream container UIDs like `472` as the host identity. Host and
container identities solve different problems.

### 3. Split the service inputs and state

Before editing the Quadlet, classify every mount:
- image-controlled and read-only -> move under `/usr/share/custom-coreos/<service>`
- persistent mutable data -> keep under `/var/lib/<service>`
- secrets or host-local config -> keep wherever the rest of the repo already manages them

If the current rootful Quadlet uses a large data directory with `:Z`, plan to
replace that with persistent SELinux labeling.

### 4. Move the Quadlet into the user search path

Move:

```text
overlay-root/etc/containers/systemd/$SERVICE.container
```

to:

```text
overlay-root/etc/containers/systemd/users/$UID/$SERVICE.container
```

Do not use `/usr/share/containers/systemd/users/$UID/` in this repo.

### 5. Rewrite the unit with user-manager assumptions

Typical changes:
- drop `WantedBy=multi-user.target`; use `WantedBy=default.target`
- remove `After=` and `Requires=` edges that point at system services
- keep the service self-contained
- keep `Network=host` only if the service genuinely needs it
- keep or change container `User=` based on image behavior, not host rootless goals

For Grafana, `User=0` stayed because rootless host execution already removed host
root privileges and the image behavior was simpler that way.

### 6. Add account provisioning

Add:
- a `sysusers.d` file for the host user/group
- a `tmpfiles.d` file for the home, container state directories, data directory, and linger marker
- explicit `subuid` and `subgid` entries

If the service is replacing an already-deployed rootful service, decide whether
you also need a repair service to correct persisted state on upgrade.

### 7. Add or update SELinux policy setup

If the service uses image-controlled assets under `/usr/share/custom-coreos` or
large persistent data under `/var/lib/<service>`, add matching `semanage
fcontext` rules and `restorecon` calls in `Containerfile`.

### 8. Enable any repair unit

If you added `ensure-$SERVICE-account.service`, enable it in `Containerfile`
before expecting the rootless user manager to start reliably on an upgraded
host.

### 9. Validate with the right commands

For rootless services, validate from the service account context:

```bash
sudo -u _nas_service env HOME=/var/home/_nas_service \
  XDG_RUNTIME_DIR=/run/user/UID \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/UID/bus \
  bash -lc 'cd / && systemctl --user status service.service --no-pager && podman ps -a --no-trunc'
```

Do not run `sudo -u ... podman ...` from an unreadable current working
directory, or `sudo` will fail before Podman ever starts.

## How To Create A New Rootless Quadlet From Scratch

### 1. Pick the service contract first

Define these before writing files:
- service name
- host username
- host UID/GID
- subordinate ID range
- mutable data path
- read-only asset path, if any
- whether the service needs a repair unit or can rely on first-boot provisioning only

### 2. Copy the starter templates

The starter templates live here:
- `docs/templates/rootless-quadlet/service.container.template`
- `docs/templates/rootless-quadlet/service.sysusers.conf.template`
- `docs/templates/rootless-quadlet/service.tmpfiles.conf.template`
- `docs/templates/rootless-quadlet/ensure-service-account.sh.template`
- `docs/templates/rootless-quadlet/ensure-service-account.service.template`

Replace the placeholders and then move the results into the real `overlay-root`
locations.

### 3. Keep the file placement consistent

Use this mapping:

| Template | Destination |
| --- | --- |
| `service.container.template` | `overlay-root/etc/containers/systemd/users/$UID/$SERVICE.container` |
| `service.sysusers.conf.template` | `overlay-root/usr/lib/sysusers.d/$SERVICE.conf` |
| `service.tmpfiles.conf.template` | `overlay-root/usr/lib/tmpfiles.d/$SERVICE-rootless.conf` |
| `ensure-service-account.sh.template` | `overlay-root/usr/local/bin/ensure-$SERVICE-account.sh` |
| `ensure-service-account.service.template` | `overlay-root/etc/systemd/system/ensure-$SERVICE-account.service` |

Also add matching entries to:
- `overlay-root/etc/subuid`
- `overlay-root/etc/subgid`

### 4. Keep the first implementation intentionally simple

For the first cut:
- prefer one data directory
- prefer one read-only asset directory
- avoid system-unit dependencies
- avoid custom user namespace mappings unless required
- avoid over-optimizing container UID behavior until the service actually runs

### 5. Add diagnostics before rollout

Before shipping the new service, document:
- how to check the user manager
- how to check `systemctl --user status`
- how to inspect rootless Podman from the service account
- where to look for SELinux denials

The Grafana checklist at `docs/rootless-grafana-checklist.md` is the concrete
example.

## Starter Template Notes

The templates use these conventions:
- `SERVICE_NAME` is the unit and container name, such as `grafana`
- `HOST_USER` is the host account, such as `_nas_grafana`
- `HOST_UID` is the host UID/GID, such as `51210`
- `HOST_SUBID_START` is the first subordinate ID, such as `512100000`
- `HOST_SUBID_COUNT` is normally `65536`
- `IMAGE_REF` is the container image reference
- `DATA_PATH` is the mutable host path under `/var/lib/...`
- `ASSET_PATH` is the optional image-controlled read-only tree under `/usr/share/custom-coreos/...`

The templates are intentionally conservative. Copy them, then delete anything
the service does not need.

## Pitfalls We Already Hit

- `u!` in `sysusers.d` broke `user@$UID.service` with PAM account-expired errors
- `/usr/share/containers/systemd/users/$UID/` generated a system unit instead of a user unit in this environment
- missing `subuid` and `subgid` would have broken rootless Podman even after PAM was fixed
- validating rootless Podman from an unreadable current directory made `sudo -u` fail before Podman started
- putting large persistent data under `:Z` would have forced expensive relabeling on every start

## When Not To Use This Pattern

Stay rootful if the service genuinely needs:
- direct hardware or device access
- privileged mounts
- tight coordination with system units that cannot be relaxed
- broad host filesystem access that would defeat the point of the rootless split

## Validation

After changes, run:

```bash
just generate-ignition
just test-build
```

Then validate the live host using service-specific read-only checks.
