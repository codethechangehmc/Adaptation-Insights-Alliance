"""Offline AfDB and IDEV listing, taxonomy and PDF regressions."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import Mock

from bs4 import BeautifulSoup

from core.fetch import RequestFailed
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

    def test_final_page_stops_without_extra_requests(self) -> None:
        """A one-page listing finishes at the actual pager boundary."""
        client = Mock()
        client.get_html.return_value = page("listing.html")
        result = afdb.enumerate_listing(client, afdb.BASE, "afdb", {})
        self.assertEqual(result.error, "")
        self.assertEqual(client.get_html.call_count, 1)

    def test_request_failure_preserves_partial_listing(self) -> None:
        """A later DNS failure retains retrieved records while marking incomplete."""
        listing = page("listing.html")
        listing.append(
            BeautifulSoup('<li class="pager-last"><a href="?page=1">Last</a></li>', "lxml")
        )
        client = Mock()
        client.get_html.side_effect = [listing, RequestFailed(afdb.BASE, "DNS failure")]
        result = afdb.enumerate_listing(client, afdb.BASE, "afdb", {})
        self.assertEqual(len(result.records), 1)
        self.assertIn("DNS failure", result.error)

    def test_viewer_and_file_field_pdf_resolution(self) -> None:
        """AfDB viewer and IDEV file field both expose their direct PDFs."""
        for filename in ["detail.html", "idev_detail.html"]:
            client = Mock()
            client.get_html.return_value = page(filename)
            urls = afdb.resolve_pdf_urls(client, {"web_url": afdb.BASE + "/document/x"})
            self.assertEqual(len(urls), 1)
            self.assertTrue(urls[0].endswith(".pdf"))

    def test_governance_and_proposals_are_dropped(self) -> None:
        """An evaluation category does not override explicit excluded families."""
        self.assertEqual(afdb.classify({"title": "Agriculture appraisal report"})[0], "drop")
        self.assertEqual(
            afdb.classify({"title": "Fiscal Sustainability completion report"})[1],
            "policy_or_budget_support",
        )
        self.assertEqual(
            afdb.classify({"title": "Agricultural evaluation", "country": "Japan"})[1],
            "no_african_country",
        )


if __name__ == "__main__":
    unittest.main()
