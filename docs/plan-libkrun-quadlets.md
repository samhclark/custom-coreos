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
| Overall status | All active rootless services use libkrun; Caddy and Jellyfin are configured to replace TSI with private nested passt after a production streaming stall exposed TSI head-of-line blocking |
| Last completed work | 2026-08-06: proved concurrent private passt guests, repeated host-loopback backend mappings, and slow-client isolation; implemented typed generator support and Caddy/Jellyfin Quadlets; all 64 tests and the full image build passed |
| Current phase | Passt implementation and local validation complete; production deployment validation pending |
| Next concrete action | Deploy normally and validate Caddy/Jellyfin listeners, routes, HTTP/3, playback seeking, and monitoring |
| Production libkrun services | blackbox-exporter; vmalert; Alertmanager; Grafana; VictoriaMetrics; Garage; Caddy; Jellyfin; Jellyfin exporter |
| Known production exceptions | The krun handler lacks `podman exec`; Jellyfin's image healthcheck is disabled in favor of blackbox probing, and service configuration changes use restarts |
| Last NAS validation | 2026-08-06: two concurrent passt guests used the same guest port in distinct namespaces; explicit pasta `-T` reached host loopback; a 1.28-MiB stalled send queue left 20 health probes below 3 ms and the VMM main thread in `epoll` |

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

## Selected Streaming Network Design

Direct TSI was deployed and validated for Caddy on 2026-08-05 and initially for
Jellyfin. Real Swiftfin seeking then exposed a synchronous-send failure mode:
a client that stopped reading blocked Caddy's VMM main thread, stopped Caddy
from draining Jellyfin, and then blocked Jellyfin's VMM main thread. Health and
session APIs stalled even though host CPU, memory, ZFS, and the services
themselves were otherwise healthy.

The implementation contract is:

- run Caddy through the existing rootless user-Quadlet path with runtime
  `krun`, 2 vCPUs, 512 MiB RAM, and SIGINT shutdown
- give Caddy and Jellyfin separate private rootless pasta namespaces and set
  `krun.use_passt=1`, so crun's broad inner passt listeners cannot collide on
  the host or with another service
- publish only Caddy TCP 80/443, UDP 443, loopback TCP 2019, and Jellyfin
  loopback TCP 8096 through the outer pasta processes
- use Caddy's outer pasta `-T` mappings as an explicit allowlist for
  host-loopback backends 3000, 3900, 3903, 8096, and 8428; Caddy reaches them
  through the inner guest gateway `10.0.0.1`
- restore HTTP/3 through the published UDP 443 listener
- retain `net.ipv4.ip_unprivileged_port_start=80`; inherited root-owned
  sockets do not cross the current krun guest boundary
- use service restarts for image-controlled configuration changes and do not
  rely on `podman exec`, which the current krun handler does not support
- preserve the existing Cloudflare secret, ACME/certificate state, config
  state, metrics, and all reverse-proxy routes; evaluate client source
  addresses when a configuration actually depends on them

Rootless crun with root-owned TCP/UDP system sockets remains the documented
fallback if a later regression blocks krun. The earlier passt rejection came
from a host-network experiment: `-t all -u all` then occupied the shared host
namespace. With the normal private outer pasta namespace, the same broad
listeners are confined per container. Outer publication and reverse mappings
remain narrow and explicit.

## Settled Working Assumptions

These are starting assumptions, not substitutes for NAS evidence.

- libkrun is a per-service isolation dial. Mixed crun and krun services are a
  valid permanent state.
- Fedora provides the required `crun-krun`, `libkrun`, and `libkrunfw`
  packages. `crun-krun` supplies the `krun` entry point and dependency chain.
- The intended first networking mode is libkrun's default Transparent Socket
  Impersonation (TSI), not passt. TSI best matches the current design in which
  services communicate through host `127.0.0.1`.
- TSI supports outgoing TCP and UDP sockets and incoming TCP streams. It does
  not support a guest listening on a UDP socket. This matters for Caddy's
  HTTP/3 listener. A host-loopback DNS stub such as `127.0.0.53` is still not
  reachable as host loopback from inside the guest; use a non-loopback resolver.
- Bind mounts are presented through virtiofs. The host still owns ZFS; the
  guest does not need ZFS kernel support.
- The VMM runs in the rootless service's host security context. libkrun adds a
  guest-kernel boundary, but it does not make bind-mounted data inaccessible
  to a compromised service that was already allowed to mount that data.
- Each krun service must have explicit resources. The upstream defaults are
  too broad for seven always-on services: 1024 MiB when no memory limit is
  supplied, and the process's available CPUs up to libkrun's limit.
- krun services must initially declare `StopSignal=SIGINT`. On the NAS,
  default SIGTERM timed out and required SIGKILL, while configured SIGINT
  stopped the disposable blackbox-exporter guest immediately.
- The krun handler does not support `podman exec`. Production runtime proof
  therefore combines `podman inspect` with the Phase 0B guest-kernel result
  from the same packaged runtime stack rather than changing service startup
  commands solely to rerun `uname`.
- This NAS runs one Alertmanager, so its default HA gossip listener is disabled
  with `--cluster.listen-address=`. Alertmanager clustering requires both TCP
  and UDP, while default TSI cannot host the UDP listener; the unused listener
  had also caused a failed first startup when no advertise address was found.

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
- Put operator commands that are long, multi-line, or likely to wrap in
  `docs/libkrun-operator-command.txt`. Keep that file focused on the current
  handoff, and have the operator copy from local `cat` output instead of from
  chat formatting.
- When journal timestamps and metadata do not answer the current question, use
  `journalctl --output=cat` to avoid clutter. Keep the default or an explicit
  timestamped output mode when event timing matters, such as stop/start tests.
