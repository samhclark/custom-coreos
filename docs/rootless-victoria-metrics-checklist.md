# Rootless VictoriaMetrics Rollout Checklist

Use this after the NAS boots an image containing the rootless VictoriaMetrics
migration. The expected host identity is `_nas_victoriametrics` with UID/GID
`51250`; the user Quadlet lives under
`/etc/containers/systemd/users/51250/victoria-metrics.container`.

The first boot may take longer while the ZFS preparation service changes
existing TSDB files from root ownership to UID/GID `51250`. The dataset root is
changed last, so an interrupted migration is retried safely on the next run.

## Before Deployment

Take a rollback snapshot while the current VictoriaMetrics service is stopped,
or immediately before the deployment reboot:

```bash
sudo zfs snapshot "tank/victoria-metrics/data@pre-rootless-$(date +%Y%m%d-%H%M%S)"
```

Deploy through a reboot so the retired rootful container and new rootless
container cannot run concurrently.

After the reboot, treat the absence of the retired system service as a hard
gate before trusting the new service with the TSDB:

```bash
test ! -e /etc/containers/systemd/victoria-metrics.container
if systemctl list-unit-files victoria-metrics.service --no-legend |
    grep -q '^victoria-metrics.service'; then
  echo 'ERROR: retired system VictoriaMetrics unit still exists' >&2
  exit 1
fi
```

If either check fails, do not manually start the rootless service. Remove the
stale rootful Quadlet only after confirming it is the retired image-managed
file, then reboot again so the system manager and Quadlet generator start from
a clean state.

## Success Criteria

- the `_nas_victoriametrics` account, subordinate IDs, linger state, and user
  manager are present
- `victoria-metrics.service` runs in the user manager, not the system manager
- the runtime Garage token is readable by only the service account
- `tank/victoria-metrics/data` remains mounted at the existing path with its
  data owned by UID/GID `51250` and labeled `container_file_t:s0`
- historical samples from before the reboot remain queryable and new samples
  continue arriving
- all eight configured scrape jobs remain healthy, aside from the documented
  possibility of a transiently slow direct Garage metrics scrape
- Grafana dashboards and vmalert continue querying VictoriaMetrics

## 1. Identity And User Manager

```bash
getent passwd _nas_victoriametrics
getent group _nas_victoriametrics
grep '^_nas_victoriametrics:' /etc/subuid /etc/subgid
loginctl show-user _nas_victoriametrics -p Linger -p State
systemctl status user@51250.service --no-pager
```

Expected subordinate-ID entries:

```text
_nas_victoriametrics:512500000:65536
```

## 2. Dataset Preparation

```bash
systemctl status zfs-create-victoria-metrics-dataset.service --no-pager
test -e /run/victoria-metrics-dataset/ready
findmnt -no SOURCE,TARGET -T /var/lib/victoria-metrics
zfs list -o name,mountpoint,used,avail tank/victoria-metrics/data
stat -c '%U:%G %a %n' /var/lib/victoria-metrics
ls -Zd /var/lib/victoria-metrics
```

The mount source must be `tank/victoria-metrics/data`, the directory should be
`_nas_victoriametrics:_nas_victoriametrics` mode `0750`, and its SELinux
context should be `container_file_t:s0` without MCS categories.

The preparation service has no start timeout and retries failures every 30
seconds. This permits a long first ownership migration and lets it recover if
`tank` is imported after the initial boot attempt. After a manual import, use
the following only if the automatic retry does not recover:

```bash
sudo systemctl restart zfs-create-victoria-metrics-dataset.service
```

An optional full ownership check prints nothing when every file is correct. It
can take time on a large dataset:

```bash
sudo find /var/lib/victoria-metrics -xdev \
  \( ! -user _nas_victoriametrics -o ! -group _nas_victoriametrics \) \
  -print -quit
```

## 3. Runtime Secret

```bash
systemctl status sops-distribute-secrets.service --no-pager
stat -c '%U:%G %a %s %n' \
  /run/nas-secrets/victoria-metrics \
  /run/nas-secrets/victoria-metrics/garage-metrics-token
sudo -u _nas_victoriametrics \
  test -r /run/nas-secrets/victoria-metrics/garage-metrics-token
```

