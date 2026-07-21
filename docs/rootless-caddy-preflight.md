# Caddy Rootless Migration Preflight (Completed)

> **Production status (2026-07-21):** The preflight completed successfully on
> the NAS. Rootful Caddy remained healthy throughout, and the successful report
> is recorded under `/var/lib/nas-migrations/caddy-rootless-preflight-v1/`.
> Phase two is the guarded reboot-based rootless cutover described at the end of
> this document.

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

Confirm the durable completion marker with:

```bash
sudo test -e /var/lib/nas-migrations/caddy-rootless-preflight-v1/complete \
  && echo "Caddy preflight complete"
```

## Production Findings

The successful run established all of the following on the deployed NAS:

- `_nas_caddy` is usable as UID/GID `51310`, has its reserved subordinate-ID
  range, linger, an active user manager, and a working rootless Podman store
- `net.ipv4.ip_unprivileged_port_start=80` permits direct TCP and UDP binding
  by `_nas_caddy`; the ephemeral port range remains disjoint
- the staged runtime Cloudflare token is readable by `_nas_caddy` and matches
  the active rootful Podman secret without exposing either value
- rootful Caddy uses the expected image, host networking, valid configuration,
  TCP 80/443, UDP 443, metrics endpoint, redirect, and Garage health route
- `/var/lib/caddy` and `/var/lib/caddy-config` are small root-owned trees with
  `container_file_t` labels and private MCS categories from their current `:Z`
  mounts

The first run also found an obsolete
`/var/lib/caddy/secrets/cf-api-token` owned by `1000:1000`. Its January 2026
timestamps and differing content confirmed that it was neither active secret
copy. It was removed before the successful rerun. The now-obsolete
`/var/lib/caddy/secrets` tmpfiles declaration still needs to be removed during
phase two.

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

## Phase-Two Handoff

Do not chown, relabel, move, stop, or manually replace Caddy state before the
cutover implementation is ready. Phase two should be one reviewable,
reboot-based transition with these elements:

1. Archive the two small persistent trees before mutation and retain the
   preflight report as the comparison baseline.
2. Add a guarded preparation unit with a durable completion marker. It must
   verify Caddy is stopped, migrate descendants first and roots last to
   `51310:51310`, install persistent `container_file_t:s0` fcontext rules, and
   use `restorecon -F -R` to clear the old private MCS categories.
3. Move the static Caddyfile from `/etc/caddy/` into
   `/usr/share/custom-coreos/caddy/` so it remains image-controlled.
4. Complete `quadlets/caddy.toml`: enable generation, mount the image-controlled
   Caddyfile, the two prepared state trees, and the runtime Cloudflare token;
   retain host networking and add bounded readiness guards for the secret and
   prepared state.
5. Remove the rootful Caddy Quadlet and the preflight timer, service, script,
   and Containerfile enablement in the same image. The reboot must leave only
   the user-manager Caddy unit eligible to start.
6. Remove the obsolete `/var/lib/caddy/secrets` tmpfiles declaration. Once
   rootless Caddy is validated and no `Secret=` consumers remain, retire the
   rootful shell secret-driver configuration, helpers, smoke test, and
   `nas-secrets` wrapper.
7. Validate TCP 80/443, UDP 443, metrics, representative HTTP/HTTPS routes,
   certificate state, logs, rootless Podman identity, state ownership, and
   `container_file_t:s0` labels. Provide a rollback procedure that restores the
   archived trees and the prior bootc deployment without mixing ownership
   states.
