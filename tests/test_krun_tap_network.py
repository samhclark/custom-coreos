# ABOUTME: Regression tests for the generated libkrun TAP network data plane.

import importlib.util
import shutil
import subprocess
import tomllib
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "generate_quadlets", REPO / "generate-quadlets.py"
)
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)
PATCH = (
    REPO / "patches/crun/0001-krun-add-tap-network-annotation.patch"
).read_text()
FILTER = (
    REPO / "overlay-root/etc/nftables/nas-krun-filter.nft"
).read_text()
NAT = (REPO / "overlay-root/etc/nftables/nas-krun-nat.nft").read_text()
POLICY_SCRIPT = (
    REPO / "overlay-root/usr/local/bin/nas-krun-network-policy.sh"
).read_text()
POLICY_UNIT = (
    REPO / "overlay-root/etc/systemd/system/nas-krun-network-policy.service"
).read_text()
NFTABLES_DROPIN = (
    REPO
    / "overlay-root/etc/systemd/system/nftables.service.d/10-nas-krun-policy.conf"
).read_text()


class KrunTapNetworkTests(unittest.TestCase):
    def load_configs(self):
        return [
            GENERATOR.load_service(path)
            for path in sorted((REPO / "quadlets").glob("*.toml"))
        ]

    def test_every_generated_microvm_uses_a_unique_tap_and_subnet(self):
        configs = self.load_configs()
        GENERATOR.validate_fleet(configs)

        taps = set()
        subnets = set()
        for cfg in configs:
            self.assertEqual(cfg["container"]["network"], "host")
            self.assertEqual(cfg["krun"]["network"], "tap")
            taps.add(GENERATOR.tap_name(cfg))
            subnets.add(GENERATOR.tap_guest(cfg).network)

        self.assertEqual(len(taps), len(configs))
        self.assertEqual(len(subnets), len(configs))

    def test_tap_quadlets_do_not_ask_podman_to_proxy_ports(self):
        for path in (REPO / "overlay-root/etc/containers/systemd/users").glob(
            "*/*.container"
        ):
            unit = path.read_text()
            self.assertIn("Annotation=krun.tap_name=", unit)
            self.assertIn("Network=host", unit)
            self.assertIn("AddDevice=/dev/net/tun", unit)
            self.assertNotIn("PublishPort=", unit)
            self.assertNotIn("Annotation=krun.use_passt", unit)
            self.assertIn("/run/nas-krun-network/policy-ready", unit)
            self.assertIn("ExecStartPost=/usr/bin/bash", unit)
            self.assertIn("/dev/tcp/", unit)

    def test_policy_failure_cannot_leave_tap_guests_running(self):
        self.assertIn(
            "BindsTo=nftables.service systemd-networkd.service", POLICY_UNIT
        )
        self.assertIn(
            "PartOf=nftables.service systemd-networkd.service", POLICY_UNIT
        )
        self.assertIn(
            "ExecStop=/usr/local/bin/nas-krun-network-policy.sh quiesce",
            POLICY_UNIT,
        )
        self.assertIn("rm -f \"${READY_FILE}\"", POLICY_SCRIPT)
        self.assertIn('systemctl stop "${USER_UNITS[@]}"', POLICY_SCRIPT)
        self.assertIn("nft list chain inet filter nas_krun_input", POLICY_SCRIPT)
        self.assertIn("systemd-networkd-wait-online", POLICY_SCRIPT)
        self.assertIn("ExecStop=\n", NFTABLES_DROPIN)
        self.assertIn("quiesce-and-flush", NFTABLES_DROPIN)
        self.assertLess(
            POLICY_SCRIPT.index('systemctl stop "${USER_UNITS[@]}"'),
            POLICY_SCRIPT.index("nft flush ruleset"),
        )

    def test_networkd_grants_tap_to_service_and_enables_vnet_headers(self):
        config = (
            REPO / "overlay-root/usr/lib/systemd/network/80-krun-51120.netdev"
        ).read_text()
        network = (
            REPO / "overlay-root/usr/lib/systemd/network/80-krun-51120.network"
        ).read_text()

        self.assertIn("User=_nas_jellyfin", config)
        self.assertIn("Group=_nas_jellyfin", config)
        self.assertIn("VNetHeader=yes", config)
        self.assertNotIn("KeepCarrier=yes", config)
        self.assertIn("Address=10.253.2.1/30", network)
        self.assertIn("PoolOffset=2", network)
        self.assertIn("PoolSize=1", network)
        self.assertIn("PersistLeases=runtime", network)
        self.assertIn("RapidCommit=yes", network)
        self.assertIn("IPv4RouteLocalnet=yes", network)

    def test_networkd_waits_for_tap_owner_accounts(self):
        ordering = (
            REPO
            / "overlay-root/etc/systemd/system/systemd-networkd.service.d/10-nas-krun-accounts.conf"
        ).read_text()
        for cfg in self.load_configs():
            self.assertIn(
                f"ensure-nas-{cfg['_slug']}-account.service",
                ordering,
            )

    def test_nft_policy_has_antispoof_edges_publication_and_nat(self):
        self.assertIn(
            'iifname "krun-51120" ip saddr != 10.253.2.2 drop', FILTER
        )
        self.assertIn(
            'iifname "krun-51310" oifname "krun-51120" '
            "ip saddr 10.253.9.2 ip daddr 10.253.2.2 tcp dport { 8096 } accept",
            FILTER,
        )
        self.assertIn("tcp dport 443 dnat to 10.253.9.2:443", NAT)
        self.assertIn(
            "ip daddr 127.0.0.1 tcp dport 8096 dnat to 10.253.2.2:8096",
            NAT,
        )
        self.assertIn("ip saddr 10.253.2.2", NAT)
        self.assertIn("masquerade", NAT)
        self.assertIn(
            "ip saddr 10.253.7.2 ip daddr 10.253.7.1 tcp dport 9100 accept",
            FILTER,
        )
        self.assertIn(
            'oifname "krun-51120" ip saddr 127.0.0.0/8 '
            "ip daddr 10.253.2.2 snat to 10.253.2.1",
            NAT,
        )
        self.assertIn(
            'iifname "krun-51230" oifname "krun-51110" '
            "ip saddr 10.253.5.2 ip daddr 10.253.1.2 tcp dport { 3903 } accept",
            FILTER,
        )

    def test_loopback_dnat_has_a_real_return_path(self):
        required = ("unshare", "ip", "nsenter", "nft", "curl", "python3")
        missing = [command for command in required if shutil.which(command) is None]
        if missing:
            self.skipTest(f"network namespace tools unavailable: {', '.join(missing)}")

        preflight = subprocess.run(
            ["unshare", "--user", "--map-root-user", "--net", "true"],
            capture_output=True,
            text=True,
        )
        if preflight.returncode:
            self.skipTest(
                "unprivileged network namespaces unavailable: "
                + preflight.stderr.strip()
            )

        script = r'''
ip link set lo up
unshare --net sleep 30 &
guest_pid=$!
server_pid=
cleanup() {
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    kill "$guest_pid" 2>/dev/null || true
}
trap cleanup EXIT

ip link add krun-test type veth peer name eth0
ip link set eth0 netns "$guest_pid"
ip addr add 10.254.254.1/30 dev krun-test
ip link set krun-test up
nsenter -t "$guest_pid" -n ip link set lo up
nsenter -t "$guest_pid" -n ip addr add 10.254.254.2/30 dev eth0
nsenter -t "$guest_pid" -n ip link set eth0 up
nsenter -t "$guest_pid" -n ip route add default via 10.254.254.1
sysctl -q -w net.ipv4.conf.krun-test.route_localnet=1

nft -f - <<'EOF'
table ip test_nat {
    chain output {
        type nat hook output priority dstnat; policy accept;
        ip daddr 127.0.0.1 tcp dport 18096 dnat to 10.254.254.2:8096
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "krun-test" ip saddr 127.0.0.0/8 ip daddr 10.254.254.2 snat to 10.254.254.1
    }
}
EOF

nsenter -t "$guest_pid" -n python3 -m http.server 8096 --bind 10.254.254.2 \
    >/dev/null 2>&1 &
server_pid=$!
for _ in 1 2 3 4 5; do
    curl -fsS --max-time 2 http://127.0.0.1:18096/ >/dev/null && exit 0
    sleep 0.2
done
exit 1
'''
        result = subprocess.run(
            [
                "unshare",
                "--user",
                "--map-root-user",
                "--net",
                "--mount",
                "--fork",
                "bash",
                "-ceu",
                script,
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_crun_patch_calls_libkrun_tap_with_dhcp(self):
        self.assertIn('find_annotation (container, "krun.tap_name")', PATCH)
        self.assertIn('dlsym (handle, "krun_add_net_tap")', PATCH)
        self.assertIn("COMPAT_NET_FEATURES, NET_FLAG_DHCP_CLIENT", PATCH)
        self.assertIn("krun.tap_name and krun.use_passt are mutually exclusive", PATCH)


if __name__ == "__main__":
    unittest.main()