The directory should be `root:_nas_victoriametrics` mode `0710`; the file
should be `_nas_victoriametrics:_nas_victoriametrics` mode `0400`. Do not
print its value. Garage receives an independent runtime-file copy of the same
SOPS value; the rootful Podman copy is retired by Garage's migration.

## 4. User Service And Logs

```bash
systemctl status victoria-metrics.service --no-pager
sudo -u _nas_victoriametrics env \
  HOME=/var/home/_nas_victoriametrics \
  XDG_RUNTIME_DIR=/run/user/51250 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51250/bus \
  bash -lc 'cd / && systemctl --user status victoria-metrics.service --no-pager && podman ps --no-trunc && podman exec victoria-metrics test -r /run/secrets/garage-metrics-token'
```

The system-manager status should report no unit. The user service and rootless
container should be active.

The old configuration path is unused by the rootless service. A locally
modified copy can survive the bootc `/etc` merge; after the new service and
scrape targets are validated, remove it if it remains:

```bash
test ! -e /etc/victoria-metrics/promscrape.yml ||
  sudo rm -f /etc/victoria-metrics/promscrape.yml
```

```bash
sudo -u _nas_victoriametrics sh -c \
  'cd / && HOME=/var/home/_nas_victoriametrics XDG_RUNTIME_DIR=/run/user/51250 podman logs --since 30m victoria-metrics'
```

Look for storage permissions, scrape-config failures, Garage authorization
errors, or SELinux denials.

## 5. Health And Scrape Targets

```bash
curl -fsS http://127.0.0.1:8428/-/healthy
curl -fsS http://127.0.0.1:8428/metrics >/dev/null
curl -fsS http://127.0.0.1:8428/api/v1/targets |
  jq -r '.data.activeTargets | sort_by(.labels.job)[] | [.labels.job, .health, (.lastError // "")] | @tsv'
```

Expected jobs are `alertmanager`, `caddy`, `garage`, `garage-health`, `grafana`,
`node`, `victoriametrics`, and `vmalert`. The direct `garage` scrape can be
slow; Garage availability remains based on `garage-health`:

```bash
curl -fsSG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=probe_success{job="garage-health"}' |
  jq -e '.status == "success" and any(.data.result[]; .value[1] == "1")'
```

Check that samples are recent:

```bash
curl -fsSG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=time() - timestamp(up)' |
  jq -r '.data.result[] | [.metric.job, .value[1]] | @tsv'
```

Most values should be below 30 seconds. Garage jobs can approach 60-90 seconds
because they use a one-minute scrape interval.

## 6. Historical Data And Grafana

Verify the same database contains node-exporter samples from both sides of the
deployment reboot:

```bash
BOOT=$(date -d "$(uptime -s)" +%s)
START=$((BOOT - 3600))
END=$(date +%s)
curl -fsSG http://127.0.0.1:8428/api/v1/query_range \
  --data-urlencode 'query=up{job="node"}' \
  --data-urlencode "start=$START" \
  --data-urlencode "end=$END" \
  --data-urlencode 'step=60s' |
  jq -e --argjson boot "$BOOT" '
    [.data.result[].values[]] as $samples |
    any($samples[]; .[0] < $boot) and any($samples[]; .[0] > $boot)
  '
```

Expected output is `true`.

In Grafana, use a time range spanning the reboot and check **ZFS & Disk
Health**, **VictoriaMetrics - vmalert**, **Alertmanager**, and **Garage S3
Storage**. Historical graphs should remain continuous and acquire fresh points
after the deployment. Grafana is the primary behavioral test, but it does not
prove the service is rootless or that dataset ownership and labels are correct.

## Rollback Note

Rolling back the bootc deployment does not require reversing ownership because
the old rootful container can access UID `51250` files. After rolling the ZFS
dataset back to a pre-migration snapshot, stop VictoriaMetrics, restart
`zfs-create-victoria-metrics-dataset.service`, and then start the rootless user
service so ownership and SELinux state are repaired before writes resume.

If the rootful image runs after a bootc rollback without a ZFS rollback, it can
create new root-owned files while the dataset root retains UID `51250`. Before
deploying the rootless image again, stop the rootful service and reset only the
dataset-root ownership so the guarded migration traverses the dataset again:

```bash
sudo systemctl stop victoria-metrics.service
sudo chown root:root /var/lib/victoria-metrics
```
