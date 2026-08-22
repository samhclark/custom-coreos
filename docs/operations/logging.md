# Host logging pilot

The configured logging pilot is:

```text
persistent journald -> host Vector -> loopback:9428 -> VictoriaLogs/libkrun
                                                     -> Grafana Explore
```

The pilot forwards only journald records selected by the Caddy UID (`51310`)
and VictoriaMetrics UID (`51250`). Caddy access logs, media applications,
the *arr services, and Mullvad/WireGuard logging remain deferred. Vector and
VictoriaLogs are configured in the image but are awaiting production
validation.

VictoriaLogs stores seven days of searchable history on
`tank/victoria-logs/data`, with a pool-filesystem usage guard at 80 percent.
Grafana Explore reaches it through the provisioned, non-default VictoriaLogs
datasource. Logs therefore inherit Grafana's current anonymous-admin access
boundary; VictoriaLogs is not published through Caddy.

The local journal remains the emergency diagnostic source. The intended host
journald policy is persistent storage under `/var/log/journal`, compressed and
bounded to seven days or 512 MiB, with a 2 GiB free-space reserve. Vector's
checkpoint and disk buffer remain on the root filesystem under
`/var/lib/nas-vector`; its runtime files are ephemeral under `/run/nas-vector`.
The pre-deployment journal used about 3.9 GiB, so the first boot with this
policy is expected to vacuum older history down toward the new 512 MiB bound.

Delivery is at-least-once. During a prolonged VictoriaLogs outage, Vector first
uses its 1 GiB disk buffer and then backpressures journald. If journald itself
reaches its configured limits, the oldest records can be vacuumed. Restarts
may duplicate records and are acceptable for this pilot.

## Pre-deployment gate

Run these read-only checks on the NAS before deployment:

```bash
findmnt -no SOURCE,FSTYPE,TARGET -T /var
findmnt -no SOURCE,FSTYPE,TARGET -T /var/log/journal
df -h /var /run
sudo journalctl --disk-usage
sudo journalctl --list-boots --no-pager | head

for uid in 51310 51250; do
  sudo journalctl -b -n 100 --no-pager -o json "_UID=${uid}" |
    jq -r '[._UID, ._SYSTEMD_UNIT, ._SYSTEMD_USER_UNIT, ._TRANSPORT, .SYSLOG_IDENTIFIER, .CONTAINER_NAME] | @tsv' |
    sort -u
done
```

Do not deploy the pilot if `/var` has less than 5 GiB free or either service
lacks useful UID-selected runtime records. The recorded pre-deployment evidence
passed both gates: `/var` had 436 GiB free, the persistent journal spanned 155
historical boots, and both service UIDs exposed useful records.

## Validation sequence

Keep this pilot in the configured-but-unvalidated state until the operator has
completed these stages:

1. Read-only checks: service health, mounted storage, journal limits, Vector
   state placement, VictoriaLogs metrics, Grafana queries, buffer size, and
   SELinux denials.
2. Stop VictoriaLogs in a controlled window. Confirm Vector remains running,
   the SSD buffer grows, and the buffer drains after VictoriaLogs recovers.
3. Restart Vector once. Confirm checkpoint and buffer recovery; tolerate only
   the documented at-least-once duplicates.
4. Reboot cleanly. Confirm prior-boot journal availability, late VictoriaLogs
   startup tolerance, and records spanning the reboot.
5. Measure root-journal growth, Vector buffer writes, VictoriaLogs dataset
   growth, and HDD behavior before expanding collection.

Do not access the production NAS from development automation. Prepare reviewed
operator commands and use returned evidence for every live validation stage.

## Stage 1 read-only command

After the changed image boots, run this command before either controlled
restart test. It does not change service or storage state and does not print
log contents:

```bash
for spec in \
  '_nas_caddy 51310 caddy.service' \
  '_nas_victoriametrics 51250 victoria-metrics.service' \
  '_nas_victorialogs 51270 victoria-logs.service' \
  '_nas_grafana 51210 grafana.service'; do
  read -r user uid unit <<<"${spec}"
  printf '\n== %s (%s) ==\n' "${unit}" "${uid}"
  sudo systemctl is-active "user@${uid}.service"
  sudo -u "${user}" env \
    HOME="/var/home/${user}" \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user show "${unit}" \
      -p LoadState -p ActiveState -p SubState -p NRestarts
done

printf '\n== Vector ==\n'
sudo systemctl is-active nas-vector.service
sudo systemctl show nas-vector.service \
  -p LoadState -p ActiveState -p SubState -p MainPID -p NRestarts
sudo journalctl -u nas-vector.service -b -n 50 --no-pager

printf '\n== Journal and storage ==\n'
test -d /var/log/journal && echo persistent-journal-directory=present
sudo systemd-analyze cat-config systemd/journald.conf |
  grep -E '^(Storage|Compress|SystemMaxUse|SystemKeepFree|SystemMaxFileSize|MaxRetentionSec|RuntimeMaxUse|RuntimeKeepFree|RuntimeMaxFileSize)='
sudo journalctl --disk-usage
sudo journalctl -b -1 -n 1 --no-pager
sudo findmnt -no SOURCE,FSTYPE,TARGET -T /var/lib/victoria-logs
sudo zfs list -H -o name,mountpoint,used,avail tank/victoria-logs/data
sudo zfs get -H -o property,value \
  recordsize,compression,atime,primarycache tank/victoria-logs/data
sudo stat -c '%U:%G %a %C %n' /var/lib/victoria-logs
sudo du -shL /var/lib/nas-vector
findmnt -no SOURCE,FSTYPE,TARGET -T /run/nas-vector
sudo find /run/nas-vector -mindepth 1 -maxdepth 2 \
  -printf '%M %u:%g %s %p\n' 2>/dev/null || true

printf '\n== VictoriaLogs and scrape health ==\n'
curl -fsS http://127.0.0.1:9428/metrics | sed -n '1,5p'
curl -fsS 'http://127.0.0.1:8428/api/v1/targets?state=active' |
  jq -r '.data.activeTargets[]
    | select(.labels.job=="victoria-logs")
    | [.labels.job,.health,(.lastError // ""),.lastScrape] | @tsv'
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS http://127.0.0.1:3000/api/datasources/name/VictoriaLogs |
  jq -e '{name,type,url,isDefault,jsonData}'

for service in caddy victoria-metrics; do
  if result="$(
    curl -fsSG http://127.0.0.1:9428/select/logsql/query \
      --data-urlencode "query=_stream:{host=\"nas\",service=\"${service}\"}" \
      --data-urlencode 'start=now-24h' \
      --data-urlencode 'end=now' \
      --data-urlencode 'limit=1'
  )" && test -n "${result}"; then
    echo "${service}: VictoriaLogs returned a record"
  else
    echo "${service}: no record returned or query failed"
  fi
done

printf '\n== SELinux AVCs ==\n'
sudo ausearch -m AVC -ts boot -i 2>/dev/null |
  grep -Ei 'vector|victoria|grafana|caddy' ||
  echo 'No matching Vector/Victoria/Grafana/Caddy AVCs'
```

Then open Grafana Explore, select the non-default `VictoriaLogs` datasource,
and run `_stream:{host="nas",service="caddy"}`. Keep the pilot unvalidated if
either service has no recent records, the scrape is unhealthy, the datasource
fails in Explore, or matching SELinux denials are present.
