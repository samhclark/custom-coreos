# Plan: Incremental libkrun Adoption for Rootless Quadlets

This is the working plan for evaluating and, where it earns its keep, enabling
libkrun for the NAS's rootless Quadlets.

The plan is intentionally optimized for the system that actually exists:

- there is one NAS
- its administrator is physically nearby
- work will happen in small sessions, often one service at a time
- a short planned outage and a manual command are acceptable
- each session may be handled by an agent with no memory of the previous one

Do not turn this into a general migration framework. Preserve data, record
evidence, and keep rollback understandable; do not build elaborate compatibility
or zero-downtime machinery for a fleet of one.

## Current Status

Update this block at the end of every implementation or NAS-validation session.
Also append a row to the session log at the bottom of this file.

| Field | Value |
| --- | --- |
| Overall status | Phase 1A is committed and pushed; assume scheduled deployment; no production service uses libkrun |
| Last completed work | 2026-07-28 Phase 1A: added `crun-krun`, passed local image validation, and pushed to `main` |
| Current phase | Phase 1A: validate krun on the NAS |
| Next concrete action | Operator runs `krun --version` on the NAS |
| Production libkrun services | None |
| Known production exceptions | None yet; Caddy is expected to need a separate decision |
| Last NAS validation | 2026-07-28: `/dev/kvm` exists; `krun` is not installed |

## Outcome

The desired end state is not necessarily "all services use libkrun." The
desired end state is:

1. Every good candidate runs in a libkrun microVM with explicit CPU and memory
   sizing.
2. Services stay rootless under their existing `_nas_*` host identities.
3. Runtime secrets, image-controlled assets, persistent state, ZFS ownership,
   and SELinux policy keep their current contracts.
4. Services that become materially less reliable, slower, or more complicated
   remain on ordinary crun, with the reason recorded here.
5. Caddy gets its own networking and socket-activation decision rather than
   forcing the rest of the migration to wait.

## Settled Working Assumptions

These are starting assumptions, not substitutes for NAS evidence.

- libkrun is a per-service isolation dial. Mixed crun and krun services are a
  valid permanent state.
- Fedora provides the required `crun-krun`, `libkrun`, and `libkrunfw`
  packages. `crun-krun` supplies the `krun` entry point and dependency chain.
- The intended first networking mode is libkrun's default Transparent Socket
  Impersonation (TSI), not passt. TSI best matches the current design in which
  services communicate through host `127.0.0.1`.
- TSI supports incoming and outgoing TCP stream sockets. It does not support
  a guest listening on a UDP socket. This matters for Caddy's HTTP/3 listener.
- Bind mounts are presented through virtiofs. The host still owns ZFS; the
  guest does not need ZFS kernel support.
- The VMM runs in the rootless service's host security context. libkrun adds a
  guest-kernel boundary, but it does not make bind-mounted data inaccessible
  to a compromised service that was already allowed to mount that data.
- Each krun service must have explicit resources. The upstream defaults are
  too broad for seven always-on services: 1024 MiB when no memory limit is
  supplied, and the process's available CPUs up to libkrun's limit.

Primary references:

