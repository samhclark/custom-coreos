# Caddy Rootless Migration Preflight

Caddy is being migrated in two releases because it is the host's TLS edge,
owns ACME account and certificate state, and is the only remaining rootful
consumer of the Podman secret driver. This document covers the first,
rootful-safe preflight release only. It does not change Caddy's runtime
identity, configuration mount, persistent-state ownership, SELinux labels, or
live listeners.

## What This Release Changes

The release reserves `_nas_caddy` with UID/GID `51310` and subordinate range
`513100000:65536`. `quadlets/caddy.toml` has `enabled = false`, so the generator
creates the account, home, linger, and subordinate-ID configuration but
deliberately does not create a rootless Caddy Quadlet.

The SOPS distributor writes a second copy of `cf-api-token` to
`/run/nas-secrets/caddy/cf-api-token`, owned by `_nas_caddy` and mode `0400`.
The existing rootful Podman secret remains in place and rootful Caddy continues
to consume it.

The image also ships this sysctl policy:

```ini
net.ipv4.ip_unprivileged_port_start = 80
```

This permits rootless Caddy to bind TCP 80/443 and UDP 443 with host
networking. It is host-wide: any unprivileged process may bind an available
port from 80 upward. It does not displace an existing listener or bypass the
host firewall.

Five minutes after boot, `caddy-rootless-preflight.timer` starts a one-time
read-only inspection. It verifies the rootful service, rootless identity and
Podman store, dual secret delivery, the effective sysctl, TCP and UDP low-port
binding on unused loopback port 81, Caddy configuration, current listeners,
metrics, and representative HTTP/HTTPS routing. It records state metadata
under `/var/lib/nas-migrations/caddy-rootless-preflight-v1/` and writes
`complete` only after every required check passes.

The preflight scans ownership, modes, SELinux contexts, entry counts, and
sizes under `/var/lib/caddy` and `/var/lib/caddy-config`. It does not change
those trees. Existing private `:Z` labels may include MCS categories; that is
expected evidence for the cutover rather than a preflight failure.

## Post-Deployment Check

Deploy this release through the normal reboot-based bootc workflow, then run:

```bash
sudo systemctl status caddy.service --no-pager
sudo systemctl status ensure-nas-caddy-account.service --no-pager
sudo systemctl status caddy-rootless-preflight.timer --no-pager
sudo systemctl status caddy-rootless-preflight.service --no-pager
sudo journalctl -u caddy-rootless-preflight.service -b --no-pager
```

The expected state is:

- `caddy.service` remains an active system service and the rootful container is
  unchanged
- no `/etc/containers/systemd/users/51310/caddy.container` exists
- no Caddy container exists in `_nas_caddy`'s rootless Podman store
- `_nas_caddy`, its subordinate IDs, linger state, and user manager exist
- `net.ipv4.ip_unprivileged_port_start` is `80`
- the rootful and runtime copies of `cf-api-token` are present and identical
  without either value appearing in the report
- TCP 80/443 and UDP 443 remain owned by production Caddy
- Caddy's configuration, metrics endpoint, HTTP redirect, and Garage health
  route validate successfully
- `/var/lib/caddy` and `/var/lib/caddy-config` remain entirely root-owned and
  use the `container_file_t` SELinux type; their modes, contents, and existing
  private MCS categories remain unchanged

List the evidence without reading any secret value:

```bash
sudo find /var/lib/nas-migrations/caddy-rootless-preflight-v1 \
  -maxdepth 1 -type f -printf '%f\n' | sort
sudo grep -H . \
  /var/lib/nas-migrations/caddy-rootless-preflight-v1/{sysctl,identity,rootless-podman,rootful-unit,image,version,config,listeners,mounts,roots,caddy-data-scan,caddy-config-scan,secret-routing,metrics,http-redirect,https-garage-health}.txt
```

`state-inventory.txt` contains only paths and sizes, not file contents. It is
root-readable migration evidence and does not need to be copied off the NAS.

## Failure And Rerun

A failed command leaves the partial report but no `complete` marker. Inspect
the journal and evidence before rerunning:

```bash
sudo systemctl reset-failed caddy-rootless-preflight.service
sudo systemctl start caddy-rootless-preflight.service
```

To deliberately refresh a completed report, remove only its marker:

```bash
sudo rm -f /var/lib/nas-migrations/caddy-rootless-preflight-v1/complete
sudo systemctl start caddy-rootless-preflight.service
```

Do not chown, relabel, move, stop, or manually replace any Caddy state during
this stage. The cutover release will archive the two persistent trees, apply a
guarded root-last ownership migration, install persistent SELinux policy, move
the static Caddyfile into `/usr/share/custom-coreos/caddy/`, and retire the
rootful Quadlet through a reboot.
