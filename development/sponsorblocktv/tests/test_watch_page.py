import runpy
import unittest
from unittest.mock import patch, MagicMock
from pathlib import Path

helper = Path(__file__).resolve().parents[1] / "../../utils/sponsorblocktv/files/ucode/sponsorblocktv-watch-page"
ns = runpy.run_path(str(helper))
fetch = ns["fetch"]

class WatchTransportTests(unittest.TestCase):
    def test_invalid_id_never_requests(self):
        with patch("urllib.request.urlopen") as req:
            with self.assertRaises(ValueError):
                fetch("../invalid")
            req.assert_not_called()

    def test_tls_and_response_limits(self):
        with patch("ssl.create_default_context") as ctx, patch("urllib.request.urlopen") as req:
            response = req.return_value.__enter__.return_value
            response.status = 200
            response.url = "https://www.youtube.com/watch?v=abcdefghijk"
            response.read.return_value = b"fixture"
            self.assertEqual(fetch("abcdefghijk"), b"fixture")
            ctx.assert_called_once_with(cafile="/etc/ssl/certs/ca-certificates.crt")
            self.assertEqual(req.call_args.kwargs["timeout"], 5)
            response.read.assert_called_once_with(2097153)
            response.read.return_value = b"x" * 2097153
            with self.assertRaises(ValueError):
                fetch("abcdefghijk")
            response.read.return_value = b"fixture"
            response.url = "https://www.youtube.com/watch?v=lmnopqrstuv"
            with self.assertRaises(ValueError):
                fetch("abcdefghijk")
            response.url = "https://www.youtube.com/watch?v=abcdefghijk"
            response.status = 503
            with self.assertRaises(ValueError):
                fetch("abcdefghijk")

    def test_invalid_output_path(self):
        self.assertEqual(ns["main"](["helper", "abcdefghijk", "/etc/config/sponsorblocktv"]), 2)
