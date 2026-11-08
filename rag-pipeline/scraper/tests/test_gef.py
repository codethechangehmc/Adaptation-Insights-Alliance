"""Offline GEF regressions from saved listing HTML and minimal document pages."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import Mock

from bs4 import BeautifulSoup

from sources import gef

FIXTURE = Path(__file__).parent / "fixtures/gef/listing.html"


class GEFTests(unittest.TestCase):
    """Check four-sweep coverage and honest incomplete results."""

    def setUp(self) -> None:
        """Read a trimmed saved GEF database row."""
        self.page = BeautifulSoup(FIXTURE.read_text(encoding="utf-8"), "lxml")

    def test_listing_count_and_missing_total(self) -> None:
        """A listing without a trustworthy total is incomplete."""
        client = Mock(spec=["get_html"])
        client.get_html.return_value = self.page
        result = gef.list_projects(client, {"facet": "focal_areas:2207"})
        self.assertFalse(result.error)
        self.assertEqual(result.records[0]["id"], "12372")
        client.get_html.return_value = BeautifulSoup("<html>Blocked</html>", "lxml")
        self.assertTrue(gef.list_projects(client, {"facet": "focal_areas:2207"}).error)


if __name__ == "__main__":
    unittest.main()
