# Roadmap: Rootless Platform Migration

This file records the decisions from the July 2026 repo review and the work
remaining. The goal driving all of it: spend time using the NAS, not
maintaining it.

## Decisions (settled — do not re-litigate without new evidence)

1. **Rootless secrets use runtime files, not Podman `Secret=`.**
   The root-owned `sops-distribute-secrets.service` decrypts SOPS once at boot
   and writes per-service files under `/run/nas-secrets/<service>/`, owned by
   the service user, mode 0400, mounted `:ro,Z` into containers (relabeling
   `/run` tmpfs files from rootless Podman is NAS-validated). Rootless Podman
   secrets via the shell driver are a validated dead end. Full findings:
   `docs/plan-sops-and-quadlet-generator.md` Appendix D.

2. **libkrun is a per-service dial, not an architecture.**
   Volumes cross into a libkrun microVM via virtiofs (host kernel keeps ZFS;
   no NFS layer needed). Enabling it is a per-unit runtime flag
   (`PodmanArgs=--runtime krun`), and bind-mounted secret files carry over
   unchanged. Incremental feasibility and deployment work is now tracked in
   `docs/plan-libkrun-quadlets.md`. Mixed crun/krun operation is an acceptable
   final state; storage-heavy services and Caddy must earn the change through
   NAS evidence.

3. **Rootless boilerplate is generated, never hand-edited.**
   `quadlets/<service>.toml` + `generate-quadlets.py` produce everything;
   CI fails on drift. The TOMLs double as the secret-routing manifest for
   the distributor.

4. **Caddy uses the validated rootless low-port policy.**
   `_nas_caddy` binds TCP low ports with
   `net.ipv4.ip_unprivileged_port_start=80`; its persistent state is maintained
   by a steady-state host preparation service. Caddy is configured for a
   private outer pasta namespace plus inner krun passt: only TCP 80/443, UDP
   443, and loopback TCP 2019 are published, while pasta `-T` explicitly
   allowlists host-loopback backends. This restores HTTP/3 and avoids TSI's
   stream head-of-line blocking. Rootless crun with root-owned TCP/UDP sockets
   remains the fallback.

5. **Service UIDs are allocate-only.** Never reuse a retired UID; numeric
   file ownership (especially in ZFS snapshots) outlives the user. Scheme
   and current allocations live in AGENTS.md; `quadlets/*.toml` is the
   active registry.

## Done (July 2026)

- Distributor rewritten to the runtime-file design; validated on the NAS
  end-to-end, deployed, and verified across two reboots.
- Quadlet generator built; grafana, vmalert, and blackbox-exporter converted
  with no functional diff; CI drift check active.
- Alertmanager migrated to a rootless Quadlet and validated on the NAS,
  including runtime Pushover credentials, health and metrics endpoints,
  Grafana visibility, and successful synthetic-alert delivery to Pushover.
- VictoriaMetrics and Garage migrated to rootless Quadlets and were validated
  on the NAS, including their guarded ZFS ownership conversions, preserved
  history/object state, runtime secrets, monitoring, and rollback paths.
- Caddy's rootless preflight completed on the NAS on 2026-07-21. UID `51310`,
  runtime-secret delivery, TCP/UDP low-port binding, rootful state inventory,
  listeners, metrics, redirect, and Garage routing are production-validated.
- Caddy's phase-two rootless cutover was deployed and validated on the NAS.
  The final rootful container residue and shell secret-driver stack were
  retired on 2026-07-25.
- Migration-only runtime scaffolding was replaced with steady-state Caddy,
  Garage, and VictoriaMetrics preparation; historical details remain in the
  migration checklists.
- Cockpit deleted (quadlet, packages, Caddy vhost).

## Remaining work (in order)

- [x] **1. First production rootless secret.** Done 2026-07-04: grafana
      mounts `garage-metrics-token` via the runtime-file path. Verified on
      the NAS: distributor writes the file at boot from the image-shipped
      TOML, grafana's user service starts ~12s later with the ExecStartPre
      guard passing (boot ordering needs no cross-manager dependency), and
      the container reads the mounted file with matching content. The
      missing-file case is bounded by design (guard fails the start;
      Restart=always retries every 30s) and was not observed live. This
      proof-only Grafana mount is removed by the VictoriaMetrics migration;
      VictoriaMetrics becomes the real rootless consumer of that token.
- [x] **2. Finish the Caddy rootless migration.** Done 2026-07-25: the
      guarded phase-two cutover was deployed and validated, the stopped
      rootful container and legacy files were removed, and the unused shell
      secret-driver stack was retired.
- [x] **3. Implement the selected Caddy krun/TSI conversion.** Done 2026-08-05:
      used the existing rootless user-Quadlet path with 2 vCPUs, 512 MiB,
      SIGINT shutdown, and HTTP/1.1 plus HTTP/2 only. The low-port sysctl and
      host-loopback reverse proxies remain; operations do not rely on
      `podman exec`. The build, bootc deployment boot, krun runtime,
      resources, TCP-only listener topology, all routes, metrics, secret/state
      contracts, exact state preservation, bounded recovery, and clean SIGINT
      shutdown all passed production validation.
- [x] **3a. Replace streaming TSI with private nested passt.** Implemented
      2026-08-06 after a stalled Jellyfin client blocked Caddy's synchronous
      TSI send path and then Jellyfin's. Two concurrent guests proved crun's
      broad inner passt listeners are isolated by separate outer pasta
      namespaces. An explicit pasta `-T` mapping reached a loopback-only host
      backend, and a 1.28-MiB backpressured response left 20 health probes at
      zero failures with 2.9 ms maximum latency while the VMM waited in
      `epoll`. Production deployment validation remains.
- [x] **4. Add Renovate.** Done 2026-08-05: the hosted app is active and has
      opened working GitHub Actions, Grafana, and grouped VictoriaMetrics
      updates. Custom regex managers cover `quadlets/*.toml` and the SOPS build
      stage; image references use pinned tags and digests. Major, minor, and
      patch PRs wait for a three-day minimum release age where the datasource
      supplies timestamps. Missing timestamps remain eligible so GHCR/Quay
      dependencies do not become permanently blocked. Renovate updates source
      TOMLs; maintainers regenerate and commit `overlay-root/` before merging
      container-image PRs.
- [ ] **5. New services** (the actual goal): Jellyfin is image-defined and
      awaiting production validation; immich, audiobookshelf, and *arr remain.
      Each service starts with one TOML + UID + Containerfile enable
      line + SOPS values + Caddy vhost, per the pipeline below.
- [ ] **6. Small cleanups**, opportunistically:
      - NAS-local cockpit residue (manual, one-time):
        `sudo rm -rf /etc/cockpit` and
        `sudo podman rmi quay.io/cockpit/ws:latest`. The `cockpit-ws`
        passwd entry stays — it ships in Fedora CoreOS's static sysusers,
        not from this repo.
      - De-duplicate README.md vs AGENTS.md.
      - Done 2026-08-08: replace the six rotating `zfs-snapshot-*.sh`
        implementations with one create-first, retention-based helper under
        `/usr/local/bin/`; legacy managed names age out without touching
        manual snapshots.

## New-service pipeline

Adding a service should cost: one `quadlets/<name>.toml` (UID from the
scheme in AGENTS.md), `python3 generate-quadlets.py`, one
`systemctl enable ensure-nas-<name>-account.service` line in the
Containerfile, secret values in `secrets.sops.yaml`, a Caddy vhost if
user-facing, and a deploy. Anything beyond that is a defect in the platform
layer and worth fixing there instead of working around per-service.
