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

    def test_repeated_page_marks_search_incomplete(self) -> None:
        """Repeated IDs cannot masquerade as later listing pages."""
        listing = page("listing.html")
        listing.append(
            BeautifulSoup('<li class="pager-last"><a href="?page=1">Last</a></li>', "lxml")
        )
        client = Mock()
        client.get_html.return_value = listing
        self.assertIn("repeated", afdb.enumerate_listing(client, afdb.BASE, "afdb", {}).error)

    def test_viewer_and_file_field_pdf_resolution(self) -> None:
        """AfDB viewer and IDEV file field both expose their direct PDFs."""
        for filename in ["detail.html", "idev_detail.html"]:
            client = Mock()
            client.get_html.return_value = page(filename)
            urls = afdb.resolve_pdf_urls(client, {"web_url": afdb.BASE + "/document/x"})
            self.assertEqual(len(urls), 1)
            self.assertTrue(urls[0].endswith(".pdf"))


if __name__ == "__main__":
    unittest.main()
