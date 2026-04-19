# Plan: SOPS Secrets Management and Quadlet Generator

This plan covers two related improvements to the NAS infrastructure:

1. **SOPS + age secrets management**: Encrypted secrets checked into the repo,
   decrypted at boot and distributed to per-user podman secret stores.
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
  - [Step 1.2: Per-user secret driver](#step-12-per-user-secret-driver)
  - [Step 1.3: SOPS distribution service](#step-13-sops-distribution-service)
  - [Step 1.4: Remove garage-generate-secrets](#step-14-remove-garage-generate-secrets)
  - [Step 1.5: Deploy and verify (rootful secrets)](#step-15-deploy-and-verify-rootful-secrets)
  - [Step 1.6: Deploy and verify (rootless secrets)](#step-16-deploy-and-verify-rootless-secrets)
- [Phase 2: Quadlet generator](#phase-2-quadlet-generator)
  - [Step 2.1: Config schema and generator script](#step-21-config-schema-and-generator-script)
  - [Step 2.2: Convert existing services](#step-22-convert-existing-services)
  - [Step 2.3: CI drift check and SOPS verification](#step-23-ci-drift-check-and-sops-verification)
  - [Step 2.4: Deploy (should be no-op)](#step-24-deploy-should-be-no-op)
- [Appendix A: File inventory](#appendix-a-file-inventory)
- [Appendix B: Secret inventory](#appendix-b-secret-inventory)
- [Appendix C: Config schema reference](#appendix-c-config-schema-reference)

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

No rootless services use podman secrets yet.

Problems:
- Some secrets are manually created and exist only on the NAS (cf-api-token,
  pushover tokens). If the NAS is rebuilt, they must be re-created by hand.
- Garage secrets are randomly generated at first boot. They cannot be
  pre-configured or version-controlled.
- There is no mechanism for rootless services to consume podman secrets, because
  `systemd-creds encrypt/decrypt` without `--user` requires root.

### Current quadlet boilerplate

Each rootless service requires ~7 nearly identical files:
- `overlay-root/etc/containers/systemd/users/$UID/$SERVICE.container`
- `overlay-root/usr/lib/sysusers.d/nas-$SERVICE.conf`
- `overlay-root/usr/lib/tmpfiles.d/nas-$SERVICE-rootless.conf`
- `overlay-root/usr/local/bin/ensure-nas-$SERVICE-account.sh`
- `overlay-root/etc/systemd/system/ensure-nas-$SERVICE-account.service`
- Entries in `overlay-root/etc/subuid` and `overlay-root/etc/subgid`

The ensure-account scripts are ~90 lines each, 95% identical across services.

### Key finding: user-scoped systemd-creds

Tested on Fedora 43 (systemd 257):

- `systemd-creds encrypt --user` works without root. It talks to the system
  credential service via the `/run/systemd/io.systemd.Credentials` varlink
  socket.
- Root can encrypt for a specific user with `--uid=<uid>`. The credential
  incorporates the target user's UID, username, and the machine ID.
- The target user can decrypt with `systemd-creds decrypt --user`. No sudo,
  no PAM escalation.
- `--with-key=host+tpm2` works in both `--user` and `--uid=` modes, preserving
  the full TPM2+host binding.

This means the existing shell driver pattern can extend to rootless users with
minimal changes: add `--user` to the encrypt/decrypt calls and use per-user
store directories.

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

### Step 1.2: Per-user secret driver

**Goal**: Extend the existing shell driver to support rootless users via
user-scoped systemd-creds.

**Current driver** (`/usr/local/lib/podman-secret-driver/`):
- `store.sh`: `systemd-creds encrypt --with-key=tpm2+host`
- `lookup.sh`: `systemd-creds decrypt`
- `delete.sh`: `rm -f`
- `list.sh`: `ls *.cred`
- All use `STORE_DIR="/var/lib/podman-secrets"`

**Changes needed**:

The driver scripts need to detect whether they are operating on root's Podman
store or a rootless user's Podman store. Do not rely only on `id -u`: Podman may
invoke shell secret-driver helpers from a user namespace where namespace UID 0
maps back to the rootless service user's host UID. The helper should resolve
the host UID through `/proc/self/uid_map`; host UID 0 uses
`/var/lib/podman-secrets`, and non-root host UIDs use
`/var/lib/podman-secrets/<username>`.

For `store.sh`, add an explicit `--uid=<service-user>` when the resolved host
UID is non-root. This matters because Podman may invoke shell driver helpers
from a user namespace where `--user`/`--uid=self` would resolve to namespace
UID 0 rather than the host service user. Both rootful and rootless secrets use
`host+tpm2`; rootless credentials are still user-scoped because `--uid` implies
`--user` and incorporates UID, username, and the machine ID into the encrypted
credential key.
```bash
if [[ "${host_uid}" -eq 0 ]]; then
    systemd-creds encrypt --with-key=tpm2+host --name "${SECRET_ID}.cred" - "${tmp}"
else
    systemd-creds encrypt --uid="${user}" --with-key=tpm2+host --name "${SECRET_ID}.cred" - "${tmp}"
fi
```

For `lookup.sh`, use the same explicit `--uid=<service-user>` when the
resolved host UID is non-root:
```bash
if [[ "${host_uid}" -eq 0 ]]; then
    systemd-creds decrypt --name "${SECRET_ID}.cred" "${SECRET_FILE}" -
else
    systemd-creds decrypt --uid="${user}" --name "${SECRET_ID}.cred" "${SECRET_FILE}" -
fi
```

The per-user store directories (`/var/lib/podman-secrets/<username>/`) are
created by the SOPS distribution service (Step 1.3) with ownership set to the
target user.

**Files modified**:
- `overlay-root/usr/local/lib/podman-secret-driver/store.sh`
- `overlay-root/usr/local/lib/podman-secret-driver/lookup.sh`
- `overlay-root/usr/local/lib/podman-secret-driver/delete.sh`
- `overlay-root/usr/local/lib/podman-secret-driver/list.sh`
- `overlay-root/usr/local/lib/podman-secret-driver/common.sh`

**Notes**:
- The `containers.conf.d/50-secret-driver.conf` does not change. The same
  driver scripts are used by both rootful and rootless podman. The scripts
  internally detect which mode they are in.
- The `nas-secrets` CLI wrapper works for root's secrets. For rootless user
  secrets, the operator would use
  `sudo -u _nas_grafana env HOME=/var/home/_nas_grafana nas-secrets list` or
  similar. This is a diagnostic/debugging path, not a normal workflow.

---

### Step 1.3: SOPS distribution service

**Goal**: A rootful systemd one-shot that runs at boot, decrypts the SOPS file,
and distributes secrets to the appropriate podman secret stores.

**Service unit**: `overlay-root/etc/systemd/system/sops-distribute-secrets.service`
```ini
[Unit]
Description=Decrypt SOPS secrets and distribute to podman stores
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

The distribution service needs a mapping of secret names to users. There are
two sources:

1. **Rootless services** (have TOML configs): The service reads every
   `quadlets/*.toml` file on the image (installed at
   `/usr/share/custom-coreos/quadlets/*.toml` — see note below). For each
   file, it extracts `[host].username` and `[[container.secrets]]` entries.
   This tells it e.g. "secret `garage-metrics-token` goes to user
   `_nas_grafana`."

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

A single secret can appear in both — e.g., `garage-metrics-token` may be
needed by both root (for victoria-metrics) and `_nas_grafana` (for grafana).

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

#### Per-user store directory creation

Per-user store directories (`/var/lib/podman-secrets/<username>/`) are created
by the distribution service itself, just before creating secrets for that user:
```bash
install -d -m 0700 -o "$user" -g "$user" "/var/lib/podman-secrets/$user"
```

This is done in the distribution service rather than in tmpfiles.d because only
users that actually have secrets need a store directory. The root store
(`/var/lib/podman-secrets/`) is already created by the existing
`podman-secret-driver.conf` tmpfiles entry. The parent directory is `0711 root
root` so rootless users can traverse to their own private `0700` subdirectory
without being able to list the root store.

#### Script flow

**Script**: `overlay-root/usr/local/bin/sops-distribute-secrets.sh`

```
1. Decrypt the age private key:
   systemd-creds decrypt --name=age-key \
     /var/lib/nas-secrets/age-key.cred /tmp/age-key.txt

2. Decrypt the SOPS file using the age key:
   SOPS_AGE_KEY_FILE=/tmp/age-key.txt \
     sops --decrypt /usr/share/custom-coreos/secrets/secrets.sops.yaml \
     > /tmp/secrets-plain.yaml

3. Shred the age key from /tmp:
   shred -u /tmp/age-key.txt

4. Build the secret-to-user mapping:
   a. Read /usr/share/custom-coreos/secrets/rootful-secrets.json
      → all listed secrets map to user "root"
   b. Read each /usr/share/custom-coreos/quadlets/*.toml
      → for each file, map [container.secrets].name entries to
        [host].username and [host].uid
   Result example:
     root:           [garage-rpc-secret, garage-admin-token, ...]
     _nas_grafana:   [garage-metrics-token]

5. Load the previous distribution state from
   /var/lib/nas-secrets/distributed-state.json.
   If the file does not exist (first boot), treat it as empty — all
   secrets will be created.

6. For each (user, secret) pair in the mapping:
   a. Compute sha256 of the secret value from the decrypted YAML.
   b. Compare against the hash in the state file (if any).
   c. If hashes match: skip (secret is up to date).
   d. If hashes differ or secret is new: create/replace.

   Create/replace logic:
     - If the secret already exists in podman: delete it first.
     - Create the new secret:

       For root:
         echo "$value" | podman secret create "$name" -

       For rootless users:
         install -d -m 0700 -o "$user" -g "$user" \
           "/var/lib/podman-secrets/$user"
         echo "$value" | sudo -u "$user" env HOME="/var/home/$user" \
           podman secret create "$name" -

       This calls the shell driver's store.sh as the target user.
       For rootless users, store.sh detects non-root and uses
       systemd-creds encrypt --user --with-key=host+tpm2.
       Podman handles its own metadata automatically.

7. For each (user, secret) pair in the OLD state that is NOT in the
   new mapping: delete the secret.

     For root:
       podman secret rm "$name"

     For rootless users:
       sudo -u "$user" env HOME="/var/home/$user" \
         podman secret rm "$name"

8. Shred the plaintext secrets file:
   shred -u /tmp/secrets-plain.yaml

9. Write the new state file to
   /var/lib/nas-secrets/distributed-state.json:

   {
     "root": {
       "garage-rpc-secret": "<sha256>",
       "garage-admin-token": "<sha256>",
       ...
     },
     "_nas_grafana": {
       "garage-metrics-token": "<sha256>"
     }
   }
```

#### Early boot compatibility

This approach uses `sudo -u $user podman secret create` for rootless secrets.
This works at early boot because:
- `podman secret create` is a local file operation — no D-Bus, no user
  manager, no container runtime needed.
- `systemd-creds encrypt --user` (called by store.sh) talks to the
  system-level varlink socket at `/run/systemd/io.systemd.Credentials`,
  which is available from PID 1 very early.
- The service runs `After=systemd-sysusers.service systemd-tmpfiles-setup.service`,
  so the user account and home directory exist.

**Verify on the NAS before deploying**: Run this manual test to confirm:
```bash
# As root, create a test secret for a rootless user
echo "test-value" | sudo -u _nas_grafana \
  env HOME=/var/home/_nas_grafana \
  podman secret create test-early-boot -

# Verify it exists
sudo -u _nas_grafana env HOME=/var/home/_nas_grafana \
  podman secret ls

# Clean up
sudo -u _nas_grafana env HOME=/var/home/_nas_grafana \
  podman secret rm test-early-boot
```

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

### Step 1.6: Deploy and verify (rootless secrets)

This step is for when a rootless service first needs a secret. It may happen
as part of a future service migration or when adding a new service.

**Work**:
1. Add `[[container.secrets]]` entries to the service's TOML config
   (e.g., `quadlets/grafana.toml`).
2. Re-run `python3 generate-quadlets.py` to regenerate the .container file
   with `Secret=` lines.
3. The distribution service automatically picks up the new mapping from the
   TOML config — no separate manifest change needed.
4. Deploy the new image and test on the NAS.

**Post-deploy verification**:
```bash
# Check the secret was distributed to the rootless user
sudo -u _nas_grafana env HOME=/var/home/_nas_grafana \
  XDG_RUNTIME_DIR=/run/user/51210 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/51210/bus \
  bash -lc 'podman secret ls && systemctl --user status grafana.service'
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
  emits `Secret=` lines in the .container file AND verifies these against
  the SOPS file.

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
overlay-root/usr/local/lib/podman-secret-driver/store.sh
overlay-root/usr/local/lib/podman-secret-driver/lookup.sh
overlay-root/usr/local/lib/podman-secret-driver/delete.sh
overlay-root/usr/local/lib/podman-secret-driver/list.sh
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
mode = "0400"               # Optional file mode

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
