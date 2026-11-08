"""Offline regressions for core.fetch."""

from __future__ import annotations

import unittest
from unittest.mock import patch

import requests

from core import fetch
from core.fetch import Client
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

    def test_host_intervals_and_crawl_delay(self) -> None:
        """Fast hosts wait less by default, a given interval applies to all, Crawl-delay wins."""
        client = Client()
        client._robots.update({"slow.org": ([], 10.0)})
        with patch.object(fetch.time, "monotonic", return_value=100.0):
            for host in ["search.worldbank.org", "example.org", "slow.org"]:
                client._wait_turn(host)
        waits = {host: round(ready - 100.0, 3) for host, ready in client._next_request.items()}
        self.assertEqual(
            waits, {"search.worldbank.org": 0.1, "example.org": 0.5, "slow.org": 10.0}
        )
        self.assertEqual(Client(request_interval=2).host_intervals, {})
        with patch.object(
            requests.Session, "get", side_effect=requests.exceptions.SSLError
        ) as get:
            for _ in range(2):
                with self.assertRaises(fetch.RequestFailed):
                    client._robots_rules("https", "failed.org")
            self.assertEqual(get.call_count, 1)


if __name__ == "__main__":
    unittest.main()
