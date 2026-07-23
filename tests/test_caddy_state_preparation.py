# ABOUTME: Regression tests for Caddy's one-time guarded state migration.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = (
    REPO / "overlay-root/usr/local/bin/prepare-caddy-rootless-state.sh"
).read_text()
SERVICE = (
    REPO
    / "overlay-root/etc/systemd/system/prepare-caddy-rootless-state.service"
).read_text()
QUADLET = (
    REPO / "overlay-root/etc/containers/systemd/users/51310/caddy.container"
).read_text()


class CaddyStatePreparationTests(unittest.TestCase):
    def test_archive_precedes_every_state_mutation(self):
        migration = SCRIPT.split("ensure_caddy_stopped\n", 1)[1]

        archive = migration.index("ensure_archive")
        root_marker = migration.index('chown root:root "${STATE_PATHS[@]}"')
        descendant_chown = migration.index(
            '-exec chown -h "${SERVICE_UID}:${SERVICE_GID}"'
        )
        restorecon = migration.index('restorecon -F -R "${STATE_PATHS[@]}"')

        self.assertLess(archive, root_marker)
        self.assertLess(archive, descendant_chown)
        self.assertLess(archive, restorecon)

    def test_archive_comparison_precedes_checksum_publication(self):
        archive = SCRIPT.split("ensure_archive() {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn(
            "compare_archive_to_original\n"
            "            write_archive_checksum",
            archive,
        )
        self.assertIn(
            "compare_archive_to_original\n"
            "    write_archive_checksum",
            archive,
        )

    def test_completion_is_published_after_full_verification(self):
        root_chown = SCRIPT.rindex(
            'chown "${SERVICE_UID}:${SERVICE_GID}" "${STATE_PATHS[@]}"'
        )
        verification = SCRIPT.rindex("verify_prepared_state")
        completion = SCRIPT.rindex(
            'install -m 0644 -o root -g root /dev/null "${MIGRATION_COMPLETE}"'
        )

        self.assertLess(root_chown, verification)
        self.assertLess(verification, completion)

    def test_mutation_guard_checks_both_stores_and_host_ports(self):
        guard = SCRIPT.split("ensure_caddy_stopped() {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn("container_is_running rootful", guard)
        self.assertIn("container_is_running rootless", guard)
        self.assertIn("ss -H -ltn", guard)
        self.assertIn("ss -H -lun", guard)
        self.assertIn(":(80|443)", guard)

    def test_one_shot_is_skipped_after_durable_completion(self):
        self.assertIn(
            "ConditionPathExists=!/var/lib/nas-migrations/"
            "caddy-rootless-ownership-v1/complete",
            SERVICE,
        )
        self.assertIn("Restart=on-failure", SERVICE)
        self.assertIn("TimeoutStartSec=infinity", SERVICE)

    def test_rootless_quadlet_guards_state_without_relabeling_it(self):
        self.assertIn(
            "ExecStartPre=/usr/bin/test -e /var/lib/nas-migrations/"
            "caddy-rootless-ownership-v1/complete",
            QUADLET,
        )
        self.assertIn(
            "ExecStartPre=/usr/bin/test -w /var/lib/caddy\n",
            QUADLET,
        )
        self.assertIn(
            "ExecStartPre=/usr/bin/test -w /var/lib/caddy-config\n",
            QUADLET,
        )
        self.assertNotIn("${path}", QUADLET)
        self.assertNotIn("ss -H", QUADLET)
        self.assertIn("Volume=/var/lib/caddy:/data\n", QUADLET)
        self.assertIn("Volume=/var/lib/caddy-config:/config\n", QUADLET)
        self.assertNotIn("Volume=/var/lib/caddy:/data:Z", QUADLET)
        self.assertNotIn("Volume=/var/lib/caddy-config:/config:Z", QUADLET)
        self.assertIn(
            "Volume=/run/nas-secrets/caddy/cf-api-token:"
            "/run/secrets/cf-api-token:ro,Z",
            QUADLET,
        )


if __name__ == "__main__":
    unittest.main()
