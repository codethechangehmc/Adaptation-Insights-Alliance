"""Offline AfDB and IDEV listing, taxonomy and PDF regressions."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import Mock

from bs4 import BeautifulSoup

from sources import afdb

FIXTURES = Path(__file__).parent / "fixtures" / "afdb"


def page(name: str) -> BeautifulSoup:
    """Read a trimmed observed HTML response."""
    return BeautifulSoup((FIXTURES / name).read_text(encoding="utf8"), "lxml")


class AfdbTests(unittest.TestCase):
    """Verify metadata and current PDF viewer behavior."""

    def test_view_rows_and_repeated_page_positions(self) -> None:
        """Count duplicate view rows, retry wrong positions, and reject repeated ranges."""
        listing = page("listing.html")
        listing.body.append(
            BeautifulSoup(
                '<div class="view-header">Displaying 1 - 1 of 2</div>'
                '<li class="pager-last"><a href="?page=1">Last</a></li>',
                "html.parser",
            )
        )
        client = Mock()
        client.get_html.return_value = listing
        self.assertIn("repeated", afdb.enumerate_listing(client, afdb.BASE, "afdb", {}).error)
        recovered = BeautifulSoup(
            str(listing).replace("sudan-", "kenya-").replace("1 - 1", "2 - 2"), "lxml"
        )
        client.get_html.side_effect = [listing, listing, recovered]
        result = afdb.enumerate_listing(client, afdb.BASE, "afdb", {})
        self.assertFalse(result.error)
        self.assertEqual(len(result.records), 2)
        client.get_html.side_effect = [
            BeautifulSoup(
                str(listing)
                .replace("1 - 1", f"{i} - {i}")
                .replace("of 2", "of 3")
                .replace("/en/documents/", "/en/legacy/"),
                "lxml",
            )
            for i in range(1, 4)
        ]
        result = afdb.enumerate_listing(client, afdb.BASE, "afdb", {})
        self.assertFalse(result.error)
        self.assertEqual(len(result.records), 1)
        self.assertEqual(result.pages, 3)


if __name__ == "__main__":
    unittest.main()
