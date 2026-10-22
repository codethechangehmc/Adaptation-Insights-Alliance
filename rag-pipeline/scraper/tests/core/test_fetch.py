"""Offline regressions for core.fetch."""

from __future__ import annotations

import unittest
from unittest.mock import patch

import requests

from core import fetch
from core.fetch import Client, RequestFailed
from tests.core.support import (
    response,
)


class FetchTests(unittest.TestCase):
    """robots.txt rules and retries."""

    def test_retry_after_is_honoured(self) -> None:
        """A 429 with Retry-After is retried after at least that pause."""
        busy, ready = response(429, {"Retry-After": "2"}), response(200)
        client = Client(request_interval=0, attempts=2)
        client._robots["example.org"] = ([], 0.0)
        pauses = []
        with (
            patch.object(requests.Session, "request", side_effect=[busy, ready]),
            patch.object(
                client, "_pause_host", side_effect=lambda host, delay: pauses.append(delay)
            ),
            self.assertLogs("scraper", level="WARNING"),
        ):
            self.assertIs(client.get("https://example.org/a"), ready)
        self.assertGreaterEqual(pauses[0], 2)

    def test_not_found_is_not_retried(self) -> None:
        """A 404 fails at once."""
        missing = response(404)
        client = Client(request_interval=0, attempts=3)
        client._robots["example.org"] = ([], 0.0)
        with patch.object(requests.Session, "request", return_value=missing) as sent:
            self.assertRaises(RequestFailed, client.get, "https://example.org/a")
        self.assertEqual(sent.call_count, 1)

    def test_redirect_checks_destination_robots(self) -> None:
        """A permitted landing page cannot redirect into a disallowed download."""
        client = Client(request_interval=0)
        client._robots.update({"example.org": ([], 0.0), "files.org": ([(False, "/")], 0.0)})
        redirect = response(302, {"Location": "https://files.org/report.pdf"})
        with patch.object(requests.Session, "request", return_value=redirect) as sent:
            self.assertRaises(fetch.BlockedByRobots, client.get, "https://example.org/report")
        self.assertEqual(sent.call_count, 1)

    def test_access_denied_stops_later_requests_to_host(self) -> None:
        """An explicit access block stops other jobs instead of probing new paths."""
        client = Client(request_interval=0)
        client._robots["example.org"] = ([], 0.0)
        with patch.object(requests.Session, "request", return_value=response(403)) as sent:
            self.assertRaises(RequestFailed, client.get, "https://example.org/one")
            self.assertRaises(RequestFailed, client.get, "https://example.org/two")
        self.assertEqual(sent.call_count, 1)


if __name__ == "__main__":
    unittest.main()
