# ABOUTME: Regression tests for Jellyfin's Caddy route and blackbox-based
# availability monitoring.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CADDYFILE = (
    REPO / "overlay-root/usr/share/custom-coreos/caddy/Caddyfile"
).read_text()
SCRAPE_CONFIG = (
    REPO
    / "overlay-root/usr/share/custom-coreos/victoria-metrics/promscrape.yml"
).read_text()
ALERT_RULES = (
    REPO / "overlay-root/usr/share/custom-coreos/vmalert/alert-rules.yml"
).read_text()


class JellyfinIntegrationTests(unittest.TestCase):
    def test_caddy_routes_selected_hostname_to_loopback_only_service(self):
        self.assertIn(
            "jellyfin.i.samhclark.com {\n"
            "\treverse_proxy 127.0.0.1:8096\n"
            "}",
            CADDYFILE,
        )

    def test_victoria_metrics_probes_jellyfin_health_via_blackbox(self):
        self.assertIn("job_name: 'jellyfin-health'", SCRAPE_CONFIG)
        self.assertIn(
            "targets: ['http://127.0.0.1:8096/health']",
            SCRAPE_CONFIG,
        )
        self.assertIn("replacement: 127.0.0.1:9115", SCRAPE_CONFIG)

    def test_alerts_distinguish_service_failure_from_probe_failure(self):
        self.assertIn("alert: JellyfinHealthDown", ALERT_RULES)
        self.assertIn(
            'probe_success{job="jellyfin-health",service="jellyfin"} == 0',
            ALERT_RULES,
        )
        self.assertIn("alert: JellyfinHealthProbeBroken", ALERT_RULES)
        self.assertIn('up{job="jellyfin-health"} == 0', ALERT_RULES)


if __name__ == "__main__":
    unittest.main()
