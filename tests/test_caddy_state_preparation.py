# ABOUTME: Regression tests for Caddy's steady-state rootless storage
# preparation and boot-scoped readiness contract.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = (
    REPO / "overlay-root/usr/local/bin/prepare-caddy-state.sh"
).read_text()
SERVICE = (
    REPO / "overlay-root/etc/systemd/system/prepare-caddy-state.service"
).read_text()
QUADLET = (
    REPO / "overlay-root/etc/containers/systemd/users/51310/caddy.container"
).read_text()


class CaddyStatePreparationTests(unittest.TestCase):
    def test_missing_state_roots_are_created_for_service_identity(self):
        self.assertIn('if [[ ! -e "${path}" ]]', SCRIPT)
        self.assertIn(
            'install -d -m 0750 -o "${SERVICE_UID}" -g "${SERVICE_GID}"',
            SCRIPT,
        )
        self.assertIn('elif [[ ! -d "${path}" ]]', SCRIPT)

    def test_existing_descendant_ownership_is_verified_not_rewritten(self):
        verification = SCRIPT.split("verify_state() {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn("find ", verification)
        self.assertIn('! -uid "${SERVICE_UID}"', verification)
        self.assertIn('! -gid "${SERVICE_GID}"', verification)
        self.assertNotIn("chown", SCRIPT)

    def test_persistent_selinux_policy_is_restored_and_verified(self):
        self.assertIn(
            'ensure_fcontext_rule "/var/lib/caddy(/.*)?"',
            SCRIPT,
        )
        self.assertIn(
            'ensure_fcontext_rule "/var/lib/caddy-config(/.*)?"',
            SCRIPT,
        )
        self.assertIn('restorecon -F -R "${STATE_PATHS[@]}"', SCRIPT)
        self.assertIn('! -context "${EXPECTED_LABEL}"', SCRIPT)

    def test_service_publishes_only_current_boot_readiness(self):
        self.assertIn("RuntimeDirectory=caddy-state", SERVICE)
        self.assertIn(
            "ExecStartPre=/usr/bin/rm -f /run/caddy-state/ready",
            SERVICE,
        )
        self.assertIn(
            "ExecStartPost=/usr/bin/touch /run/caddy-state/ready",
            SERVICE,
        )
        self.assertIn("TimeoutStartSec=300", SERVICE)
        self.assertNotIn("nas-migrations", SERVICE)

    def test_quadlet_waits_for_readiness_and_keeps_large_state_unlabeled(self):
        self.assertIn("/run/caddy-state/ready", QUADLET)
        self.assertIn("/usr/bin/test -w /var/lib/caddy", QUADLET)
        self.assertIn("/usr/bin/test -w /var/lib/caddy-config", QUADLET)
        self.assertIn("Volume=/var/lib/caddy:/data\n", QUADLET)
        self.assertIn("Volume=/var/lib/caddy-config:/config\n", QUADLET)
        self.assertNotIn("Volume=/var/lib/caddy:/data:Z", QUADLET)
        self.assertNotIn("Volume=/var/lib/caddy-config:/config:Z", QUADLET)
        self.assertNotIn("nas-migrations", QUADLET)
        self.assertNotIn("/etc/containers/systemd/caddy.container", QUADLET)

    def test_runtime_secret_mount_is_unchanged(self):
        self.assertIn(
            "Volume=/run/nas-secrets/caddy/cf-api-token:"
            "/run/secrets/cf-api-token:ro,Z",
            QUADLET,
        )


if __name__ == "__main__":
    unittest.main()
