# ABOUTME: Exercises application grouping, named endpoints, and dependency
# readiness with a production-shaped but deliberately undeployed Immich suite.

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from quadletgen.compiler import compile_fleet
from quadletgen.model import Fleet
from quadletgen.parser import load_service
from tests.quadlet_test_support import REPO, service_toml


def tap(ipv4: str, probe: str) -> str:
    return (
        "enabled = true\n"
        "cpus = 1\n"
        "ram-mib = 256\n"
        'network = "tap"\n'
        f'ipv4 = "{ipv4}"\n'
        f'probe-endpoint = "{probe}"'
    )


class ImmichApplicationModelTests(unittest.TestCase):
    def test_multi_component_application_compiles_from_named_contracts(self):
        definitions = {
            "immich-database": service_toml(
                name="immich-database",
                uid=51810,
                subid_start=518100000,
                application="immich",
                role="database",
                container='''network = "host"

[[container.endpoints]]
name = "postgres"
port = 5432
consumers = ["immich-server"]''',
                krun=tap("10.253.40.2/30", "postgres"),
            ),
            "immich-redis": service_toml(
                name="immich-redis",
                uid=51820,
                subid_start=518200000,
                application="immich",
                role="cache",
                container='''network = "host"

[[container.endpoints]]
name = "redis"
port = 6379
consumers = ["immich-server"]''',
                krun=tap("10.253.41.2/30", "redis"),
            ),
            "immich-machine-learning": service_toml(
                name="immich-machine-learning",
                uid=51830,
                subid_start=518300000,
                application="immich",
                role="machine-learning",
                container='''network = "host"

[[container.endpoints]]
name = "http"
port = 3003
consumers = ["immich-server"]''',
                krun=tap("10.253.42.2/30", "http"),
            ),
            "immich-server": service_toml(
                name="immich-server",
                uid=51840,
                subid_start=518400000,
                application="immich",
                role="server",
                container='''network = "host"

[[container.endpoints]]
name = "http"
port = 2283''',
                krun=tap("10.253.43.2/30", "http"),
                extra='''
[[storage]]
name = "state"
kind = "directory"
host-path = "/var/lib/immich-server"
mode = "0750"
subdirectories = ["data"]

[[storage.exports]]
subpath = "data"
container-path = "/usr/src/app/upload"
access = "read-write"

[[startup.dependencies]]
service = "immich-database"
endpoint = "postgres"
condition = "tcp"
timeout-sec = 120
interval-sec = 2

[[startup.dependencies]]
service = "immich-redis"
endpoint = "redis"
condition = "tcp"
timeout-sec = 120
interval-sec = 2

[[startup.dependencies]]
service = "immich-machine-learning"
endpoint = "http"
condition = "http"
path = "/ping"
timeout-sec = 120
interval-sec = 2''',
            ),
        }

        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            services = []
            for name, source in definitions.items():
                path = directory / f"{name}.toml"
                path.write_text(source)
                services.append(load_service(path))
            fleet = Fleet.build(services)
            artifacts = {
                artifact.path: artifact.content
                for artifact in compile_fleet(fleet)
            }

        self.assertEqual(
            {(service.info.application, service.info.role) for service in fleet.services},
            {
                ("immich", "database"),
                ("immich", "cache"),
                ("immich", "machine-learning"),
                ("immich", "server"),
            },
        )
        server = artifacts[
            Path("etc/containers/systemd/users/51840/immich-server.container")
        ]
        self.assertIn("marker /run/nas-storage/immich-server/ready 300 2", server)
        self.assertIn("tcp 10.253.40.2:5432 120 2", server)
        self.assertIn("tcp 10.253.41.2:6379 120 2", server)
        self.assertIn("http http://10.253.42.2:3003/ping 120 2", server)
        policy = artifacts[Path("etc/nftables/nas-krun-filter.nft")]
        self.assertIn(
            'iifname "krun-51840" oifname "krun-51810" '
            "ip saddr 10.253.43.2 ip daddr 10.253.40.2 "
            "tcp dport { 5432 } accept",
            policy,
        )


if __name__ == "__main__":
    unittest.main()