- Do not package one-off diagnostic scripts into the image merely to work
  around chat copy/paste formatting. That creates a fragile
  commit/build/deploy/test loop for commands that can run directly on the NAS.
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
StopSignal=SIGINT
```

Requirements:

- `enabled` must be Boolean
- CPU and RAM values must be positive integers
- reject `[krun]` fields when `enabled = false`
- enforce at least 128 MiB because lower values are ignored upstream
- render `StopSignal=SIGINT` whenever krun is enabled
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
- inspection reports the krun runtime; Phase 0B's guest-kernel proof remains
  applicable because the handler does not support live `podman exec`
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
- stderr logging still arrives in the user journal through Podman/systemd;
  native journald socket logging is intentionally disabled because the host
  socket is not usable across the krun guest boundary
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
- The custom Caddy image is patched for inherited stream and datagram file
  descriptors and includes `certmagic@v0.25.3`. Treat application support as
  settled; do not use older Caddy socket-activation bug reports to reopen it.
- HTTP/3 is optional for this single home NAS. Disabling it is acceptable if
  direct TCP 80/443 over TSI makes krun materially simpler and remains reliable.
- Default libkrun TSI cannot support a guest UDP listener, so HTTP/3 is not
  directly compatible with the simplest krun conversion.
- In the installed crun 1.28 implementation, `krun.use_passt=1` starts passt
  with `-t all -u all --no-dhcp-dns --fd ...`; it does not pass
  `--no-map-gw`. Passt was evaluated as a broad networking change rather than
  a targeted UDP-443 toggle and rejected for the current stack because its
  all-port mapping reserves unrelated free host ports.
- Caddy can consume inherited descriptors using `fd/N` for streams and
  `fdgram/N` for datagrams.
- Podman supports passing socket-activated descriptors through
  Podman/conmon/crun to an ordinary container.

References:

- [Podman socket activation tutorial](https://github.com/containers/podman/blob/main/docs/tutorials/socket_activation.md)
- [Red Hat: socket activation with Podman](https://www.redhat.com/en/blog/socket-activation-podman)
- [Rootless Quadlet Caddy TCP/UDP example](https://github.com/eriksjolund/podman-caddy-socket-activation/blob/main/examples/example4/README.md)
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

Result: inherited host descriptors do not cross krun. On 2026-08-04, the disposable krun test generated and triggered
correctly and Caddy loaded its configuration, but every start found `fd/3`
absent with `fcntl: bad file descriptor`. The otherwise identical ordinary-
crun control served the expected response through `fd/3` and remained active.
This proves the failure is at the krun guest boundary, not in Caddy, Quadlet,
systemd socket activation, or Podman's ordinary OCI-runtime FD forwarding.
The follow-up initial-process probe made the boundary explicit: Podman invoked
krun with `--preserve-fds 1`, and the guest retained `LISTEN_FDS=1` plus the
socket-unit name, but its PID was 417 while `LISTEN_PID` remained 1 and its
descriptor table contained no fd 3. The identical crun process was PID 1 and
received the socket as fd 3. Thus the metadata crosses but the host-kernel
socket does not in the currently packaged stack.
This result rules out socket inheritance under krun; it does not rule out Caddy
using guest-created listeners through TSI or passt. There is no reason to
repeat the inherited-descriptor mechanism with UDP under krun.

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

### Evidence-based Caddy comparison

| Design | Proven behavior | Main cost | Status |
| --- | --- | --- | --- |
| krun with direct TSI TCP | HTTP/2, loopback bind, host-loopback reverse proxy, TLS state reuse, clean restart, DNS, and Let's Encrypt HTTPS egress | A stalled downstream stream can block the synchronous VMM send path; no guest UDP listener | Retired for streaming services after the 2026-08-06 production stall |
| Rootless crun with root-owned system sockets | Inherited TCP and UDP, HTTP/2, QUIC with `h3`, rootless Podman, and system-owned listeners | Caddy is the production runtime exception and needs a hand-written system service rather than the user-Quadlet path | Valid fallback, not selected |
| krun with passt inside private outer pasta | Concurrent guests on the same guest port, narrow host publication, explicit loopback backend `-T` mappings, HTTP/2/QUIC, and independent health under 1.28-MiB backpressure | Two network layers; Caddy backend addresses use the stable inner gateway and must remain explicitly allowlisted | **Selected and implemented; production validation pending** |
| krun with direct TSI TCP plus root nftables redirect | Components are individually plausible but the combined path has not been tested | Disables HTTP/3 and adds root-managed redirect policy, but could remove the unprivileged-port sysctl while retaining krun | Not selected; revisit only with new requirements |

The former production design—rootless crun with direct host-network binds—
remains the lowest-change fallback, but it retains both the low-port sysctl
and the absence of a microVM boundary.

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

The current Caddyfile has no source-IP matchers, trusted-proxy policy, rate
limits, or access-log contract, so client source addresses are not an
operational dependency in this deployment. A future source-IP-dependent policy
must validate TSI behavior before relying on it.

Retain `90-custom-coreos-rootless-ports.conf` for the selected direct-low-port
design. Remove it only after selecting and validating a different listener or
redirect design that does not require unprivileged TCP 80/443.

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

Completion result (2026-08-05): every disposable Phase 8 unit/container was
removed during its experiment and no passt, proxy, socket, or redirect
experiment entered the repository. `AGENTS.md`, `docs/roadmap.md`, and the
generator schema now describe the validated steady state and Caddy exceptions.
Quadlet regeneration, all 38 unit tests, ShellCheck for the operator handoff,
and `git diff --check` pass. The implementation image build passed before
deployment, and the bootc deployment plus NAS evidence validated production.

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
| 2026-07-29 | Phase 1A validation | Recorded deployed runtime validation | `krun --version` reported crun 1.28 with `+LIBKRUN` | List `_nas_blackbox`'s pulled images, then construct Phase 0B smoke test |
| 2026-07-29 | Phase 0B preparation | Selected the existing pinned blackbox-exporter image for the smoke test | `_nas_blackbox`'s store contains the production image at the expected digest | Run the reviewed disposable smoke test |
| 2026-07-29 | Phase 0B runtime check | Recorded first disposable krun result | `_nas_blackbox` launched the pinned image with krun; guest `6.12.91` differs from host `7.1.3-200.fc44.x86_64` | Test the read-only bind mount |
| 2026-07-29 | Phase 0B workflow refinement | Added one image-managed command; Bash, ShellCheck, image inspection, and `make build` passed | Manual multi-line commands proved awkward over SSH; no NAS change from this repo work yet | Commit and push `krun-smoke-test`; after scheduled deployment, operator runs that single command |
| 2026-07-29 | Phase 0B helper correction | Changed the helper to use a traversable working directory and resolve the untagged stored image ID by its pinned digest; added a plain operator-command handoff file; Bash, ShellCheck, image inspection, and `make build` passed | First deployed run inherited `/var/home/core` and could not resolve the repository-by-digest image name; no container started | Commit and redeploy, then copy the command from local `cat` output and rerun |
| 2026-07-29 | Phase 0B workflow correction | Abandoned the image-managed diagnostic helper; replaced its handoff with the next direct operator command block | No new NAS action; the deployed helper failure demonstrated that iterating diagnostics through image deployments is too fragile | Copy commands from local `cat` output; test one question at a time without deploying diagnostics |
| 2026-07-29 | Phase 0B bind mount | Updated the direct-command handoff for the next check | Disposable krun container reported `bind-mount=readable` for the image-controlled blackbox config | Test incoming TSI TCP on unused loopback port 19115 |
| 2026-07-29 | Phase 0B incoming TCP | Updated the direct-command handoff to investigate shutdown behavior | Host reported `incoming-tcp=reachable`; SIGTERM timed out after 10 seconds and Podman used SIGKILL | Test `StopSignal=SIGINT`, which libkrun 1.19 forwards through the guest console |
| 2026-07-29 | Phase 0B clean stop | Added `StopSignal=SIGINT` to the planned generator behavior and prepared the outgoing-TCP check | Disposable guest reported `listener=reachable` and `clean-stop-seconds=0` with SIGINT | Test outgoing TSI TCP to host loopback |
| 2026-07-29 | Phase 0B outgoing TCP | Prepared the final read-only SELinux and cleanup checks | Disposable guest reported `outgoing-host-loopback=reachable` against blackbox-exporter on `127.0.0.1:9115` | Confirm enforcing mode, inspect recent AVCs, and verify no disposable containers remain |
| 2026-07-29 | Phase 0B completion | Closed the disposable smoke-test phase and cleared the operator-command handoff | SELinux reported `Enforcing`, `ausearch` reported no matches, and no `krun-smoke*` containers remained | Implement Phase 1B generator schema locally |
| 2026-07-29 | Phase 1B generator schema | Added strict `[krun]` validation and rendering for the krun runtime, CPU/RAM annotations, and `StopSignal=SIGINT`; removed the obsolete image-managed smoke-test helper | 32 unit tests, generated-output verification, `git diff --check`, and `make build` passed; existing service output was unchanged and no production service was enabled | Review and commit these changes, then begin the blackbox-exporter canary with a small operator-command handoff |
| 2026-07-30 | Phase 2 baseline start | Corrected the stale Phase 1B handoff and prepared the first read-only functional-baseline command | Operator confirmed the NAS runs the latest image from the latest `main` commit; baseline command not yet run | Confirm the blackbox metrics endpoint, direct Garage probe, and stored VictoriaMetrics probe result are healthy |
| 2026-07-30 | Phase 2 functional baseline | Recorded the successful ordinary-crun functional baseline and prepared the resource/log check | Blackbox metrics were reachable, the direct Garage probe returned `1`, and VictoriaMetrics stored `probe_success=1` at 07:54:48 CDT | Capture ordinary-crun runtime identity, cgroup resource counters, and recent logs |
| 2026-07-30 | Phase 2 implementation | Enabled krun only for blackbox-exporter with 1 vCPU, 128 MiB, and the generator-provided SIGINT stop signal; 32 tests, generation, diff checks, and `make build` passed | Ordinary-crun baseline was active/running at about 65.5 MiB current and 75.7 MiB peak; recent startup was healthy and the prior host-shutdown application stop was graceful | Review and commit; validate runtime, guest kernel, loopback listener, probes, restart, reboot, and memory after deployment |
| 2026-07-30 | Phase 2 deployment | No new implementation; prepared the first deployed-runtime proof | Operator pushed the two Phase 2 commits and confirmed the resulting image is deployed | Prove the container is running under krun and its guest kernel differs from the host |
| 2026-07-30 | Phase 2 runtime proof | Recorded live `podman exec` as unsupported and retained Phase 0B's guest-kernel result as the kernel proof for this packaged stack | Host kernel was `7.1.3-200.fc44.x86_64`; production inspection reported `runtime=krun`, `status=running`; the handler rejected `exec` | Validate the loopback listener, direct Garage probe, and VictoriaMetrics probe result |
| 2026-07-30 | Phase 2 networking validation | Recorded successful production listener and monitoring evidence; prepared the manual-restart gate | The krun VMM owned only `127.0.0.1:9115`; metrics and direct Garage probe succeeded; VictoriaMetrics stored `probe_success=1` at 08:31:38 CDT | Restart once; confirm clean SIGINT shutdown, krun recovery, health, and current memory |
| 2026-07-30 | Phase 2 manual restart | Added concise-journal guidance and moved the canary into observation | Restart completed in about 0.36 seconds; krun returned active/running, metrics and Garage probe passed, and no timeout or SIGKILL occurred. The workload logged SIGTERM despite the host-side SIGINT stop configuration. Immediate memory was about 83 MiB current and 84 MiB peak; the prior krun invocation reported a 178.5 MiB peak. | Let it run for one normal evening or day, then check health, stored probe freshness, memory, and warning logs |
| 2026-08-01 | Phase 2 observation | Recorded stable runtime/resource use and prepared a focused failure-attribution check | krun was active/running at about 163 MiB current/164 MiB peak; current metrics, direct Garage probe, and a fresh stored probe passed. Blackbox logged repeated five-second Garage health timeouts from 00:57-03:09 UTC and one canceled probe at 18:53 UTC. | Compare historical failures across the krun cutover and inspect Garage's own journal during the main failure window before closing Phase 2 |
| 2026-08-01 | Phase 2 completion | Closed the blackbox canary and prepared the vmalert ordinary-crun baseline | VictoriaMetrics recorded 2 failed Garage probes on July 30 and 70 on August 1; Garage's own unit emitted many broken-pipe and disconnected-flow messages while an overnight laptop backup generated unusually heavy traffic. Blackbox itself remained healthy and correctly exposed the target failures. | Capture vmalert rule state, evaluation progress, connectivity, resources, and warnings before enabling krun |
| 2026-08-01 | Phase 3 implementation | Enabled krun for vmalert with 1 vCPU, 256 MiB, and the generator-provided SIGINT stop signal; generation, 32 tests, generated-output verification, diff checks, and `make build` passed | Ordinary-crun vmalert was active/running at about 32 MiB current/41 MiB peak; VictoriaMetrics and Alertmanager were healthy, all three groups and nine rules evaluated with healthy state and no errors, and VictoriaMetrics stored `up=1`. The journal showed a graceful host-shutdown stop and normal restart. | Review and commit; after scheduled deployment, prove krun runtime, rule evaluation, dependency communication, scrape health, and resources |
| 2026-08-01 | Phase 3 deployment | Recorded successful deployed runtime and functional checks; prepared a focused notifier proof | vmalert reported `runtime=krun`, active/running at about 90 MiB current/91 MiB peak. All three groups and nine rules resumed healthy evaluation, both dependencies answered, VictoriaMetrics stored `up=1`, and the cutover stopped ordinary crun gracefully. The guest omitted optional PSI metrics because its cgroup view lacks `cpu.pressure`; this does not affect rule evaluation. | Confirm evaluation timestamps advance and vmalert's own counters show notifier traffic without send errors, then close Phase 3 |
| 2026-08-01 | Phase 3 completion | Closed the vmalert conversion and prepared the Alertmanager baseline | Deployed krun vmalert was healthy: post-start evaluations advanced for all groups with no rule or connection errors, VictoriaMetrics and Alertmanager answered on host loopback, and VictoriaMetrics stored `up=1`. TSI outbound loopback was already proven by Phase 2; no synthetic alert was added solely to exercise an inactive notifier. | Capture Alertmanager silences, persistent data, runtime-secret presence, resources, and health under ordinary crun |
| 2026-08-01 | Phase 4 implementation | Enabled krun for Alertmanager with 1 vCPU and 256 MiB and disabled its unused single-node HA listener; generation, 32 tests, generated-output verification, diff checks, and `make build` passed | Ordinary-crun Alertmanager was active/running at about 55 MiB current/56 MiB peak; health and metrics passed, no silences were listed, `nflog` and `silences` persisted with UID/GID 51240, both 0400 runtime secrets were readable, and prior stops were graceful. Its default gossip startup had failed once before retrying on `10.0.0.2:9094`; HA requires UDP that TSI cannot host. | Review and commit; after scheduled deployment, prove krun runtime, absent gossip listener, health, preserved state, and clean logs before sending the synthetic alert |
| 2026-08-01 | Phase 4 deployed read-only validation | Recorded successful krun runtime, health, state, and listener checks; prepared the separate real-notification action | Alertmanager reported `runtime=krun`, active/running at about 131 MiB current/132 MiB peak; health, readiness, and metrics passed; `nflog` and `silences` remained intact; port 9094 was absent; the new startup had no gossip messages; and no relevant AVCs were returned. | Start the existing five-minute synthetic alert and confirm its real Pushover notification |
| 2026-08-01 | Phase 4 synthetic-alert helper fix | Replaced the obsolete in-container `amtool` invocation with a host-side POST to Alertmanager's loopback API; ShellCheck, Bash parsing, 32 tests, generated-output verification, diff checks, and `make build` passed | The prior test exited before submission because the krun handler rejects `podman exec`; no alert was submitted and no notification was expected | Commit and deploy, then rerun the same five-minute synthetic alert |
| 2026-08-02 | Phase 4 notification failure | Recorded that the corrected helper is deployed and prepared a focused Alertmanager log check | Alertmanager accepted four submissions of the same `ManualNotificationTest` alert, but no Pushover notification arrived after the first alert expired; repeated identical labels refreshed one alert rather than creating independent notifications | Inspect Alertmanager's own logs around 17:08-17:19 UTC for scheduling or Pushover delivery errors |
| 2026-08-02 | Phase 4 DNS diagnosis | Recorded the notification failure's root cause and prepared a non-stub resolver check | Alertmanager attempted notification delivery at least 13 times, but every attempt failed before contacting Pushover because guest DNS pointed to the host's loopback-only `127.0.0.53` systemd-resolved stub | Identify the host's real upstream resolver, then test it from a disposable TSI guest before changing the production Quadlet |
| 2026-08-02 | Phase 4 resolver selection | Recorded the NAS's non-stub resolver set and prepared a disposable TSI DNS test using Alertmanager's existing image | The host uses Tailscale MagicDNS (`100.100.100.100` and its IPv6 address), followed by Comcast IPv4/IPv6 resolvers, with the tailnet search domain | Test `100.100.100.100` from a disposable krun guest without pulling an image or changing Alertmanager |
| 2026-08-02 | Phase 4 DNS implementation | Added validated `[container].dns` generation, rejected loopback resolvers specifically for host-network krun guests, and configured Alertmanager with MagicDNS plus two IPv4 fallbacks | The disposable guest resolved `api.pushover.net` through MagicDNS; 36 tests, regeneration, diff checks, and `make build` passed locally; production is unchanged | Review and commit; after scheduled deployment, submit one synthetic alert and confirm Pushover delivery |
| 2026-08-02 | Phase 4 completion | Closed the Alertmanager conversion and moved the handoff to Grafana | The explicit non-loopback DNS configuration was deployed; Alertmanager submitted the synthetic alert through Pushover and the operator received the notification | Capture the ordinary-crun Grafana functional and persistent-state baseline |
| 2026-08-02 | Phase 5 baseline start | Recorded Grafana health, persistent database metadata, and installed plugin versions; prepared the resource/listener check | Grafana 13.1.1 reported database `ok`; its 2,203,648-byte SQLite file remained owned by 51210:51210; six plugins included VictoriaMetrics datasource 0.25.2 | Confirm ordinary crun, loopback-only port 3000, and current/peak host memory |
| 2026-08-02 | Phase 5 runtime baseline | Recorded runtime, listener, cgroup resources, and startup time; deferred resource selection pending a memory breakdown | Grafana was active/running under crun on only `127.0.0.1:3000`; its cgroup reported about 871 MiB current/878 MiB peak and 11.45 CPU-seconds since its 17:39 UTC start | Determine whether the high memory charge is application RSS or reclaimable file cache before choosing krun RAM |
| 2026-08-02 | Phase 5 resource selection | Chose 2 GiB rather than the initial 512 MiB starting point and recorded the overcommit rationale | The cgroup showed about 687 MiB anonymous memory and 6.2 GB file cache; Podman reported 506.7 MB container use on a 32 GB host. One GiB left little room for guest/kernel overhead, while file cache did not justify sizing above 2 GiB. | Enable Grafana alone with 2 vCPUs, 2 GiB, and explicit non-loopback DNS |
| 2026-08-02 | Phase 5 implementation | Enabled krun for Grafana with 2 vCPUs and 2 GiB; added the validated DNS set for synchronous plugin installation | Generation, 36 tests, generated-output isolation, diff checks, and `make build` passed; only expected bootc cache warnings appeared; production remains on ordinary crun | Confirm the dashboard visual baseline, then review and commit for scheduled deployment |
| 2026-08-02 | Phase 5 deployment and visual validation | Recorded the successful dashboard comparison and initial deployed runtime evidence; prepared the remaining read-only checks | Every provisioned dashboard was reviewed over Last 24 hours before and after deployment and all panels looked the same. Grafana was active/running under `[libcrun:krun]`; its service cgroup reported 1.6 GiB current and peak memory after seven minutes. | Verify health, plugin persistence, database metadata, loopback-only listener, and Podman runtime; then restart separately |
| 2026-08-02 | Phase 5 deployed read-only validation | Recorded successful health, persistence, listener, and runtime checks; prepared the separate restart action | Grafana 13.1.1 reported database `ok`; the database remained 2,203,648 bytes with host ownership 51210:51210; the VictoriaMetrics plugin remained present; only `127.0.0.1:3000` listened; and Podman reported `runtime=krun status=running`. | Restart Grafana once, verify clean shutdown and recovery, and confirm dashboards still load |
| 2026-08-02 | Phase 5 restart recovery | Recorded successful restart and functional recovery; corrected the failed journal diagnostic | Grafana restarted in one second, returned database `ok` under krun, and retained its database and plugin metadata. Only `journalctl --machine` failed because it tried an unsupported non-root machine connection; that did not affect Grafana. | Read the service journal through the service account and confirm one dashboard still loads |
| 2026-08-02 | Phase 5 restart journal | Recorded clean shutdown and startup evidence; classified repeated startup messages as non-blocking configuration debt rather than krun failures | Grafana received `System signal: interrupt`, stopped without timeout or SIGKILL, and listened on `127.0.0.1:3000` about four seconds later. The missing optional provisioning directories, deprecated anonymous Admin setting, executable database mode, and other warnings appeared on both krun starts; the shutdown-only `context canceled` followed the intentional stop. | Confirm one dashboard loads after the restart, then close Phase 5 |
| 2026-08-02 | Phase 5 completion | Closed the Grafana conversion and moved the handoff to VictoriaMetrics | After the validated restart, the provisioned dashboards continued to load normally and their panels still matched the pre-cutover Last 24 hours view. Health, krun runtime, loopback networking, SQLite state, plugin persistence, graceful shutdown, and recovery all passed. | Begin Phase 6 later by capturing the ordinary-crun VictoriaMetrics functional and resource baseline |
| 2026-08-02 | Phase 6 baseline preparation | Started the VictoriaMetrics phase with a focused read-only functional handoff | No NAS state changed; VictoriaMetrics remains on ordinary crun | Confirm ordinary crun, service health, all eight active targets, and fresh samples before collecting storage and resource evidence |
| 2026-08-02 | Phase 6 functional baseline | Recorded the successful ordinary-crun runtime, health, target, and sample-freshness baseline | VictoriaMetrics reported `runtime=crun status=running` and healthy; all eight configured jobs were up, with newest `up` samples between about 0.5 and 25 seconds old | Capture cgroup memory breakdown, Podman usage, dataset space, mount source, and ownership before selecting krun resources |
| 2026-08-02 | Phase 6 resource and storage baseline | Recorded ordinary-crun memory and persistent-dataset evidence; deferred sizing until compaction evidence is available | The service cgroup used about 195 MiB current and 235 MiB peak memory, including about 168 MiB anonymous and 24 MiB file memory; Podman reported about 203 MB. The 276 MiB ZFS dataset had the expected mount source, 51250:51250 ownership, mode 0750, and `container_file_t:s0` label. | Capture ingestion and merge/compaction counters before choosing the krun memory limit |
| 2026-08-02 | Phase 6 internal metrics baseline | Recorded ingestion, storage-state, pending-work, and resident-memory counters; narrowed the missing compaction evidence | Promscrape had inserted 4,094,170 rows with no ignored rows; storage was writable with about 6 TB free and 1,102 pending rows; resident memory was about 199 MB. `vm_slow_row_inserts_total` was 1,744, but this lifetime counter needs a rate. The anticipated `vm_merge_*` metrics were not exported under those names. | Discover the exported merge/compaction metric names, then query concise recent rates |
| 2026-08-02 | Phase 6 compaction metric discovery | Recorded the exact merge metric names exported by VictoriaMetrics 1.148.0 | The live endpoint exposed `vm_active_merges`, `vm_merges_total`, `vm_rows_merged_total`, and related force-merge, assisted-merge, part, and timestamp-block metrics | Query recent ingestion, slow-insert, pending-row, and merge activity over concise windows |
| 2026-08-02 | Phase 6 ingestion and compaction baseline | Recorded a period containing sustained real merge work with low concurrency and backlog; retained the planned resource starting point pending the final query baseline | Ingestion averaged about 682 rows/second over 15 minutes. Over 24 hours, the small-storage path performed about 11,087 merges covering 245 million rows; the last hour peaked at one active merge and 575 pending storage rows. The 24-hour slow-insert increase spans counter resets and needs a current rate for context. | Measure a representative 24-hour query's continuity and latency plus the current slow-insert rate; then select 2 vCPUs and 1 GiB if healthy |
| 2026-08-02 | Phase 6 slow-insert rate and query-helper correction | Recorded the healthy current slow-insert rate and replaced an unavailable timing binary | Slow inserts averaged about 0.021 rows/second versus roughly 682 ingested rows/second. The historical query did not run because `/usr/bin/time` is absent on the NAS; no service state changed. | Rerun only the historical query using Bash's built-in `time` |
| 2026-08-02 | Phase 6 baseline completion and resource selection | Completed the ordinary-crun baseline and selected the planned 2 vCPU / 1 GiB starting point | A representative 24-hour node query returned 1,439 samples spanning the full period in 18 ms. Combined with about 235 MiB peak memory and sustained compaction with low concurrency and backlog, this leaves comfortable guest headroom at 1 GiB. | Enable krun for VictoriaMetrics alone and complete local validation before taking the production snapshot |
| 2026-08-02 | Phase 6 implementation | Enabled krun for VictoriaMetrics alone with 2 vCPUs, 1 GiB RAM, and the generator-provided SIGINT stop signal | Generation, all 36 tests, generated-output isolation, diff checks, and `make build` passed; only expected bootc cache warnings appeared. Production remains on ordinary crun. | Briefly stop VictoriaMetrics, take the pre-krun ZFS snapshot, restart ordinary crun, and verify health before deployment |
| 2026-08-02 | Phase 6 pre-krun snapshot | Recorded the reported snapshot creation and successful ordinary-crun recovery; corrected the final verification command | The stop and snapshot succeeded, creating `tank/victoria-metrics/data@pre-krun-20260802-220254`; VictoriaMetrics restarted healthy. Only the final `zfs list` failed because this host does not accept the supplied long options. | Verify the exact snapshot using portable short ZFS options |
| 2026-08-02 | Phase 6 snapshot verification | Closed the pre-deployment gates and prepared the implementation commit | The exact pre-krun snapshot was present with 1.32 MiB referenced snapshot space and a 22:02 UTC creation time; ordinary-crun VictoriaMetrics remained healthy | Commit locally; push when ready for scheduled deployment, then run the Phase 6 production checklist |
| 2026-08-02 | Phase 6 deployment | Recorded that the pushed image booted and prepared the first production-runtime gate | The operator reports the new image booted; no post-deployment VictoriaMetrics evidence has been collected yet | Prove `runtime=krun`, running state, application health, and loopback-only port 8428 |
| 2026-08-02 | Phase 6 deployed runtime proof | Recorded successful krun runtime, service, health, and listener evidence | Podman reported `runtime=krun status=running`; the user service was active/running, VictoriaMetrics was healthy, and the krun VMM listened only on `127.0.0.1:8428` | Verify historical samples span the deployment reboot and all eight jobs continue producing fresh samples |
| 2026-08-02 | Phase 6 continuity and ingestion proof | Recorded cross-reboot TSDB continuity and successful fresh ingestion from every configured job | The node series had samples on both sides of the deployment reboot. All eight jobs were up, with newest samples between about 4.5 and 35 seconds old. | Verify the unchanged ZFS mount, ownership, SELinux label, runtime secret, and initial krun resource use |
| 2026-08-02 | Phase 6 storage and resource proof | Recorded successful virtiofs-facing storage and secret contracts plus initial krun resource use | The service used about 182 MiB current/peak cgroup memory and Podman reported about 163 MB. The ZFS mount source, 51250:51250 ownership, mode 0750, `container_file_t:s0` label, and Garage metrics token readability were unchanged. | Confirm vmalert rule evaluation and one Grafana dashboard query still work |
| 2026-08-02 | Phase 6 vmalert dependency proof | Recorded successful post-deployment evaluation against krun-VictoriaMetrics | vmalert's metrics endpoint was reachable; all three groups and nine rules had fresh evaluation timestamps, `health=ok`, inactive state, and no last error | Confirm one provisioned Grafana dashboard displays current data, then begin compaction observation |
| 2026-08-02 | Phase 6 Grafana dependency proof | Completed the downstream-consumer gate and prepared the krun compaction observation | Grafana's provisioned vmalert dashboard displayed current post-deployment data; together with the vmalert rule evidence, both consumers continued querying VictoriaMetrics successfully | Measure recent ingestion, pending work, and real merge activity under krun |
| 2026-08-02 | Phase 6 krun compaction observation | Recorded a post-deployment period containing successful real compaction without backlog or read-only pressure; retained a slow-insert-rate observation | VictoriaMetrics ingested about 609 rows/second while the small-storage path completed 204 merges covering about 3.55 million rows in 30 minutes. Peak active merges was one, pending storage rows peaked at 200, and storage stayed writable. Slow inserts were about 1.13 rows/second, roughly 0.19% of ingestion and higher than the pre-deployment point sample. | Repeat the identical 24-hour query latency test, then inspect focused storage and I/O error logs |
| 2026-08-02 | Phase 6 query-latency comparison | Recorded a healthy current krun query-path result without misclassifying the data window as a krun soak | The deployed krun service returned 1,439 node samples spanning data written under both crun and krun in 18 ms. This matches the pre-deployment query wall time but does not represent 24 hours of krun-written data. | Inspect narrowly filtered storage, permission, locking, corruption, merge, and I/O failure logs; then perform the final restart test |
| 2026-08-02 | Phase 6 focused journal check | Recorded a clean storage and I/O error scan and prepared the final restart action | No storage, permission, locking, corruption, merge, or I/O failure matched in the deployed service journal | Restart once; verify graceful shutdown, krun recovery, retained recent history, and resumed ingestion |
| 2026-08-02 | Phase 6 completion | Closed the VictoriaMetrics conversion and moved the handoff to Garage | VictoriaMetrics received SIGINT, cleanly shut down its web service, and restarted healthy under krun in two seconds. It retained 236 node samples over the prior hour and resumed ingestion with the worst sample age at 55 seconds, within the one-minute cadence of slower jobs. Runtime, TSDB continuity, all eight scrapes, vmalert, Grafana, virtiofs storage contracts, secrets, compaction, resources, query performance, logs, and restart recovery passed. | Begin Phase 7 later with the ordinary-crun Garage functional, storage, resource, and performance baseline |
| 2026-08-02 | Phase 7 baseline start | Recorded Garage's ordinary-crun runtime and host listener topology | Podman reported `runtime=crun status=running`; ports 3900, 3902, and 3903 were published only on `127.0.0.1` through pasta, while private RPC port 3901 was absent from the host | Confirm direct health and authenticated metrics availability |
| 2026-08-02 | Phase 7 functional baseline | Recorded successful direct health and authenticated metrics checks | Garage reported fully operational; `/health` and authenticated `/metrics` both returned HTTP 200 without exposing the metrics token | Capture cgroup resource use and the persistent ZFS storage contracts |
| 2026-08-02 | Phase 7 resource and storage baseline | Recorded Garage's ordinary-crun memory use and verified both persistent ZFS datasets | The service cgroup used about 89 MiB current/115 MiB peak memory, including about 32 MiB anonymous and 54 MiB file memory; Podman reported 76.94 MB. The 81.4 GiB data and 306 MiB metadata datasets had the expected mount sources, 51110:51110 ownership, mode 0750, and `container_file_t:s0` labels, with 5.48 TiB available. | Capture bounded recent native journald output and relevant warnings |
| 2026-08-02 | Phase 7 journald baseline | Verified absolute-path journald delivery and reviewed a bounded recent error-oriented window | Garage logged normal SQLite opening, GC/lifecycle work, and live backup LIST/DELETE/PUT requests. Its S3, web, and admin servers exited without error during prior host shutdowns. The only warnings were Podman pause-process cgroup races while shutdown jobs were already queued; no SQLite locking, corruption, I/O, or Garage application failures appeared. | Capture request latency, error rate, block throughput, and internal queue metrics |
| 2026-08-02 | Phase 7 idle metrics point | Recorded current Garage internal queues but did not treat an inactive interval as the performance baseline | The 15-minute request rate was zero, so latency and block-I/O queries had no series. Resync length, errored blocks, and Merkle-updater queue were zero; the table-GC queue was 24. | Repeat only activity metrics over six hours to span the observed backup workload |
| 2026-08-02 | Phase 7 request-performance baseline | Recorded a six-hour S3 request window spanning the backup activity visible in the journal | Garage served 14 requests with no exported error series; aggregate request latency was 1.25 seconds p50, 5.6 seconds p95, and 6.72 seconds p99. The observed operations did not produce exported block-read or block-write byte series. | Inventory buckets, key metadata, and available S3 clients before designing the disposable object test |
| 2026-08-02 | Phase 7 object-read baseline | Identified a matching operator-laptop AWS profile and recorded a repeatable existing-object checksum without printing object contents or credentials | Garage contained bucket `sam-lemur-fedora-backup` and key metadata `sam-key`; no NAS-local S3 client was present. Laptop profile `garage-backup` matched the key ID and endpoint. Existing object `config` was 155 bytes with SHA-256 `259cdf67289b6a111d0d27ec2dbc9df1900b12ab3a3cb3828c9e84cb03e639c9`. | Run a self-cleaning small PUT/GET/checksum/DELETE test from the laptop |
| 2026-08-02 | Phase 7 object-write baseline | Completed the self-cleaning ordinary-crun S3 mutation test through Caddy | A unique 82-byte object was uploaded, read with matching SHA-256, deleted, and confirmed absent; no existing object was touched | Select explicit krun CPU and RAM resources from the completed baseline |
| 2026-08-02 | Phase 7 resource selection | Selected 2 vCPUs and 1 GiB as Garage's initial krun allocation | Ordinary crun peaked near 115 MiB, but Garage's default block RAM buffer is 256 MiB and concurrent requests add multiple block-sized buffers outside that limit. One GiB leaves room for guest overhead, SQLite, compression, and backup bursts; two vCPUs allow compression and storage work without an excessive allocation. | Enable krun for Garage alone and complete local validation |
| 2026-08-02 | Phase 7 implementation | Enabled krun for Garage alone with 2 vCPUs, 1 GiB RAM, and the generator-provided SIGINT stop signal | Generation, all 36 tests, generated-output verification, diff checks, and `make build` passed; only the documented bootc runtime and `/var` cache warnings appeared. Production remains on ordinary crun. | Stop Garage briefly, snapshot both ZFS datasets at one shared timestamp, restart ordinary crun, and verify health |
| 2026-08-02 | Phase 7 pre-krun snapshots | Closed the pre-deployment data-safety gate and prepared the implementation commit | Coordinated snapshots `tank/garage/meta@pre-krun-20260803-034602` and `tank/garage/data@pre-krun-20260803-034602` were created with 306 MiB and 81.4 GiB referenced, respectively. Ordinary-crun Garage restarted and became healthy; the first retry received an expected transient reset during startup. | Commit locally; push when ready for scheduled deployment, then run the Phase 7 production checklist |
| 2026-08-02 | Phase 7 implementation commit | Committed the Garage-only krun conversion and its complete baseline/snapshot evidence | No additional NAS state changed; production remains healthy on ordinary crun with both pre-krun snapshots retained | Push when ready for scheduled deployment, then prove krun runtime, health, and listener topology |
| 2026-08-02 | Phase 7 deployment | Recorded that the Garage krun image is deployed and prepared the first read-only production gate | The operator reports deployment complete; no post-deployment Garage runtime or functional evidence has been collected yet | Prove krun runtime, active service state, health, and host listener topology |
| 2026-08-02 | Phase 7 startup diagnosis | Recorded that the first production check ran before Garage created its container | The user service reported `activating`; `podman inspect` found no Garage object, and port 3903 was closed. This places the delay before container startup, most likely in an `ExecStartPre` readiness gate. | Inspect the user unit and host dataset-preparation contracts without restarting anything |
| 2026-08-02 | Phase 7 journald incompatibility | Identified native journald socket access, not storage preparation, as the krun startup blocker | Dataset preparation completed in seven seconds, explicitly skipped recursive ownership work, and published the readiness marker; mounts, owners, and write checks all passed. Each krun container then exited because the bind-mounted host journald socket returned `Connection refused`. | Temporarily override `GARAGE_LOG_TO_JOURNALD` to empty, restart Garage, and prove stderr journal delivery and health |
| 2026-08-02 | Phase 7 temporary journald override | Applied the host-local Quadlet drop-in and separated the prior failed attempt from the override restart | The new container reported `runtime=krun status=running` and effective `GARAGE_LOG_TO_JOURNALD=` at 04:17:17 UTC. The returned `Connection refused` belonged to the 04:17:10 attempt; the immediate post-restart health check was too early and returned HTTP 000. | Wait boundedly for health, then inspect runtime, listeners, and only post-04:17:17 journal entries |
| 2026-08-02 | Phase 7 temporary override proof | Confirmed the permanent logging design and retained an explicit host-cleanup obligation | Garage became fully operational under krun; SQLite and all workers initialized cleanly, stderr logs arrived in the user journal, and pasta published only 3900, 3902, and 3903 on `127.0.0.1`. Temporary file `/etc/containers/systemd/users/51110/garage.container.d/90-disable-native-journald.conf` remains required by the currently deployed image. | Remove native journald configuration and socket mount in the repo; after deployment, delete the drop-in before further validation |
| 2026-08-02 | Phase 7 permanent journald fix | Removed the native-journald environment and host socket mount from Garage's source TOML and regenerated its Quadlet | All 36 tests, generated-output verification, diff checks, and `make build` passed with only the documented bootc warnings. The NAS remains healthy through the temporary drop-in, which must be deleted only after this fix deploys. | Commit and deploy; remove the drop-in, reload/restart Garage, and verify no host override remains |
| 2026-08-02 | Phase 7 permanent-fix commit | Committed the locally validated Garage logging correction | No additional NAS state changed; Garage remains healthy under krun through the temporary drop-in | Push and deploy, then remove the temporary drop-in and validate the image-controlled configuration |
| 2026-08-02 | Phase 7 host-override cleanup | Removed the only temporary NAS file and validated the permanent image-controlled logging configuration | The cleanup refused to run until the deployed base Quadlet lacked both native-journald settings. It then deleted the drop-in and empty directory, restarted Garage, and confirmed health, `runtime=krun`, no journald environment/socket mount, stderr logs, and loopback-only 3900/3902/3903. Garage received SIGINT, all workers exited peacefully, and SQLite plus all servers recovered in about one second. | Verify storage, secret, authenticated metrics, and resource contracts |
| 2026-08-02 | Phase 7 storage and secret proof | Verified virtiofs-facing storage, runtime secrets, authenticated metrics, and initial krun resources | Both datasets retained exact ZFS sources, 51110:51110 ownership, mode 0750, and `container_file_t:s0`; all three 0400 runtime secrets were readable by `_nas_garage`; authenticated metrics returned HTTP 200. The service used about 151 MiB current/157 MiB peak cgroup memory and Podman reported 142.1 MB. | Verify the existing object checksum and repeat the self-cleaning object mutation test through Caddy |
| 2026-08-02 | Phase 7 object-integrity proof | Verified preserved object data and new S3 mutations through Caddy under krun | Existing object `config` remained 155 bytes with exact pre-krun SHA-256 `259cdf67289b6a111d0d27ec2dbc9df1900b12ab3a3cb3828c9e84cb03e639c9`. A unique 73-byte object passed PUT, GET with matching SHA-256, DELETE, and absence verification. | Verify Caddy health routing and fresh monitoring data in VictoriaMetrics |
| 2026-08-02 | Phase 7 monitoring proof | Verified both the user-facing route and Garage's two monitoring paths | Caddy's public Garage health route returned HTTP 200. Blackbox `probe_success` and the `garage-health` scrape `up` were 1 with samples no more than one second old; authenticated Garage `cluster_healthy` was 1 and one second old. | Capture post-krun latency, internal queues, and a concise storage/I/O error count |
| 2026-08-02 | Phase 7 performance point | Recorded fast post-krun request latency and healthy internal queues; corrected a no-match journal-count helper failure | Nine requests completed at 2.5 ms p50, 86.5 ms p95, and 97.3 ms p99. Resync length, errored blocks, and Merkle queue were zero; table-GC queue was 25 versus the idle crun point's 24. One S3 error likely represents the intentional HEAD-after-DELETE absence check. The journal-count line did not run because `journalctl --grep` returned nonzero for no matches under `pipefail`. | Inspect the error series labels and rerun the corrected journal count |
| 2026-08-02 | Phase 7 error attribution | Cleared the apparent S3 error and completed the focused journal scan | The sole error series was `HeadObject` status 404 with increase 1, exactly matching the intentional absence check after deleting the smoke object. The corrected focused journal scan returned zero corruption, SQLite, permission, or I/O matches. | Exercise real block-file reads and writes with one self-cleaning 16 MiB object |
| 2026-08-02 | Phase 7 block-file proof | Exercised Garage object-block writes and reads over virtiofs with deterministic incompressible data | A 16 MiB object uploaded, downloaded with exact SHA-256 `f64bf0297adfdfcb575975d37d2b82f5bf79b426d3a774f13558fc7f42d905b3`, deleted, and was confirmed absent. End-to-end laptop-through-Caddy wall times were 19.366 seconds upload and 8.975 seconds download, about 0.83 MiB/s and 1.78 MiB/s respectively. No pre-krun large-object baseline exists, so this is correctness proof and a post-krun timing point, not evidence by itself of improvement or regression. | Confirm block metrics, queues, resources, and focused journal state before deciding whether real-workload observation is needed |
| 2026-08-02 | Phase 7 post-block state | Recorded clean error/resource evidence and retained newly queued background work for one follow-up | No block-read timeout series, resync errors, or relevant journal matches appeared. The service used about 193 MiB current/203 MiB peak memory. Resync and table-GC queues were both 36 after writing and deleting sixteen 1 MiB blocks; the ordinary-crun idle points were 0 and 24-25 respectively. Local single-node reads/writes did not increment the exported block-byte counters. | Recheck after about 10 minutes and confirm queued work drains without errors |
| 2026-08-04 | Phase 7 completion | Closed Garage production validation after the bounded background-work follow-up | Resync and Merkle queues reached zero, table-GC queue drained from 36 to 5, resync errors remained zero, and cluster health remained 1. Together with the prior runtime, storage, secret, object-integrity, monitoring, performance, journal, and restart evidence, this completes Garage's krun gate. | Begin Phase 8 with a disposable high-port inherited-socket test |
| 2026-08-04 | Phase 8 Caddy orientation | Recorded the operator-confirmed application capability and added relevant Podman/Quadlet examples | No NAS action. The custom Caddy build supports inherited TCP/UDP descriptors and includes `certmagic@v0.25.3`; the remaining first-spike question is whether those descriptors cross krun. | Test an inherited TCP socket first on a disposable high port without changing production Caddy |
| 2026-08-04 | Phase 8 krun TCP spike | Recorded a repeatable missing-descriptor failure and corrected the operator handoff's interactive-shell behavior | The runtime-only Quadlet and matching socket generated and triggered correctly. Four krun guest starts loaded the pinned image and Caddy config, then each failed on inherited `fd/3` with `fcntl: bad file descriptor`; production Caddy was untouched. The prior handoff's top-level `exit` also closed the operator's SSH shell after failure. | Repeat the same test with ordinary crun; if it succeeds, classify inherited host descriptors as unsupported across krun |
| 2026-08-04 | Phase 8 crun TCP control | Proved the socket-activation harness and isolated the inherited-descriptor failure | The otherwise identical control returned `crun-caddy-tcp-ok`, reported `runtime=crun status=running`, and showed an active service with `Result=success`. This isolates the missing descriptor to krun rather than Caddy, Quadlet, systemd, or ordinary Podman FD forwarding. | Explore direct krun listeners before making the Caddy runtime decision |
| 2026-08-04 | Phase 8 scope correction | Reopened the Caddy runtime decision after distinguishing one failed mechanism from krun as a whole | No NAS action. The operator did not select a crun exception. Existing blackbox evidence and libkrun's model show that guest-created TCP listeners over TSI remain viable; passt may additionally provide guest UDP. HTTP/3 is optional for this home NAS, so a reliable TSI TCP design may intentionally disable it. | Test a disposable Caddy-created TCP listener under krun/TSI |
| 2026-08-04 | Phase 8 krun TSI TCP | Proved that Caddy itself runs under krun and accepts a guest-created TCP listener through TSI | The first curl raced startup and was refused, then its retry returned `krun-caddy-tsi-tcp-ok`. Podman reported `runtime=krun status=running`, systemd remained active with `Result=success`, and the listener appeared on the host. The wildcard listener came from the test Caddyfile lacking an explicit `bind`, not from a demonstrated TSI limitation. | Add an explicit loopback bind and reverse-proxy Garage health through host loopback |
| 2026-08-04 | Phase 8 inherited-FD probe refinement | Replaced the application-level retry with a paired runtime introspection test | No NAS action. The same initial shell process will print `LISTEN_PID`, `LISTEN_FDS`, `LISTEN_FDNAMES`, and every open descriptor under both krun and crun, distinguishing a dropped, renumbered, or unexpectedly preserved socket without relying on Caddy behavior. | Run the paired probe and compare the two FD tables |
| 2026-08-04 | Phase 8 inherited-FD probe attempt | Confirmed the crun control and identified a timing hole in the krun observation | The crun initial process reported PID 1, `LISTEN_FDS=1`, `LISTEN_FDNAMES=crun-fd-probe.socket`, and socket `fd=3`. The krun section was completely empty, including the unconditional PID line, so it cannot yet distinguish missing FDs from a probe that had not started before cleanup. | Rerun after a three-second wait; collect full krun status and journal only if output remains absent |
| 2026-08-04 | Phase 8 inherited-FD conclusion | Proved exactly how socket inheritance fails in the current krun stack | Podman invoked krun with `--preserve-fds 1`. The guest process ran as PID 417 and retained `LISTEN_PID=1`, `LISTEN_FDS=1`, and the socket-unit name, but its full descriptor table had no fd 3. The identical crun process ran as PID 1 with the socket at fd 3. | Treat inherited sockets as unavailable under current krun; resume guest-created TSI listener testing |
| 2026-08-04 | Phase 8 TSI proxy path | Proved explicit loopback binding plus Caddy's production-style backend direction under krun | After one expected startup-race refusal, Caddy returned Garage's real health response with HTTP 200. Podman reported krun, systemd remained healthy, and the host listener was exactly `127.0.0.1:19083`, not wildcard. | Test TLS/HTTP2 and disposable persistent Caddy state across a restart |
| 2026-08-04 | Phase 8 TSI TLS and state | Proved TLS/HTTP2, virtiofs-backed state creation and reuse, graceful restart, and initial resources | Both pre- and post-restart requests returned HTTP/2 200. Ten files were retained across the restart; the second start reused the certificate and skipped recent storage cleanup. SIGINT shut down cleanly, the listener remained `127.0.0.1:19443`, and krun used about 112 MiB current/132 MiB peak memory. | Test DNS resolution plus outbound HTTPS to the Let's Encrypt directory through TSI |
| 2026-08-04 | Phase 8 TSI egress | Proved the candidate DNS and outbound HTTPS path used by ACME | A disposable process in the pinned Caddy image under krun resolved and fetched the Let's Encrypt production directory, reporting `letsencrypt_dns_and_https=ok`. Review of crun 1.28 also found that `krun.use_passt=1` hardcodes all TCP and UDP port forwarding, so passt needs a deliberately isolated experiment rather than a casual production-like start. | Compare a root-owned high-port system socket handed to rootless Podman/crun |
| 2026-08-04 | Phase 8 system-socket TCP | Proved a root-owned listener can feed a genuinely rootless Caddy container under crun | The test returned `system-socket-rootless-crun-ok`; Podman reported `rootless=true`, crun, and running state, while the system service remained active with `Result=success` and `User=_nas_caddy`. This makes removal of the global low-port sysctl viable for TCP without making Caddy rootful. | Check for an HTTP/3-capable client, then test paired system TCP/UDP sockets |
| 2026-08-04 | Phase 8 HTTP/3 client inventory | Ruled out the installed curl as an end-to-end HTTP/3 validator | curl 8.18.0 reported HTTP2 but no HTTP3 feature or QUIC backend. This says nothing about Caddy's server capability; it only means curl cannot prove the UDP/QUIC request path. | Check whether the installed OpenSSL `s_client` exposes a QUIC client |
| 2026-08-04 | Phase 8 QUIC probe capability | Identified a transport-level QUIC validator already installed on the NAS | OpenSSL 3.5.7's `s_client` reported `-quic`. It can prove a QUIC handshake and `h3` ALPN over UDP, but it does not itself issue an HTTP/3 request. | Calibrate the probe against the current production Caddy |
| 2026-08-04 | Phase 8 QUIC probe calibration | Proved the transport-level probe against the known-good production listener | OpenSSL connected to production Caddy over QUIC using TLS 1.3 with `TLS_AES_128_GCM_SHA256` and negotiated `h3`. The missing curl HTTP/3 feature no longer prevents direct validation of the UDP/QUIC handshake path. | Test paired root-owned TCP/UDP sockets passed to rootless Podman/crun |
| 2026-08-04 | Phase 8 system-socket TCP/UDP | Proved the complete root-owned-listener path into genuinely rootless Caddy under crun | The inherited TCP socket returned the expected body with HTTP/2 200, while the inherited UDP socket completed a QUIC/TLS 1.3 handshake and negotiated `h3`. Podman reported `rootless=true`, `runtime=crun status=running`; the system service was active as `_nas_caddy`; and `ss` showed systemd, conmon, and Caddy retaining the expected TCP and UDP descriptors. The internal-CA verification warning was expected and unrelated to transport. | Remove all disposable paired-socket test state from `/run` |
| 2026-08-04 | Phase 8 paired-socket cleanup | Removed the complete disposable crun test without touching production Caddy | The system service became `LoadState=not-found`, TCP and UDP listener counts on 19444 were both zero, and the empty filtered Podman output confirmed no leftover test container. | Design the krun/passt test inside a private host network namespace |
| 2026-08-04 | Phase 8 passt prerequisite and source correction | Confirmed the required host tools and corrected the exact crun 1.28 passt invocation | `passt`, `ip`, and `nsenter` were installed; packages were passt `0^20260611.ga9c61ff-1.fc44` and crun-krun `1.28-1.fc44`. Exact crun 1.28 source passes `-t all -u all --no-dhcp-dns --fd ...`, not the previously recorded `--no-map-gw`; default gateway-to-host mapping may therefore remain available. | Run only the ingress TLS/HTTP2/QUIC probe inside an isolated host network namespace |
| 2026-08-04 | Phase 8 isolated passt ingress | Proved krun/passt TCP and UDP ingress without touching the live NAS network namespace | The private-namespace listener returned the expected body with HTTP/2 200 and completed a QUIC/TLS 1.3 handshake with `h3`. Podman reported rootless krun and running state under `_nas_caddy`. The NAS namespace had zero TCP and UDP listeners on 19445, while the service namespace showed only passt owning both listeners. The internal-CA verification warning was expected. | Inspect the guest route and client tools, then test passt gateway-to-host access |
| 2026-08-04 | Phase 8 krun exec limitation | Recorded a runtime-management limitation and replaced the failed inspection method | `podman exec` returned `the handler does not support exec`. This does not affect the already-proven ingress path, and production Caddy currently has no exec-based reload contract, but arbitrary in-guest exec cannot be part of a krun operational design. | Use an initial-process wrapper to print the evidence, then exec Caddy |
| 2026-08-04 | Phase 8 passt restart proof | Proved restart recovery but did not yet recover the wrapper evidence | The disposable service returned to active/running with `Result=success` and served HTTP/2 200 after restart. The system-journal extraction printed no route/client block, so the guest evidence remains uncollected. | Confirm the configured command and query Podman's container log directly |
| 2026-08-04 | Phase 8 passt guest inventory | Recovered the guest evidence without relying on unsupported runtime exec | Podman inspect confirmed the wrapper as the initial command. Podman's stored log showed an `eth0` default route with gateway hex `010200C0`, i.e. `192.0.2.1`, plus `/usr/bin/wget` and `/bin/busybox`. | Bind a host-loopback backend before passt, then test reverse proxy through the guest gateway |
| 2026-08-04 | Phase 8 passt backend path | Proved the production-direction network path from Caddy's guest to a host-loopback service | A backend bound to `127.0.0.1:19086` before passt started. It returned HTTP 200 directly in the shared private namespace and through Caddy reverse-proxying to `192.0.2.1:19086`. Both services stayed active/successful and Podman reported krun running. | Measure whether `-t all` reserves the real backend port numbers when initially free |
| 2026-08-04 | Phase 8 passt port reservation | Confirmed the hard-coded all-port mapping creates a real startup-order hazard | In the isolated namespace, passt eagerly owned every tested free TCP port: Caddy admin 2019, Grafana 3000, Garage 3900/3903, and VictoriaMetrics 8428. This explains why the gateway test required the backend to bind first. Robust production ordering would have to cross several independent rootless user managers, conflicting with this repo's established avoidance of cross-manager ordering. UDP 443 was not bound in the private namespace, plausibly because that namespace did not inherit the host's lowered unprivileged-port floor; high-port UDP/QUIC had already passed. | Remove all disposable passt state, then compare the three validated Caddy designs |
| 2026-08-04 | Phase 8 passt cleanup | Removed the complete isolated passt experiment without touching production | Both disposable system units reported `LoadState=not-found`, NAS TCP and UDP listener counts on 19445 were zero, and the empty filtered Podman output confirmed no leftover container. | Choose between the two serious finalists, or request the optional krun/TSI plus nftables spike |
| 2026-08-05 | Phase 8 Caddy decision | Locked in direct krun/TSI as the implementation path and explicitly deferred code changes | No NAS or runtime state changed. Production Caddy remains on ordinary rootless crun. The selected future design uses 2 vCPUs, 512 MiB, HTTP/1.1 and HTTP/2 only, the existing low-port sysctl, persistent state, and restart-based operation without `podman exec`. | Commit documentation only; implement and validate Caddy in a later session |
| 2026-08-05 | Phase 8 Caddy implementation | Enabled Caddy's generated Quadlet for krun with 2 vCPUs, 512 MiB, SIGINT, and explicit non-loopback DNS; limited the Caddyfile to HTTP/1.1 and HTTP/2; added focused regression coverage | No NAS action. Generation, all 38 unit tests, `git diff --check`, adaptation by the exact pinned Caddy binary, and the operator-run full image build passed. | Push for normal deployment, then execute the Caddy completion gates |
| 2026-08-05 | Phase 8 Caddy deployment | Recorded the deployed image and first functional evidence; prepared the runtime/resource proof command | Operator reports the changed image is deployed and `visualize.i.samhclark.com` still loads Grafana through Caddy. Runtime and remaining gates have not yet been checked. | Prove the active user service, krun runtime, and selected CPU/RAM annotations |
| 2026-08-05 | Phase 8 Caddy runtime proof | Recorded the deployed runtime, resources, and healthy user-service state | Caddy reported active/running with `Result=success`; Podman reported `runtime=krun status=running cpus=2 ram_mib=512` | Verify TCP 80/443 listeners and the intentional absence of UDP 443 |
| 2026-08-05 | Phase 8 Caddy listener proof | Recorded the selected direct-TSI network surface | `VM:nas` owned wildcard TCP listeners on ports 80 and 443; UDP 443 had no listener, as expected with HTTP/3 disabled | Verify the redirect, HTTP/2 reverse-proxy routes, and local Caddy metrics |
| 2026-08-05 | Phase 8 Caddy route and metrics proof | Verified the redirect, three known reverse proxies, negotiated protocol, and local metrics | HTTP redirected with 308 to HTTPS. Garage, VictoriaMetrics, and Grafana each returned HTTP/2 200. Caddy metrics returned a live admin request counter; the subsequent curl 23 was only the expected early pipe close from `grep -m1`. | Verify the Cloudflare runtime secret and preserved ACME, certificate, and config state |
| 2026-08-05 | Phase 8 Caddy secret and state proof | Verified the runtime-secret and persistent-state host contracts without exposing contents | The token remained `_nas_caddy:_nas_caddy` mode 0400, readable by `_nas_caddy`, and privately MCS-labeled. Both state roots remained `_nas_caddy:_nas_caddy` mode 0750 with `container_file_t:s0`. ACME, certificate, and config trees contained 4, 18, and 1 files. | Verify the S3 route reaches Garage, then prepare the restart preservation proof |
| 2026-08-05 | Phase 8 Caddy S3 route proof | Verified the remaining configured reverse-proxy route without using credentials | The S3 endpoint returned the expected unauthenticated HTTP 403 over HTTP/2 from tailnet address `100.86.242.118:443`, proving the request crossed Caddy to Garage | Capture an aggregate persistent-state fingerprint before the separate restart action |
| 2026-08-05 | Phase 8 Caddy pre-restart state | Captured a content-only aggregate fingerprint without exposing file names or contents | The combined persistent-state fingerprint was `5eb58091e9a3f15681e9cee47aafb71ca190c91fb89b3008834457c928c41f3f` | Restart only Caddy, prove bounded recovery, compare the fingerprint, and inspect the focused journal |
| 2026-08-05 | Phase 8 Caddy restart recovery | Restarted only the rootless Caddy user service and compared exact state | Recovery completed within 30 seconds; service and krun container were active/running/successful; the state fingerprint remained exactly `5eb58091e9a3f15681e9cee47aafb71ca190c91fb89b3008834457c928c41f3f`. Startup logged 2 CPUs, a 487091404-byte Go memory limit, and h1/h2 on `srv0`. The tailed journal began after shutdown evidence. | Recover the preceding focused shutdown lines and confirm SIGINT clean exit |
| 2026-08-05 | Phase 8 Caddy clean shutdown | Closed the missing half of the restart evidence | Caddy received SIGINT, logged `shutdown complete` with exit code 0, and stopped its HTTP/admin servers; Podman reported the old container died and was removed before systemd marked the service stopped | Reboot the NAS when convenient, then run a separate post-boot recovery check |
| 2026-08-05 | Phase 8 completion | Counted the bootc deployment boot as the full-boot gate and closed the service phase | The changed image-managed Quadlet could only become active after booting the deployment. Subsequent evidence proved krun/resources, TCP-only listeners, all routes, metrics, secret/state contracts, exact state preservation, recovery, and clean shutdown. The current Caddyfile has no operational source-IP policy. | Begin Phase 9 steady-state documentation and final repository verification; no NAS command is pending |
| 2026-08-05 | Phase 9 completion | Finalized topology, exceptions, schema, roadmap, and evidence; regenerated outputs and ran all 38 tests | No NAS action. Disposable experiments were already removed, the implementation build/deployment passed, and production validation is complete. | Commit and push the final documentation; return to ordinary roadmap work |
| 2026-08-06 | Streaming TSI diagnosis and nested-passt proof | Traced a stalled Swiftfin seek through Caddy and Jellyfin VMM threads blocked in `tcp_sendmsg`; corrected the scope of crun's broad passt mapping and implemented private nested passt for both streaming services | Two disposable guests concurrently served guest port 18080 through distinct namespaces and narrow loopback publications. Pasta `-T` reached loopback-only host backends with both one and two simultaneous explicit mappings. With a deliberately stalled 512-MiB response and 1.28-MiB host send queue, 20 health probes had zero failures and 2.9-ms maximum latency while the VMM main thread waited in `epoll`. All disposable containers and ports were removed. | Deploy normally, then validate listeners, routes, HTTP/3, seeking, health, and playback metrics |

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
