# ABOUTME: Behaviorally tests the fixed host-side startup policy helpers.

from __future__ import annotations

import http.server
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
WAIT = REPO / "overlay-root/usr/local/bin/nas-wait-for-readiness.sh"
PORTS = REPO / "overlay-root/usr/local/bin/nas-assert-tcp-ports-free.sh"


class QuietHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, format, *args):
        pass


class StartupHelperTests(unittest.TestCase):
    def test_marker_requires_both_token_and_exact_mount_source(self):
        with tempfile.TemporaryDirectory(dir=REPO) as directory_name:
            directory = Path(directory_name)
            marker = directory / "ready"
            marker.touch()
            source = subprocess.run(
                ["/usr/bin/findmnt", "-rn", "-o", "SOURCE", "-T", directory],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            ready = subprocess.run(
                [WAIT, "marker", marker, "1", "1", f"{directory}={source}"],
                capture_output=True,
                text=True,
                timeout=3,
            )
            wrong_mount = subprocess.run(
                [WAIT, "marker", marker, "1", "1", f"{directory}=wrong"],
                capture_output=True,
                text=True,
                timeout=3,
            )

        self.assertEqual(ready.returncode, 0, ready.stderr)
        self.assertEqual(wrong_mount.returncode, 1)
        self.assertIn("was not ready within 1 seconds", wrong_mount.stderr)

    def test_http_readiness_uses_a_real_bounded_request(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run(
                [
                    WAIT,
                    "http",
                    f"http://127.0.0.1:{server.server_port}/healthy",
                    "2",
                    "1",
                ],
                capture_output=True,
                text=True,
                timeout=3,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tcp_port_check_detects_and_releases_listener(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        busy = subprocess.run(
            [PORTS, str(port)],
            capture_output=True,
            text=True,
            timeout=3,
        )
        listener.close()
        free = subprocess.run(
            [PORTS, str(port)],
            capture_output=True,
            text=True,
            timeout=3,
        )

        self.assertEqual(busy.returncode, 1)
        self.assertIn(f"host TCP port {port}", busy.stderr)
        self.assertEqual(free.returncode, 0, free.stderr)


if __name__ == "__main__":
    unittest.main()
