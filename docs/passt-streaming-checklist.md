# Caddy and Jellyfin Passt Validation

Use this after the first normal deployment of the image that replaces direct
TSI networking for Caddy and Jellyfin. The change does not alter their service
users, persistent mounts, secrets, or data. It adds a private outer pasta
namespace to each service and uses crun passt for the libkrun guest.

Status: repository implementation complete; production deployment validation
pending.

## Expected topology

```text
client
  -> outer rootless pasta (only declared host publications)
  -> private per-container network namespace
  -> inner crun passt (broad listeners confined here)
  -> libkrun guest
```

Caddy's outer pasta process also reverse-forwards only host-loopback backend
ports `3000`, `3900`, `3903`, `8096`, and `8428`. Inside the guest, Caddy
reaches those mappings at `10.0.0.1`. Jellyfin publishes only host loopback
TCP 8096. The two services must have different network namespaces.

## 1. Services and runtime configuration

```bash
for spec in '_nas_caddy 51310 caddy' '_nas_jellyfin 51120 jellyfin'; do
  set -- $spec
  sudo -u "$1" env \
    HOME="/var/home/$1" \
    XDG_RUNTIME_DIR="/run/user/$2" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$2/bus" \
    systemctl --user status "$3.service" --no-pager
done

sudo -u _nas_caddy env \
  HOME=/var/home/_nas_caddy XDG_RUNTIME_DIR=/run/user/51310 \
  podman inspect caddy --format \
  'runtime={{.OCIRuntime}} network={{.HostConfig.NetworkMode}} ports={{json .NetworkSettings.Ports}} annotations={{json .Config.Annotations}}'

sudo -u _nas_jellyfin env \
  HOME=/var/home/_nas_jellyfin XDG_RUNTIME_DIR=/run/user/51120 \
  podman inspect jellyfin --format \
  'runtime={{.OCIRuntime}} network={{.HostConfig.NetworkMode}} ports={{json .NetworkSettings.Ports}} health={{json .Config.Healthcheck}} annotations={{json .Config.Annotations}}'
```

Both services should report `runtime=krun`, a pasta network mode, and
`krun.use_passt=1`. Caddy should show only TCP 80/443, UDP 443, and loopback
TCP 2019. Jellyfin should show only loopback TCP 8096 and no executable image
healthcheck.

Confirm that Caddy's private namespace received the low-port threshold. The
host sysctl alone is insufficient because a new network namespace starts with
its own default:

```bash
caddy_pid=$(sudo -u _nas_caddy env \
  HOME=/var/home/_nas_caddy XDG_RUNTIME_DIR=/run/user/51310 \
  podman inspect --format '{{.State.Pid}}' caddy)
sudo nsenter -t "$caddy_pid" -n \
  sysctl -n net.ipv4.ip_unprivileged_port_start
```

The result must be `80`.

## 2. Host listeners and namespace isolation

```bash
sudo ss -H -ltnup \
  '( sport = :80 or sport = :443 or sport = :2019 or sport = :8096 )'

caddy_pid=$(sudo -u _nas_caddy env \
  HOME=/var/home/_nas_caddy XDG_RUNTIME_DIR=/run/user/51310 \
  podman inspect --format '{{.State.Pid}}' caddy)
jellyfin_pid=$(sudo -u _nas_jellyfin env \
  HOME=/var/home/_nas_jellyfin XDG_RUNTIME_DIR=/run/user/51120 \
  podman inspect --format '{{.State.Pid}}' jellyfin)
sudo readlink "/proc/$caddy_pid/ns/net" "/proc/$jellyfin_pid/ns/net"
sudo nsenter -t "$caddy_pid" -n ss -H -ltnup \
  '( sport = :80 or sport = :443 )'
```

TCP 80/443 and UDP 443 may be wildcard listeners because they are intentional
ingress. TCP 2019 and 8096 must be loopback-only. The two namespace links must
have different inode numbers.
The private-namespace listener output must include inner passt on TCP 80/443
and UDP 443; host listeners without these inner listeners only accept and then
reset connections.

## 3. Routes, metrics, and HTTP/3

```bash
curl -fsS http://127.0.0.1:2019/metrics >/dev/null
curl -fsS http://127.0.0.1:8096/health
curl -fsS https://garage.i.samhclark.com/health
curl -fsS https://metrics.i.samhclark.com/-/healthy
curl -fsS https://visualize.i.samhclark.com/api/health | jq .
curl -fsS https://jellyfin.i.samhclark.com/health

openssl s_client -quic -alpn h3 \
  -connect 127.0.0.1:443 \
  -servername jellyfin.i.samhclark.com </dev/null 2>&1 |
  grep -E 'Protocol|ALPN protocol|Verification'
```

Every HTTP request should succeed. The OpenSSL probe should negotiate `h3`;
it proves the QUIC/TLS transport and ALPN, not a complete HTTP/3 request.

## 4. Reproduce the original workload

Start a Direct Play item in Swiftfin, seek backward by 15 seconds several
times, and watch the Jellyfin playback dashboard. During and immediately after
the seeks:

```bash
for attempt in $(seq 1 20); do
  curl -fsS --max-time 1 -o /dev/null \
    -w '%{http_code} %{time_total}\n' \
    http://127.0.0.1:8096/health || echo failed
  sleep 0.25
done
```

The stream should resume, the session should remain visible unless the client
deliberately closes it, and every health request should complete. Grafana
should continue updating playback position, mode, formats, and transcode
speed while the workload is active.

If it fails, capture the two user journals plus the VMM main-thread stacks
before restarting either service:

```bash
sudo journalctl _UID=51310 -b --since '-10 minutes' --no-pager
sudo journalctl _UID=51120 -b --since '-10 minutes' --no-pager
sudo cat "/proc/$caddy_pid/stack" "/proc/$jellyfin_pid/stack"
sudo ss -H -tnp '( sport = :443 or sport = :8096 )'
```

The stacks should not show `sk_stream_wait_memory`, `tcp_sendmsg`, or `sendto`
on either VMM main thread.

## 5. Reboot gate

After the focused validation succeeds, reboot once through the normal host
workflow and repeat sections 1 through 3 plus one seek test. Persistent Caddy
state, Jellyfin configuration, libraries, and monitoring history must remain
unchanged.