- [libkrun networking and security model](https://github.com/libkrun/libkrun)
- [crun krun runtime and annotations](https://github.com/containers/crun/blob/main/krun.1.md)
- [Fedora `crun-krun` package](https://packages.fedoraproject.org/pkgs/crun/crun-krun/)
- [Podman Quadlet `PodmanArgs=`](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html#podmanargs)

## Single-NAS Working Style

Optimize for one operator changing one nearby NAS in short evening sessions,
not for an unattended fleet rollout.

- Ask one concrete question at a time. Run the smallest command that decides
  it, record the answer, and stop.
- Gather evidence when a decision needs it, not because it might be useful in
  a later phase.
- Prefer a short copy-paste command over a checked-in diagnostic script. Add a
  script only when the procedure is repeated, error-prone, or valuable as a
  maintained repository tool.
- Manual intervention and a brief planned outage are acceptable. Add
  automation or zero-downtime preparation only when its benefit exceeds the
  cost of doing the operation by hand once.
- A change committed and pushed to `main` is picked up by the scheduled image
  build and NAS update. In a later session, assume it is deployed unless
  evidence says otherwise; do not insert a manual publish or deployment step.
- Recovery preparation should match the actual risk of the current change.
  Do not build fleet-style guardrails around a reversible runtime experiment.

## Rules for Every Fresh Session

A fresh agent should begin here, even if the requested task sounds narrow.

1. Read `AGENTS.md`, Current Status, Single-NAS Working Style, the phase in
   scope, the latest session-log rows, and the source TOML for the service in
   scope. Other phases and evidence are optional until they become relevant.
2. Run `git status --short --branch`. Preserve unrelated user changes.
3. Use Current Status as the handoff. Ask the operator for NAS evidence only
   when the current decision depends on deployed state.
4. State which single phase or service is in scope. Do not opportunistically
   convert the next service.
5. For a production-service phase, capture only the before-state needed to
   recognize success or rollback. Collect resource measurements when choosing
   resource limits, not automatically at the start of every session.
6. Make source changes in `quadlets/*.toml` or the generator. Never hand-edit a
   file with a `GENERATED` header.
7. Run the relevant local tests and build verification.
8. Deploy with the normal bootc workflow. A manual stop/start or brief outage
   is acceptable when it makes the cutover easier to understand.
9. Validate on the NAS using the phase checklist.
10. Update Current Status and append a session-log row after NAS evidence,
    implementation changes, or a newly discovered blocker changes the handoff.
    A repo-only reread that discovers nothing new should leave the plan clean.

If a session ends before deployment, say so in Current Status. Do not leave the
next agent to infer whether a checked-in change reached the NAS.

## NAS Operator-Execution Protocol

Agents must never execute commands on the NAS, including through SSH. When NAS
evidence or action is required, the agent prepares a reviewed copy-paste
command and explains its expected effects. The operator runs it and returns
the output.

Follow Single-NAS Working Style: prefer the smallest command that answers the
current question, and do not collect a general baseline. Keep state-changing
operations separate and explain their effects, validation, and rollback before
asking the operator to run them.

Agents may inspect returned output and prepare the next command, but may not
open or reuse an authenticated NAS session themselves. Do not substitute
development-laptop evidence for NAS evidence.

### Completed Phase 0A check

```bash
krun --version
test -e /dev/kvm && echo "/dev/kvm exists"
```

The operator reported that `krun` is absent and `/dev/kvm` exists. Do not ask
for a broader baseline or repeat these checks until the Phase 1A image is
deployed.

## Evidence Menu for Service Conversions

This is a menu, not a preflight checklist. Select evidence that answers the
current phase's question. By the end of a completed conversion, retain enough
of it to prove the new runtime is in use and the service still works.

Use the service account's environment when inspecting its user manager and
Podman store:

```bash
service_user=_nas_blackbox
service_uid=51230

sudo -u "${service_user}" env \
  HOME="/var/home/${service_user}" \
  XDG_RUNTIME_DIR="/run/user/${service_uid}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${service_uid}/bus" \
  systemctl --user status blackbox-exporter.service --no-pager

sudo -u "${service_user}" env \
  HOME="/var/home/${service_user}" \
  XDG_RUNTIME_DIR="/run/user/${service_uid}" \
  podman inspect blackbox-exporter
```

Depending on the phase, useful evidence includes:

- generated `podman run` command from `systemctl --user cat`
- `podman inspect` runtime and annotations
- host and guest `uname -r` values
- service health and expected listeners
- the last relevant journal entries
- SELinux AVCs, if any
- cgroup `MemoryCurrent`, `MemoryPeak`, and CPU use where available
- whether stop, restart, and reboot behave normally
- actual outage duration if the cutover was noticeable

A krun conversion is not proven merely because the application answers HTTP.
The guest kernel should differ from the host kernel, and inspection/logs must
show the krun runtime was used.

## Resource Starting Points

These are experiment values, not promises. Capture the current service's
ordinary-crun usage before selecting the final limit.

| Service | Initial vCPUs | Initial RAM MiB | Notes |
| --- | ---: | ---: | --- |
| blackbox-exporter | 1 | 128 | Minimum viable canary |
| vmalert | 1 | 256 | Small but active evaluator |
| Alertmanager | 1 | 256 | Small persistent state and outbound notifications |
| Grafana | 2 | 512 | Plugins and SQLite need headroom |
| VictoriaMetrics | 2 | 1024 | Tune only after observing compactions |
| Garage | 2 | 1024 | Tune after object and SQLite testing |
| Caddy | 2 | 512 | Revisit after networking design is selected |

Do not reduce a limit simply to make the table look efficient. This NAS should
be boring to operate.

## Phase Summary

| Phase | Scope | Production behavior changed? | Completion gate |
| --- | --- | --- | --- |
| 0A | Minimal capability check | No | Runtime presence and `/dev/kvm` existence recorded |
| 1A | Image packages, if absent | Packages only | Rebooted image exposes a working krun runtime |
| 0B | Disposable krun smoke test | No | KVM, runtime, bind mount, and TSI TCP proven |
| 1B | Generator schema | No | Generated files without `[krun]` stay stable |
| 2 | blackbox-exporter | Yes | Probe path and monitoring remain healthy |
| 3 | vmalert | Yes | Rules evaluate and reach VictoriaMetrics/Alertmanager |
| 4 | Alertmanager | Yes | Secrets, persistence, and real notification work |
| 5 | Grafana | Yes | Dashboards, plugin, persistence, and restart work |
| 6 | VictoriaMetrics | Yes | Historical data, ingestion, scrapes, and virtiofs performance work |
| 7 | Garage | Yes | SQLite, objects, journald, networking, and virtiofs performance work |
| 8 | Caddy and low ports | Yes | Explicit socket/networking decision validated |
| 9 | Cleanup and steady-state docs | No intended change | Obsolete experiments removed and final exceptions documented |

## Phase 0: NAS Baseline and Disposable Smoke Test

### Goal

Answer the cheapest feasibility questions on the real NAS before committing
the image or generator to a design.

Phase 0 is deliberately split:

- **0A** checks for the runtime and `/dev/kvm`.
- If krun packages are absent, perform only the package portion of Phase 1
  (**1A**), deploy it, and return here.
- **0B** runs the disposable smoke test.
- The generator portion of Phase 1 (**1B**) follows only after the manual
  runtime syntax is proven.

### Phase 0A: Minimal capability check

Start with:

```bash
krun --version
test -e /dev/kvm && echo "/dev/kvm exists"
```

If `krun` is absent, move to the package-only Phase 1A. If `/dev/kvm` is absent,
stop and investigate the host. User-specific access, SELinux, package details,
and resource baselines can wait until a smoke test or service conversion
actually requires them.

### Phase 0B: Disposable smoke test

Use an already-trusted small image if practical. The smoke test must not use a
production container name or production port.

Prove, in order:

1. a rootless service user can start `podman run --runtime=krun`
2. `uname -r` reports the libkrun guest kernel
3. a read-only bind mount is readable
4. a TCP listener on an unused loopback port is reachable from the host
5. the guest can connect to an existing host-loopback HTTP endpoint
6. SELinux remains enforcing without relevant AVCs
7. the process stops cleanly and leaves no disposable container behind

Prefer a small manual command over adding a permanent test service at this
stage. Before running it, write down the proposed command and confirm that it
uses a pinned or already-pulled trusted image, an explicit disposable name, an
unused high loopback port, the `_nas_blackbox` HOME/XDG environment, resource
annotations, and cleanup on exit. Do not invent an unpinned test dependency.

The first successful session must record the exact reusable command and
output here. Until the real NAS image inventory is available, do not freeze a
speculative command into the plan.

### Stop conditions

Pause and record evidence if:

- `/dev/kvm` is unavailable to the service identity
- krun silently falls back to ordinary crun
- TSI cannot expose or reach host-loopback TCP
- a normal read-only bind mount fails under SELinux

These are platform questions. Do not compensate inside an individual service.

## Phase 1: Image and Generator Support

### Phase 1A: Image packages

Add the Fedora-packaged krun runtime to the `Containerfile`. Prefer
`crun-krun` and its packaged dependencies over COPRs or locally built
libraries.

After the package-only image is deployed, verify:

```bash
krun --version
```

Inspect packages or linker state only if that command fails. The local image
build already confirmed the packaged dependency chain.

Repeat the disposable Phase 0 smoke test on the image-built installation.

### Phase 1B: Generator schema

After the manual syntax is proven, add first-class source configuration rather
than making every service carry raw Quadlet strings. A reasonable shape is:

```toml
[krun]
enabled = true
cpus = 1
ram-mib = 128
```

Expected generated behavior:

```ini
PodmanArgs=--runtime=krun
Annotation=krun.cpus=1
Annotation=krun.ram_mib=128
```

Requirements:

- `enabled` must be Boolean
- CPU and RAM values must be positive integers
- reject `[krun]` fields when `enabled = false`
- enforce at least 128 MiB because lower values are ignored upstream
- do not add `krun.use_passt` to the normal service schema until a service
  actually proves it needs passt
- services without `[krun]` must generate byte-for-byte identical output
- add generator unit tests for valid rendering and invalid inputs

Run:

```bash
python3 -m unittest discover -s tests -v
python3 generate-quadlets.py
git diff --check
make build
```

Complete this phase without enabling krun for a production service.

## Phase 2: blackbox-exporter Canary

### Why first

Blackbox exporter has no mutable state or secrets. It exercises a read-only
asset mount, an incoming loopback TCP listener, and an outgoing loopback HTTP
probe.

### Before

Record:

```bash
curl -fsS http://127.0.0.1:9115/metrics >/dev/null
curl -fsSG http://127.0.0.1:9115/probe \
  --data-urlencode module=http_2xx \
  --data-urlencode target=http://127.0.0.1:3903/health
curl -fsSG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=probe_success{job="garage-health"}'
```

Capture ordinary-crun memory and logs before changing the TOML.

### Change

Enable `[krun]` only in `quadlets/blackbox-exporter.toml`, initially with one
vCPU and 128 MiB. Regenerate and deploy normally.

### Validate

- the user service and container are active
- the runtime and guest kernel prove krun is in use
- port 9115 remains loopback-only
- direct probing of Garage succeeds
- VictoriaMetrics continues receiving `probe_success`
- one manual restart and one reboot recover normally
- memory does not show pathological growth

An observation period of one normal evening or day is enough. There is no need
to invent a week-long soak requirement for a stateless exporter.

### Rollback

Remove `[krun]`, regenerate, deploy, and reboot. No service data is involved.

## Phase 3: vmalert

vmalert is the second network test. It must reach VictoriaMetrics and
Alertmanager through host loopback, and it serves its own loopback endpoint.

Before changing it, record active rule groups and alert state. After deploying:

```bash
curl -fsS http://127.0.0.1:8880/metrics >/dev/null
curl -fsS http://127.0.0.1:8880/api/v1/rules
curl -fsS http://127.0.0.1:8428/-/healthy
curl -fsS http://127.0.0.1:9093/-/healthy
```

Confirm rule evaluation timestamps continue advancing and there are no
connection failures to `127.0.0.1:8428` or `127.0.0.1:9093`.

Rollback is runtime-only and does not change persistent data.

## Phase 4: Alertmanager

This phase proves runtime secret bind mounts, small writable state, outbound
Internet access, and real notification delivery.

Before deployment:

- record current silences
- verify the notification log/data directory
- confirm both runtime secret files without printing their values

After deployment:

- verify both secret mounts are readable in the guest
- verify `/alertmanager` is writable and existing state remains
- check `/-/healthy` and `/metrics`
- send the existing synthetic alert and confirm Pushover delivery
- restart the service and confirm silences/state remain
- check for SELinux AVCs involving `/run/nas-secrets` or
  `/var/lib/alertmanager`

A failed real notification is a rollback condition even if the HTTP health
endpoint is green.

## Phase 5: Grafana

Grafana proves a larger writable btrfs-backed state tree, SQLite, image-owned
provisioning, plugin persistence, and queries to VictoriaMetrics.

Before deployment:

- record the installed plugin version
- record the Grafana database size and ownership
- open the existing dashboards and choose a time range spanning the cutover

After deployment:

- verify `/api/health`
- confirm the VictoriaMetrics datasource plugin loads without reinstall loops
- check every provisioned dashboard
- restart once and confirm the database and plugin persist
- verify the listener remains loopback-only
- compare page/query latency with the ordinary-crun baseline

Do not add a migration archive for this runtime-only change. The existing
state tree is mounted unchanged, and a manual rollback is sufficient.

## Phase 6: VictoriaMetrics

VictoriaMetrics is the first storage-performance gate. The functional
filesystem contract should survive virtiofs, but that must be demonstrated
with the real TSDB and workload.

### Before deployment

Stop VictoriaMetrics briefly and take a ZFS snapshot:

```bash
sudo -u _nas_victoriametrics env \
  HOME=/var/home/_nas_victoriametrics \
  XDG_RUNTIME_DIR=/run/user/51250 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51250/bus \
  systemctl --user stop victoria-metrics.service

sudo zfs snapshot \
  "tank/victoria-metrics/data@pre-krun-$(date +%Y%m%d-%H%M%S)"
```

Start it again if deployment is not immediate. Record ingestion rate, active
targets, query latency, dataset space, process memory, and recent compaction
behavior.

### Validate after deployment

- the dataset source and ownership are unchanged
- the runtime secret remains readable
- historical data spans the deployment reboot
- new samples arrive from all configured jobs
- vmalert and Grafana continue querying successfully
- compactions complete without permission, locking, or I/O errors
- query and ingestion latency remain acceptable during normal NAS use
- a clean restart recovers the TSDB

Use at least one period containing normal scrape ingestion and a compaction.
There is no fixed multi-day soak requirement; record what was actually
observed.

### Rollback

First revert the runtime and deploy. Roll back the ZFS snapshot only if the
TSDB itself was damaged; ordinary performance disappointment does not justify
discarding post-snapshot samples.

## Phase 7: Garage

Garage has the highest data and networking risk:

- SQLite metadata on virtiofs
- object blocks on virtiofs
- three published loopback ports plus a private RPC listener
- an absolute-path journald socket
- several runtime secrets

Do not combine its runtime conversion with a port-layout redesign unless the
manual smoke test proves the current publication model cannot work.

### Before deployment

Plan a short outage. Stop Garage and snapshot both datasets:

```bash
sudo zfs snapshot \
  "tank/garage/meta@pre-krun-$(date +%Y%m%d-%H%M%S)"
sudo zfs snapshot \
  "tank/garage/data@pre-krun-$(date +%Y%m%d-%H%M%S)"
```

Record:

- current listeners on 3900-3903
- a known object's checksum and size
- a small PUT/GET/DELETE test
- Garage health and metrics
- recent journald output
- metadata/data dataset usage

### First networking experiment

Test the existing `PublishPort=` configuration under krun before editing
Garage's bind addresses. Confirm:

- only 3900, 3902, and 3903 are published
- all three remain bound to host loopback
- RPC 3901 is not exposed
- Caddy and VictoriaMetrics can reach their existing endpoints

If it fails, stop and record the exact behavior. A later session may evaluate
loopback binds plus TSI, or passt, as a separate networking change.

### Storage and service validation

- existing metadata opens without SQLite locking or corruption errors
- the known object reads with the same checksum
- new PUT/GET/DELETE operations work
- an unclean test is not required; a normal stop/start recovery is
- journald logging still arrives through the mounted absolute socket
- metrics authorization still works
- object throughput and metadata latency remain reasonable
- dataset ownership and SELinux labels remain unchanged

Rollback the runtime first. Restore snapshots only for demonstrated data
damage, while Garage is stopped.

## Phase 8: Caddy, Socket Activation, and Low Ports

Caddy is a separate design exercise. Do not block earlier services on it.

### Current facts

- Caddy currently uses host networking and binds TCP 80/443 and UDP 443.
- `net.ipv4.ip_unprivileged_port_start=80` allows `_nas_caddy` to bind those
  ports.
- Default libkrun TSI cannot support a guest UDP listener, so HTTP/3 is not
  directly compatible with the simplest krun conversion.
- Caddy can consume inherited descriptors using `fd/N` for streams and
  `fdgram/N` for datagrams.
- Podman supports passing socket-activated descriptors through
  Podman/conmon/crun to an ordinary container.

References:

- [Podman socket activation tutorial](https://github.com/containers/podman/blob/main/docs/tutorials/socket_activation.md)
- [Caddy inherited TCP/UDP descriptor example](https://github.com/caddyserver/caddy/issues/6833)
- [systemd socket units](https://www.man7.org/linux/man-pages/man5/systemd.socket.5.html)

### Important distinction

A `caddy.socket` unit in `_nas_caddy`'s user manager would still be opened by
the unprivileged user manager. It may simplify listener ownership, but it does
not let us remove the low-port sysctl.

To eliminate unprivileged low-port access, TCP/UDP 80/443 must be opened by
the system manager or redirected by a root-managed network rule.

The service does not need to become on-demand. The socket units can acquire
the ports early at boot while Caddy is still started normally and kept
running. In this project, descriptor ownership is the interesting part of
socket activation; avoiding an always-on Caddy process is not a goal.

### Decision spike A: Can activated FDs cross krun?

Before designing production units, use disposable high ports to answer:

1. Can a systemd socket pass a TCP listener through Podman and the krun
   handler into a guest process?
2. Can it do the same for UDP?
3. Does Caddy see the expected descriptor numbers and `LISTEN_FDS` metadata?
4. Are source addresses preserved?
5. Do stop, restart, and config reload retain sane descriptor ownership?

Ordinary Podman/crun support does not prove krun support. A host listening
socket is a host-kernel object, while Caddy runs behind a guest kernel. Treat
descriptor transfer across that boundary as unproven until the NAS
demonstrates it.

If direct descriptor inheritance works, the likely production shape is a
system-level socket and a deliberately hand-written system service running
Podman as `_nas_caddy`. That would be an exception to the user-Quadlet
generator. For one service on one NAS, a clear exception is preferable to
distorting the generator.

### Decision spike B: If direct inheritance does not work

Evaluate these in order:

1. **Keep Caddy on ordinary rootless crun with system socket activation.**
   This can remove the low-port sysctl while preserving HTTP/3, assuming the
   system-service/rootless-Podman handoff works.
2. **Run Caddy under krun with TSI and disable HTTP/3.**
   TCP 80/443 may work directly, but this retains the low-port sysctl unless a
   root-owned TCP forwarding layer is added.
3. **Use root-owned TCP socket proxies to high Caddy ports.**
   `systemd-socket-proxyd` handles stream sockets only, not UDP. Check source
   IP requirements and PROXY protocol support before selecting this.
4. **Use root-managed nftables redirection to high ports.**
   This is simpler than a proxy and may preserve useful network behavior, but
   it does not solve krun's lack of a guest UDP listener.
5. **Evaluate krun passt networking.**
   This enables a guest network interface and UDP, but changes the current
   host-loopback model. Prove how Caddy reaches Garage, VictoriaMetrics, and
   Grafana before considering it.

It is acceptable for the final answer to be "Caddy stays on crun." Record the
security and maintenance tradeoff, then remove unused experiments.

### Caddy completion gates

Whichever design wins must preserve:

- TCP 80/443 and, if retained, UDP 443
- Cloudflare DNS challenge credentials
- existing ACME account and certificates
- Caddy state and config trees
- client source addresses where operationally important
- all Garage, S3, VictoriaMetrics, and Grafana routes
- Caddy metrics
- reboot and reload behavior

Only remove `90-custom-coreos-rootless-ports.conf` after the selected design
has been rebooted and validated without it.

## Phase 9: Cleanup and Steady State

After the final service decision:

- remove disposable test units and containers
- remove unused passt, proxy, socket, or redirect experiments
- update `docs/roadmap.md` with the actual result
- update `AGENTS.md` runtime topology with krun services and exceptions
- add final runtime/resource fields to the generator schema documentation
- keep service-specific validation evidence in this file or split completed
  phases into checklists if they become unwieldy
- run the full unit suite, regenerate Quadlets, build the image, and confirm a
  clean worktree

Do not delete the session log. It is the evidence explaining why some services
may intentionally remain on crun.

## Session Log

Append one row per meaningful repo or NAS session. Keep entries concise and
link a dedicated checklist or commit when more detail is needed.

| Date | Phase/service | Repo change | NAS action and result | Decision / next action |
| --- | --- | --- | --- | --- |
| 2026-07-28 | Planning | Added phased libkrun plan | No NAS change | Start with Phase 0 baseline |
| 2026-07-28 | Phase 0 cold handoff | Established operator-only NAS execution; reduced the initial check after review | Agent authentication reached a trusted host key but stopped at the TPM2/PKCS#11 PIN; no remote command ran | Operator checks `krun --version` and `/dev/kvm` |
| 2026-07-28 | Phase 0A | Recorded the minimal capability result | Operator confirmed `/dev/kvm` exists and `krun` is absent | Proceed to package-only Phase 1A |
| 2026-07-28 | Planning refinement | Added Single-NAS Working Style and made common evidence an optional menu | No NAS action | Use progressive evidence and short operator commands |
| 2026-07-28 | Phase 1A | Added `crun-krun`; local image build and runtime inspection passed; committed and pushed to `main` | Assume the scheduled build and NAS update deploy it | Operator runs `krun --version` |

## Session Note Template

Copy this section when a session needs more detail than the table can hold.

```markdown
### YYYY-MM-DD — Phase N / service

Scope:

Repo starting state:

NAS starting state:

Changes made:

Commands/checks run:

Results:

What went well:

What failed or surprised us:

Production state when the session ended:

Rollback state:

Exact next action:
```
