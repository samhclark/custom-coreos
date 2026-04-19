# Plan: SOPS Secrets Management and Quadlet Generator

This plan covers two related improvements to the NAS infrastructure:

1. **SOPS + age secrets management**: Encrypted secrets checked into the repo,
   decrypted once at boot, distributed to rootful Podman secrets, and written
   as per-service runtime files under `/run` for rootless services.
2. **Quadlet generator**: A Python script that reads declarative config files
   and generates the rootless quadlet boilerplate (sysusers.d, tmpfiles.d,
   ensure-account scripts, container units, subuid/subgid).

These are independently deployable. Phase 1 (SOPS) changes runtime behavior
and needs careful deploy/verify cycles. Phase 2 (generator) is a repo-side
refactor — the generated files should match current files, so deploying is a
no-op until new services are added.

---

## Table of Contents

- [Background](#background)
- [Phase 1: SOPS + age secrets](#phase-1-sops--age-secrets)
  - [Step 1.1: Age keypair and SOPS file](#step-11-age-keypair-and-sops-file)
  - [Step 1.2: Rootless runtime secret delivery](#step-12-rootless-runtime-secret-delivery)
  - [Step 1.3: SOPS distribution service](#step-13-sops-distribution-service)
  - [Step 1.4: Remove garage-generate-secrets](#step-14-remove-garage-generate-secrets)
  - [Step 1.5: Deploy and verify (rootful secrets)](#step-15-deploy-and-verify-rootful-secrets)
  - [Step 1.6: Deploy and verify (rootless runtime files)](#step-16-deploy-and-verify-rootless-runtime-files)
- [Phase 2: Quadlet generator](#phase-2-quadlet-generator)
  - [Step 2.1: Config schema and generator script](#step-21-config-schema-and-generator-script)
  - [Step 2.2: Convert existing services](#step-22-convert-existing-services)
  - [Step 2.3: CI drift check and SOPS verification](#step-23-ci-drift-check-and-sops-verification)
  - [Step 2.4: Deploy (should be no-op)](#step-24-deploy-should-be-no-op)
- [Appendix A: File inventory](#appendix-a-file-inventory)
- [Appendix B: Secret inventory](#appendix-b-secret-inventory)
- [Appendix C: Config schema reference](#appendix-c-config-schema-reference)
- [Appendix D: Rootless secret findings](#appendix-d-rootless-secret-findings)

---

## Background

### Current secrets story

Secrets are stored via a custom podman shell driver that encrypts at rest with
`systemd-creds --with-key=tpm2+host`. The driver scripts live at
`/usr/local/lib/podman-secret-driver/` and store encrypted credential files in
`/var/lib/podman-secrets/`.

Today, only rootful services use podman secrets:
- **garage**: `garage-rpc-secret`, `garage-admin-token`, `garage-metrics-token`
  (auto-generated at boot by `garage-generate-secrets.sh`)
- **victoria-metrics**: `garage-metrics-token` (shared with garage)
- **caddy**: `cf-api-token` (manually created on the NAS)
- **alertmanager**: `pushover-user-key`, `pushover-api-token` (manually created,
  read by `alertmanager-generate-config.sh` via `nas-secrets show`)

No rootless services use secrets yet.

Problems:
- Some secrets are manually created and exist only on the NAS (cf-api-token,
  pushover tokens). If the NAS is rebuilt, they must be re-created by hand.
- Garage secrets are randomly generated at first boot. They cannot be
  pre-configured or version-controlled.
- The rootful Podman secret driver is not a safe path for rootless services.
  NAS testing showed rootless Podman's shell-driver helper can run in a user
  namespace where meaningful `systemd-creds` key modes cannot access the host
  credential secret or TPM device.

### Current quadlet boilerplate

Each rootless service requires ~7 nearly identical files:
- `overlay-root/etc/containers/systemd/users/$UID/$SERVICE.container`
- `overlay-root/usr/lib/sysusers.d/nas-$SERVICE.conf`
- `overlay-root/usr/lib/tmpfiles.d/nas-$SERVICE-rootless.conf`
- `overlay-root/usr/local/bin/ensure-nas-$SERVICE-account.sh`
- `overlay-root/etc/systemd/system/ensure-nas-$SERVICE-account.service`
- Entries in `overlay-root/etc/subuid` and `overlay-root/etc/subgid`

The ensure-account scripts are ~90 lines each, 95% identical across services.

### Key finding: user-scoped systemd-creds and rootless Podman

Initial Fedora 43 testing showed that user-scoped `systemd-creds` can work in a
plain user session. NAS validation later showed an important caveat: rootless
Podman may invoke shell secret-driver helpers inside a user namespace, and that
namespace cannot access the host credential secret or TPM device in the way
`systemd-creds` needs.

Validated behavior on the NAS:
- `systemd-creds --user --with-key=host`, `host+tpm2`, and `auto` work for the
  `core` user in a normal shell.
- `systemd-creds --user --with-key=tpm2`, `auto-initrd`, and `null` are rejected
  in `--uid=` scoped mode.
- Direct `_nas_grafana` use of `systemd-creds --uid=_nas_grafana
  --with-key=host+tpm2` works in a normal shell.
- The same explicit `--uid=_nas_grafana --with-key=host+tpm2` command fails
  inside `podman unshare` with `Failed to determine local credential host
  secret: Permission denied`.
- Inside `podman unshare`, unscoped `host`, `host+tpm2`, and `auto` fail on the
  host secret; `tpm2` and `auto-initrd` fail opening `/dev/tpmrm0`; only `null`
  works, which is not useful for secrets.

Conclusion: the existing Podman shell-driver pattern is good for rootful Podman
secrets, but should not be considered a validated path for rootless Podman
secrets. Future rootless secret work should use a different design. See
[Appendix D](#appendix-d-rootless-secret-findings).

---

## Phase 1: SOPS + age secrets

### Step 1.1: Age keypair and SOPS file

**Goal**: Create the age keypair, encrypt all existing secrets into a SOPS file
checked into the repo, and store the age private key on the NAS.

**Work**:

1. Generate an age keypair:
   ```bash
   age-keygen -o age-key.txt
   # Public key is printed to stderr and written in the file header
   ```

2. Create `.sops.yaml` in the repo root to configure SOPS:
   ```yaml
   creation_rules:
     - path_regex: ^overlay-root/usr/share/custom-coreos/secrets/.*\.sops\.yaml$
       age: "age1<public-key-here>"
   ```

3. Create the secrets file at
   `overlay-root/usr/share/custom-coreos/secrets/secrets.sops.yaml` with all
   current secrets as a flat key-value map:
   ```yaml
   garage-rpc-secret: "<value>"
   garage-admin-token: "<value>"
   garage-metrics-token: "<value>"
   cf-api-token: "<value>"
   pushover-user-key: "<value>"
   pushover-api-token: "<value>"
   ```
   Encrypt with `sops --encrypt --in-place overlay-root/usr/share/custom-coreos/secrets/secrets.sops.yaml`.

4. Store the age public key in the repo at `secrets/age-recipients.txt` (one
   public key per line, standard age format). This is what SOPS uses to encrypt.

5. On the NAS, store the age private key encrypted with systemd-creds:
   ```bash
   install -d -m 0700 /var/lib/nas-secrets
   systemd-creds encrypt --with-key=tpm2+host --name=age-key \
     age-key.txt /var/lib/nas-secrets/age-key.cred
   shred -u age-key.txt
   ```
   The private key also lives in the operator's password manager as a backup.

6. Add `sops` and `age` to the packages installed in the Containerfile so they
   are available on the NAS at boot.

**Files created/modified**:
- `NEW: .sops.yaml`
- `NEW: overlay-root/usr/share/custom-coreos/secrets/secrets.sops.yaml` (encrypted)
- `NEW: secrets/age-recipients.txt`
- `MODIFIED: Containerfile` (add `sops` and `age` packages)
- `MODIFIED: .gitignore` (ensure plaintext key files are excluded)

**Notes**:
- The garage secrets currently auto-generated at boot need to be captured from
  the running NAS first (`nas-secrets show garage-rpc-secret`, etc.) and placed
  into the SOPS file. This preserves existing garage cluster identity.
- The cf-api-token and pushover tokens also need to be captured from the NAS.

---

### Step 1.2: Rootless runtime secret delivery

**Goal**: Keep the existing Podman shell secret driver as the rootful secret
store, and use rootful SOPS distribution to write rootless service secrets as
runtime-only files under `/run`.

**Selected design**:
- Rootful services continue to consume Podman secrets. Those secrets are
  encrypted at rest in `/var/lib/podman-secrets/*.cred` by the existing
  shell driver and `systemd-creds --with-key=tpm2+host`.
- Rootless services do not use Podman `Secret=` with the current shell driver.
  The shell driver can be invoked from a rootless Podman helper namespace where
  it cannot access the host credential secret or TPM device.
- `sops-distribute-secrets.service` remains rootful. It decrypts SOPS once at
  boot, creates or updates rootful Podman secrets, and writes only the rootless
  service files that are declared in the TOML configs.
- Rootless secret files live in tmpfs under `/run`, so plaintext does not
  persist across reboots and no general-purpose decryption key is handed to a
  service user.

Runtime file layout:
```text
/run/nas-secrets/                         0711 root:root
/run/nas-secrets/<service>/               0710 root:<service-user>
/run/nas-secrets/<service>/<secret-name>  0400 <service-user>:<service-user>
```

The directory is service-scoped rather than only user-scoped. If two services
need the same SOPS key, the distributor writes two separate runtime files, one
per consuming service. That keeps the service user's readable surface limited
to the files explicitly mounted into that service.

Generated rootless Quadlets should mount runtime secret files read-only into
the conventional container path:
```ini
Volume=/run/nas-secrets/grafana/garage-metrics-token:/run/secrets/garage-metrics-token:ro,Z
```

The `:Z` relabel is the intended first validation path because these files are
tiny and per-service. If rootless relabeling of `/run` files fails on the NAS,
fall back to setting the required SELinux label in the distributor and mount
without relabeling. Do not add a real rootless secret consumer until this has
been validated on the NAS.

**Rejected design**:

The earlier plan tried to extend the Podman shell driver with per-user
`/var/lib/podman-secrets/<username>/` stores and `systemd-creds --uid=<user>`.
Direct user-scoped `systemd-creds` works in a normal shell, but not from the
rootless Podman helper namespace. Keep those findings in
[Appendix D](#appendix-d-rootless-secret-findings) and do not build new
rootless secret consumers on that path.

---

### Step 1.3: SOPS distribution service

**Goal**: A rootful systemd one-shot that runs at boot, decrypts the SOPS file
once, distributes rootful Podman secrets, and writes rootless runtime secret
files under `/run`.

**Service unit**: `overlay-root/etc/systemd/system/sops-distribute-secrets.service`
```ini
[Unit]
Description=Decrypt SOPS secrets and distribute to Podman stores and runtime files
DefaultDependencies=no
After=local-fs.target systemd-sysusers.service systemd-tmpfiles-setup.service
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sops-distribute-secrets.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

This runs very early — after filesystems and user/group creation, but before
any container services start. It replaces `garage-generate-secrets.service` in
the dependency chain. Services that currently `Requires=garage-generate-secrets.service`
will change to `Requires=sops-distribute-secrets.service`.

#### How the distribution service knows which secrets go where

The distribution service needs a mapping of secret names to consumers. There
are two sources:

1. **Rootless services** (have TOML configs): The service reads every
   `quadlets/*.toml` file on the image (installed at
   `/usr/share/custom-coreos/quadlets/*.toml` — see note below). For each
   file, it extracts `[host].username` and `[[container.secrets]]` entries.
   This tells it e.g. "write secret `garage-metrics-token` to
   `/run/nas-secrets/grafana/garage-metrics-token`, owned by `_nas_grafana`."

2. **Rootful services** (no TOML configs): A separate manifest file at
   `overlay-root/usr/share/custom-coreos/secrets/rootful-secrets.json`
   declares which secrets go to root:
   ```json
   {
     "secrets": [
       "garage-rpc-secret",
       "garage-admin-token",
       "garage-metrics-token",
       "cf-api-token",
       "pushover-user-key",
       "pushover-api-token"
     ]
   }
   ```

A single SOPS key can appear in multiple places — e.g.,
`garage-metrics-token` may be needed by rootful Podman and by one or more
rootless services. Rootful consumers get a Podman secret. Each rootless service
gets its own runtime file.

**Note on TOML file location at runtime**: The TOML configs live at
`quadlets/` in the repo and are used by the generator at development time.
For the distribution service to read them at boot, they need to be installed
into the image. Add to the Containerfile:
```dockerfile
COPY quadlets/ /usr/share/custom-coreos/quadlets/
```
This makes the TOMLs available at `/usr/share/custom-coreos/quadlets/*.toml`
on the running NAS. They are read-only image-controlled files, consistent with
the existing pattern for assets under `/usr/share/custom-coreos/`.

#### Runtime secret directory creation

The distribution service owns `/run/nas-secrets` and rebuilds the runtime
secret tree on each run. Service directories are created just before writing
files for that service:
```bash
install -d -m 0711 -o root -g root /run/nas-secrets
install -d -m 0710 -o root -g "$user" "/run/nas-secrets/$service"
```

Files are written atomically with ownership and mode set before the final
rename:
```bash
install -m 0400 -o "$user" -g "$user" /dev/null "$tmp"
printf '%s' "$value" > "$tmp"
mv -f "$tmp" "/run/nas-secrets/$service/$secret"
```

This is done by the distributor rather than tmpfiles.d because only services
that declare secrets need runtime directories. The parent is traversable but
not listable by service users; each service directory is group-traversable only
by the owning service user.

#### Script flow

**Script**: `overlay-root/usr/local/bin/sops-distribute-secrets.sh`

```
1. Create a private work directory in tmpfs:
   install -d -m 0700 -o root -g root /run/nas-secrets/.work

2. Decrypt the age private key:
   systemd-creds decrypt --name=age-key \
     /var/lib/nas-secrets/age-key.cred /run/nas-secrets/.work/age-key.txt

3. Decrypt the SOPS file using the age key:
   SOPS_AGE_KEY_FILE=/run/nas-secrets/.work/age-key.txt \
     sops --decrypt /usr/share/custom-coreos/secrets/secrets.sops.yaml \
     > /run/nas-secrets/.work/secrets-plain.yaml

4. Shred the age key from /run:
   shred -u /run/nas-secrets/.work/age-key.txt

5. Build the secret-to-consumer mapping:
   a. Read /usr/share/custom-coreos/secrets/rootful-secrets.json
      → all listed secrets map to the rootful Podman secret store
   b. Read each /usr/share/custom-coreos/quadlets/*.toml
      → for each file, map [container.secrets].name entries to
        [service].name, [host].username, [host].uid, and the container target
   Result example:
     podman/root:       [garage-rpc-secret, garage-admin-token, ...]
     runtime/grafana:   [garage-metrics-token]

6. Load the previous distribution state from
   /var/lib/nas-secrets/distributed-state.json.
   If the file does not exist (first boot), treat it as empty — all
   rootful Podman secrets will be created.

7. For each rootful Podman secret:
   a. Compute sha256 of the secret value from the decrypted YAML.
   b. Compare against the hash in the state file (if any).
   c. If hashes match: skip (secret is up to date).
   d. If hashes differ or secret is new: create/replace.

   Create/replace logic:
     - If the secret already exists in podman: delete it first.
     - Create the new secret:

       echo "$value" | podman secret create "$name" -

8. Rebuild the rootless runtime file tree:
   a. Remove managed service directories under /run/nas-secrets.
   b. For each rootless service with declared secrets, create:
      /run/nas-secrets/<service>/ as 0710 root:<service-user>
   c. For each declared secret, write:
      /run/nas-secrets/<service>/<secret-name>
      as 0400 <service-user>:<service-user>

   Runtime files are always written when the service runs. Do not skip them
   solely because /var/lib/nas-secrets/distributed-state.json has a matching
   hash; /run is tmpfs and may have been cleared since the last successful
   distribution.

9. For each rootful Podman secret in the OLD state that is NOT in the new
   rootful mapping, delete the secret:

   podman secret rm "$name"

10. Shred the plaintext secrets file and remove the work directory:
    shred -u /run/nas-secrets/.work/secrets-plain.yaml
    rmdir /run/nas-secrets/.work

11. Write the new state file to
    /var/lib/nas-secrets/distributed-state.json:

   {
     "podman": {
       "root": {
         "garage-rpc-secret": "<sha256>",
         "garage-admin-token": "<sha256>",
         ...
       }
     },
     "runtime": {
       "grafana": {
         "garage-metrics-token": "<sha256>"
       }
     }
   }
```

#### Early boot compatibility

Rootful secret distribution is compatible with early boot and has been
validated on the NAS.

Rootless runtime file distribution should also be compatible with early boot:
the service runs after `systemd-sysusers.service` and
`systemd-tmpfiles-setup.service`, so service users and `/run` exist before the
files are written. The normal boot path runs this service before container
services start. Generated rootless Quadlets that consume runtime files should
also include a local readability check, such as:
```ini
ExecStartPre=/usr/bin/test -r /run/nas-secrets/grafana/garage-metrics-token
```

Do not use cross-manager ordering from user services to
`sops-distribute-secrets.service` as the primary dependency. It is clearer for
the distributor to run early and for the user service to fail with an explicit
missing-file check if the distributor did not complete.

**Files created**:
- `NEW: overlay-root/usr/local/bin/sops-distribute-secrets.sh`
- `NEW: overlay-root/etc/systemd/system/sops-distribute-secrets.service`
- `NEW: overlay-root/usr/share/custom-coreos/secrets/rootful-secrets.json`

**Files modified**:
- `overlay-root/etc/containers/systemd/garage.container`
  (change `Requires=garage-generate-secrets.service` to
  `Requires=sops-distribute-secrets.service`)
- `overlay-root/etc/containers/systemd/victoria-metrics.container`
  (same change)
- `Containerfile` (enable `sops-distribute-secrets.service`,
  add `sops` and `age` packages,
  `COPY quadlets/ /usr/share/custom-coreos/quadlets/`)

**NAS setup (manual, one-time)**:
- The age private key must already be encrypted and stored at
  `/var/lib/nas-secrets/age-key.cred` (done in Step 1.1).

---

### Step 1.4: Remove garage-generate-secrets

**Goal**: Remove the auto-generation of garage secrets since they are now
managed by SOPS.

**Files deleted**:
- `overlay-root/usr/local/bin/garage-generate-secrets.sh`
- `overlay-root/etc/systemd/system/garage-generate-secrets.service`

**Files modified**:
- `Containerfile`: remove `garage-generate-secrets.service` from
  `systemctl enable` list, add `sops-distribute-secrets.service`
- `overlay-root/etc/containers/systemd/garage.container`: change
  `After=...garage-generate-secrets.service...` and
  `Requires=garage-generate-secrets.service` to reference
  `sops-distribute-secrets.service`
- `overlay-root/etc/containers/systemd/victoria-metrics.container`: same

---

### Step 1.5: Deploy and verify (rootful secrets)

**DEPLOY CHECKPOINT**

At this point, commit everything from Steps 1.1-1.4, push, and let the image
build. Before deploying to the NAS:

**Pre-deploy on the NAS**:
1. Capture existing secrets:
   ```bash
   nas-secrets show garage-rpc-secret
   nas-secrets show garage-admin-token
   nas-secrets show garage-metrics-token
   nas-secrets show cf-api-token
   nas-secrets show pushover-user-key
   nas-secrets show pushover-api-token
   ```
   Put these values into the SOPS file and re-encrypt.

2. Encrypt and store the age private key on the NAS:
   ```bash
   install -d -m 0700 /var/lib/nas-secrets
   systemd-creds encrypt --with-key=tpm2+host --name=age-key \
     age-key.txt /var/lib/nas-secrets/age-key.cred
   shred -u age-key.txt
   ```

**Deploy**: Update the NAS to the new image (bootc upgrade).

**Post-deploy verification**:
```bash
# Check the SOPS distribution service ran successfully
systemctl status sops-distribute-secrets.service
journalctl -u sops-distribute-secrets.service

# Verify all rootful secrets are present
podman secret ls
nas-secrets show garage-rpc-secret
nas-secrets show garage-admin-token
nas-secrets show garage-metrics-token
nas-secrets show cf-api-token
nas-secrets show pushover-user-key
nas-secrets show pushover-api-token

# Verify garage starts and works
systemctl status garage.service
curl -s http://127.0.0.1:3903/health

# Verify victoria-metrics starts and can scrape garage
systemctl status victoria-metrics.service
curl -s http://127.0.0.1:8428/-/healthy

# Verify alertmanager config was generated correctly
systemctl status alertmanager-generate-config.service
# No unsubstituted placeholders:
grep -c '__' /var/lib/alertmanager/alertmanager.yml && echo "FAIL" || echo "OK"

# Verify caddy has its secret
systemctl status caddy.service
```

---

### Step 1.6: Deploy and verify (rootless runtime files)

This step is for the first rootless service that needs a secret. It uses the
runtime-file design from Step 1.2, not Podman `Secret=`.

**Work**:
1. Add `[[container.secrets]]` entries to the service's TOML config
   (e.g., `quadlets/grafana.toml`):
   ```toml
   [[container.secrets]]
   name = "garage-metrics-token"
   target = "/run/secrets/garage-metrics-token"
   mode = "0400"
   ```
2. Re-run `python3 generate-quadlets.py` to regenerate the `.container` file.
   The generator emits a read-only volume mount from the distributor-owned
   runtime file:
   ```ini
   Volume=/run/nas-secrets/grafana/garage-metrics-token:/run/secrets/garage-metrics-token:ro,Z
   ExecStartPre=/usr/bin/test -r /run/nas-secrets/grafana/garage-metrics-token
   ```
3. The distribution service automatically picks up the new mapping from the
   TOML config. No rootless Podman secret store and no separate rootless
   manifest are needed.
4. Deploy the new image and test on the NAS before relying on the secret in
   production.

**Validation focus**:
- The distributor creates `/run/nas-secrets/<service>/` with the expected owner,
  group, mode, and SELinux label.
- The rootless service user can read the host file.
- The rootless container can read the mounted target file.
- The file is gone after reboot until `sops-distribute-secrets.service` runs
  again.

**Post-deploy verification**:
```bash
# Check the distributor wrote the runtime file without printing the secret
systemctl status sops-distribute-secrets.service
sudo ls -ldZ /run/nas-secrets /run/nas-secrets/grafana
sudo ls -lZ /run/nas-secrets/grafana

# Check the service user can read it
sudo -u _nas_grafana test -r /run/nas-secrets/grafana/garage-metrics-token

# Check the user service and container can see the mounted file
sudo -u _nas_grafana env HOME=/var/home/_nas_grafana \
  XDG_RUNTIME_DIR=/run/user/51210 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51210/bus \
  bash -lc 'systemctl --user status grafana.service && podman exec grafana test -r /run/secrets/garage-metrics-token'
```

---

## Phase 2: Quadlet generator

### Step 2.1: Config schema and generator script

**Goal**: Create `generate-quadlets.py` and define the config file format.

**Config file location**: `quadlets/` directory at repo root. One TOML file per
rootless service. Example: `quadlets/grafana.toml`.

**Generator location**: `generate-quadlets.py` at repo root.

**Config schema** (see Appendix C for full reference):

```toml
# quadlets/grafana.toml

[service]
name = "grafana"
description = "Grafana Dashboard"
documentation = "https://grafana.com/docs/grafana/latest/"

[host]
username = "_nas_grafana"
uid = 51210
subid-start = 512100000

[container]
image = "docker.io/grafana/grafana-oss:12.1.1"
network = "host"
container-user = 0
pull = "newer"

[container.environment]
GF_PLUGINS_PREINSTALL_SYNC = "victoriametrics-metrics-datasource"
GF_SERVER_HTTP_ADDR = "127.0.0.1"
GF_SERVER_HTTP_PORT = "3000"
GF_AUTH_ANONYMOUS_ENABLED = "true"
GF_AUTH_ANONYMOUS_ORG_ROLE = "Admin"
GF_AUTH_DISABLE_LOGIN_FORM = "true"

[[container.volumes]]
source = "/usr/share/custom-coreos/grafana/provisioning"
target = "/etc/grafana/provisioning"
options = "ro"

[[container.volumes]]
source = "/usr/share/custom-coreos/grafana/dashboards"
target = "/etc/grafana/dashboards"
options = "ro"

[[container.volumes]]
source = "/var/lib/grafana"
target = "/var/lib/grafana"

[[container.secrets]]
name = "some-future-secret"
target = "/run/secrets/some-future-secret"
mode = "0400"

[data]
path = "/var/lib/grafana"
mode = "0750"

[assets]
path = "/usr/share/custom-coreos/grafana"

[unit]
restart-sec = 30
timeout-start-sec = 900

# Arbitrary extra lines injected into quadlet sections.
# For service-specific directives that don't fit the common schema.
[unit.extra]
Unit = []
Service = []
Install = []
Container = []
```

Design principles:
- The TOML captures what varies between services. Conventions are baked into
  the generator (e.g., `WantedBy=default.target`, `Restart=always`,
  subid-count is always 65536).
- The `[unit.extra]` escape hatch allows injecting arbitrary lines into any
  quadlet section. For example, vmalert's `ExecStartPre` readiness loop:
  ```toml
  [unit.extra]
  Service = [
    "ExecStartPre=/usr/bin/bash -lc 'for i in {1..150}; do ...; done'",
    "TimeoutStartSec=330",
  ]
  ```
- `[[container.secrets]]` declares secrets this service needs. The generator
  emits read-only `Volume=` mounts from `/run/nas-secrets/<service>/<name>` to
  `/run/secrets/<name>` by default, adds a local readability check, and
  verifies the names against the SOPS file.

**What the generator produces per service**:

| Output file | Content |
| --- | --- |
| `overlay-root/etc/containers/systemd/users/$UID/$NAME.container` | Quadlet unit |
| `overlay-root/usr/lib/sysusers.d/nas-$NAME.conf` | User/group creation |
| `overlay-root/usr/lib/tmpfiles.d/nas-$NAME-rootless.conf` | Directories and linger |
| `overlay-root/usr/local/bin/ensure-nas-$NAME-account.sh` | Account repair script |
| `overlay-root/etc/systemd/system/ensure-nas-$NAME-account.service` | Account repair unit |

**Aggregated outputs** (one file from all services):

| Output file | Content |
| --- | --- |
| `overlay-root/etc/subuid` | All rootless users' subordinate UID ranges |
| `overlay-root/etc/subgid` | All rootless users' subordinate GID ranges |

Every generated file starts with a comment:
```
# GENERATED by generate-quadlets.py from quadlets/grafana.toml — DO NOT EDIT
```

The generator is **idempotent**: running it twice produces identical output.
It reads all `quadlets/*.toml` files, sorts them by UID for deterministic
ordering, and writes all outputs.

**SOPS verification** (built into the generator):

When run with `--verify-sops` (or by default if the SOPS file exists), the
generator:
1. Collects all secret names from `[[container.secrets]]` across all TOMLs
2. Parses the SOPS YAML file and extracts key names (SOPS leaves keys in the
   clear — no decryption needed)
3. Fails with a clear error listing any declared secrets not found in the
   SOPS file

**Implementation notes**:
- Python 3 stdlib only (`tomllib` is stdlib since 3.11, which Fedora ships).
  No pip dependencies. Use `import yaml` only if available, otherwise parse
  the SOPS YAML keys with a simple regex (the key structure is trivial).
- The generator does NOT read or modify the Containerfile. The
  `systemctl enable ensure-nas-$NAME-account.service` lines in the
  Containerfile still need manual updates when adding/removing services.
  This is intentional — the Containerfile is complex enough that
  auto-modifying it would be fragile.

---

### Step 2.2: Convert existing services

**Goal**: Create TOML configs for all three existing rootless services and
verify the generated output matches the current hand-written files.

Services to convert:
1. `grafana` (UID 51210) — has data dir, assets, environment vars
2. `vmalert` (UID 51220) — has assets, ExecStartPre readiness loop
3. `blackbox-exporter` (UID 51230) — has assets, custom exec args, AutoUpdate

**Process for each**:
1. Write the TOML config by reading the existing files
2. Run `python3 generate-quadlets.py`
3. `git diff` to compare generated vs hand-written
4. Adjust the generator or TOML until the diff is clean (or the differences
   are intentional improvements like consistent formatting)

**Expected diffs**: Some minor formatting differences are acceptable (e.g.,
consistent blank lines, comment style). Functional differences are not — the
generated quadlets must produce the same systemd behavior.

**Files created**:
- `NEW: quadlets/grafana.toml`
- `NEW: quadlets/vmalert.toml`
- `NEW: quadlets/blackbox-exporter.toml`
- `NEW: generate-quadlets.py`

**Files that become generated** (previously hand-written):
- All files listed in the "What the generator produces" table above,
  for all three services.
- `overlay-root/etc/subuid`
- `overlay-root/etc/subgid`

---

### Step 2.3: CI drift check and SOPS verification

**Goal**: Add CI checks that fail if generated files are out of date or if
declared secrets are missing from the SOPS file.

**Drift check**: Add a job to `.github/workflows/build-check.yaml`:
```yaml
verify-generated:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@...
    - name: Regenerate quadlet files
      run: python3 generate-quadlets.py
    - name: Check for drift
      run: git diff --exit-code overlay-root/
```

**SOPS verification**: This runs as part of `generate-quadlets.py` by default
(see Step 2.1). The CI drift check job already runs the generator, which
includes the SOPS key verification. No separate step needed.

**Files modified**:
- `.github/workflows/build-check.yaml` (add `verify-generated` job)

---

### Step 2.4: Deploy (should be no-op)

**DEPLOY CHECKPOINT**

This deploy should be a no-op — the generated files are byte-for-byte
identical to the hand-written ones (or functionally equivalent). The NAS
behavior does not change.

**Verification**:
```bash
# After bootc upgrade, verify all rootless services still work
for uid in 51210 51220 51230; do
  user="$(getent passwd "$uid" | cut -d: -f1)"
  echo "=== $user (UID $uid) ==="
  sudo -u "$user" \
    env HOME="/var/home/$user" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    bash -lc 'systemctl --user status --no-pager && podman ps -a --no-trunc'
done
```

---

## Appendix A: File inventory

### New files
```
.sops.yaml
secrets/age-recipients.txt
overlay-root/usr/share/custom-coreos/secrets/secrets.sops.yaml
overlay-root/usr/share/custom-coreos/secrets/rootful-secrets.json
overlay-root/usr/local/bin/sops-distribute-secrets.sh
overlay-root/etc/systemd/system/sops-distribute-secrets.service
generate-quadlets.py
quadlets/grafana.toml
quadlets/vmalert.toml
quadlets/blackbox-exporter.toml
```

### Deleted files
```
overlay-root/usr/local/bin/garage-generate-secrets.sh
overlay-root/etc/systemd/system/garage-generate-secrets.service
```

### Modified files
```
.gitignore
Containerfile
overlay-root/etc/containers/systemd/garage.container
overlay-root/etc/containers/systemd/victoria-metrics.container
.github/workflows/build-check.yaml
```

### Files that become generator-managed
```
overlay-root/etc/containers/systemd/users/51210/grafana.container
overlay-root/etc/containers/systemd/users/51220/vmalert.container
overlay-root/etc/containers/systemd/users/51230/blackbox-exporter.container
overlay-root/usr/lib/sysusers.d/nas-grafana.conf
overlay-root/usr/lib/sysusers.d/nas-vmalert.conf
overlay-root/usr/lib/sysusers.d/nas-blackbox.conf
overlay-root/usr/lib/tmpfiles.d/nas-grafana-rootless.conf
overlay-root/usr/lib/tmpfiles.d/nas-vmalert-rootless.conf
overlay-root/usr/lib/tmpfiles.d/nas-blackbox-rootless.conf
overlay-root/usr/local/bin/ensure-nas-grafana-account.sh
overlay-root/usr/local/bin/ensure-nas-vmalert-account.sh
overlay-root/usr/local/bin/ensure-nas-blackbox-account.sh
overlay-root/etc/systemd/system/ensure-nas-grafana-account.service
overlay-root/etc/systemd/system/ensure-nas-vmalert-account.service
overlay-root/etc/systemd/system/ensure-nas-blackbox-account.service
overlay-root/etc/subuid
overlay-root/etc/subgid
```

---

## Appendix B: Secret inventory

| Secret name | Used by (rootful) | Used by (rootless) | Source |
| --- | --- | --- | --- |
| `garage-rpc-secret` | garage | — | Capture from NAS, add to SOPS |
| `garage-admin-token` | garage | — | Capture from NAS, add to SOPS |
| `garage-metrics-token` | garage, victoria-metrics | — | Capture from NAS, add to SOPS |
| `cf-api-token` | caddy | — | Capture from NAS, add to SOPS |
| `pushover-user-key` | alertmanager (via generate-config) | — | Capture from NAS, add to SOPS |
| `pushover-api-token` | alertmanager (via generate-config) | — | Capture from NAS, add to SOPS |

---

## Appendix C: Config schema reference

```toml
# Required: service identity
[service]
name = "string"             # Container name and unit name
description = "string"      # Unit Description=
documentation = "string"    # Unit Documentation= (optional)

# Required: host identity for rootless user
[host]
username = "string"         # e.g., "_nas_grafana"
uid = 12345                 # Host UID and GID (same value)
subid-start = 123450000    # First subordinate ID

# Required: container configuration
[container]
image = "string"            # Full image reference
network = "string"          # "host" or omit for default
container-user = 0          # User= inside container (optional)
pull = "string"             # "newer" or "always" (default: "newer")
auto-update = "string"      # "registry" (optional)
exec = "string"             # Exec= args (optional)

# Optional: environment variables
[container.environment]
KEY = "VALUE"

# Optional: volume mounts (array of tables)
[[container.volumes]]
source = "/host/path"
target = "/container/path"
options = "ro"              # Optional mount options

# Optional: published ports (array of tables, rootful only typically)
[[container.ports]]
host = "127.0.0.1:3900"
container = 3900

# Optional: secret references (array of tables)
[[container.secrets]]
name = "secret-name"        # Must exist in SOPS file
target = "/run/secrets/secret-name"  # Container path, default shown
mode = "0400"               # Runtime host file mode, default shown

# Optional: persistent data directory
[data]
path = "/var/lib/something" # Created by tmpfiles.d, labeled by ensure-account
mode = "0750"               # Default: 0750

# Optional: image-controlled read-only assets
[assets]
path = "/usr/share/custom-coreos/something"  # SELinux-labeled in Containerfile

# Optional: unit configuration
[unit]
restart-sec = 30            # Default: 30
timeout-start-sec = 900     # Optional

# Optional: arbitrary extra lines per quadlet section
[unit.extra]
Unit = ["After=something.target"]
Container = ["PodmanArgs=--foo"]
Service = ["ExecStartPre=/usr/bin/something"]
Install = []
```

**Conventions baked into the generator** (not configurable per service):
- `subid-count` is always `65536`
- `Restart=always`
- `WantedBy=default.target`
- Group name = username, GID = UID
- Home directory = `/var/home/$username`
- Shell = `/sbin/nologin`
- Linger is always enabled
- Generated file header comment

---

## Appendix D: Rootless secret findings

### Production status

The rootful SOPS deployment is validated on the NAS:
- the age key credential decrypts
- `sops-distribute-secrets.service` completes successfully
- all six rootful Podman secrets are recreated from the SOPS file
- Garage, VictoriaMetrics, Caddy, and Alertmanager start and pass health checks

Rootless Podman secrets are not validated and should not be enabled for any
rootless service. Current rootless services do not declare secrets, so this
does not block the rootful deployment.

The selected rootless design is now runtime files under `/run` written by the
rootful SOPS distributor. That avoids the rootless Podman shell-driver
namespace entirely. It still needs a focused NAS validation pass before the
first real rootless service consumes a secret.

### NAS test results

Tests were run on the NAS as `core` and `_nas_grafana`.

User-scoped `systemd-creds` in a normal shell:
- `--user --with-key=host` works
- `--user --with-key=host+tpm2` works
- `--user --with-key=auto` works
- `--user --with-key=tpm2` fails with
  `Selected key not available in --uid= scoped mode, refusing.`
- `--user --with-key=auto-initrd` fails with the same scoped-mode error
- `--user --with-key=null` fails with the same scoped-mode error

Root creating user-scoped credentials with `--uid=core` has the same behavior:
`host`, `host+tpm2`, and `auto` work; `tpm2`, `auto-initrd`, and `null` are
rejected in scoped mode.

Direct `_nas_grafana` use works in a normal shell:
```bash
systemd-creds encrypt --uid=_nas_grafana --with-key=host+tpm2 ...
systemd-creds decrypt --uid=_nas_grafana ...
```

The same explicit `--uid=_nas_grafana --with-key=host+tpm2` command fails
inside `podman unshare`:
```text
Failed to determine local credential host secret: Permission denied
```

Inside `podman unshare`, unscoped `systemd-creds` behaves as follows:
- `host`, `host+tpm2`, and `auto` fail because the host credential secret is
  not readable from that namespace
- `tpm2` and `auto-initrd` fail because `/dev/tpmrm0` is not accessible
- `null` works, but provides no useful protection for secrets

Conclusion: rootless Podman shell-driver helpers do not have a useful
`systemd-creds` key mode available from their execution context.

### Option: age-backed Podman shell driver

An age-backed shell driver is technically possible, but it does not solve the
core key-placement problem by itself. The helper would need an age private key
available whenever Podman creates or looks up a secret.

Possible placements and tradeoffs:
- Plaintext age key persisted under the rootless service user: simple, but weak
  at-rest protection; compromise of the service user can decrypt every secret
  in that user's store.
- Age key encrypted with `systemd-creds`: returns to the same rootless helper
  problem, because the helper cannot use meaningful `systemd-creds` modes from
  Podman's user namespace.
- Root decrypts an age key to `/run` for the service user: avoids persistent
  plaintext, but gives that service user a runtime decrypt capability broader
  than just the specific secret files it needs.

For this NAS, an age-backed Podman shell driver is not the preferred next step.

### Selected design: rootful distributor writes runtime files

The selected rootless design is:
1. keep SOPS as the persistent source of truth
2. keep the age private key protected as `/var/lib/nas-secrets/age-key.cred`
3. have the rootful `sops-distribute-secrets.service` decrypt the SOPS file at
   boot
4. write only the needed per-service secret files under `/run`, owned by the
   rootless service user and mode `0400`
5. have generated rootless Quadlets mount those runtime files read-only under
   `/run/secrets/`

This keeps plaintext off persistent storage and avoids the rootless Podman shell
driver namespace entirely. It also limits each service user to exactly the
runtime files it is given, rather than handing it a general-purpose decryption
key.

Concrete layout:
```text
/run/nas-secrets/                         0711 root:root
/run/nas-secrets/<service>/               0710 root:<service-user>
/run/nas-secrets/<service>/<secret-name>  0400 <service-user>:<service-user>
```

Generated Quadlet mount:
```ini
Volume=/run/nas-secrets/<service>/<secret-name>:/run/secrets/<secret-name>:ro,Z
ExecStartPre=/usr/bin/test -r /run/nas-secrets/<service>/<secret-name>
```

Details still to validate:
- SELinux behavior for `:Z` on `/run` files mounted by rootless Podman. If this
  fails, the distributor should set a suitable label and the generated mount
  should omit relabeling.
- Normal boot ordering between the early rootful distributor and admin-managed
  rootless user services.
- Restart behavior when the distributor fails and the runtime file is missing.

### Other possible designs

Root-mediated Podman secret creation:
- A privileged helper or service could create rootless Podman secrets outside
  the problematic namespace.
- This adds a new privilege boundary and API surface. It is probably overkill
  for a single-admin NAS unless Podman secrets become mandatory.

Systemd credentials for user services:
- It may be possible to use systemd user-service credentials rather than Podman
  secrets.
- This needs separate validation with admin-managed rootless Quadlets and the
  Podman systemd generator. It should not be assumed to work.
