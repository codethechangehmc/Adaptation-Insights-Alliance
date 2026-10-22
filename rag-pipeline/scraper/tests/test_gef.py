"""Offline GEF regressions from saved listing HTML and minimal document pages."""

from __future__ import annotations

import unittest
from datetime import date
from pathlib import Path
from unittest.mock import Mock, patch

from bs4 import BeautifulSoup

from core import classification
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

    def test_repeated_listing_page_is_incomplete(self) -> None:
        """Do not mistake a repeated last page for successful pagination."""
        client = Mock(spec=["get_html"])
        client.get_html.return_value = BeautifulSoup(
            str(self.page).replace("of 1", "of 2"), "lxml"
        )
        self.assertIn("Repeated", gef.list_projects(client, {"facet": "x"}).error)

    def test_document_family_dates_and_non_pdf(self) -> None:
        """Keep recovered years by stable ID and retain Word evaluations for download."""
        project = {
            "id": "1",
            "web_url": gef.SITE,
            "project_title": "Kenya farming",
            "country": "Kenya",
            "project_type": "Full-size Project",
        }
        page = BeautifulSoup(
            '<a href="/TE/report.pdf">Terminal evaluation</a>'
            '<a href="/report.docx">Mid-term review</a>',
            "lxml",
        )
        records = gef.project_documents(page, project)
        with patch.dict(gef.DOCUMENT_DATES, {records[0]["id"]: "2020"}, clear=True):
            gef.prepare_record(records[0])
        self.assertEqual(records[0]["doc_date"], "2020")
        self.assertEqual(gef.pdf_urls(records[1]), [gef.SITE + "/report.docx"])
        self.assertEqual(
            gef.classify({**records[0], "doc_type": "Project Implementation Report"})[:2],
            ("drop", "progress_report"),
        )

    def test_stored_source_families_use_canonical_rules(self) -> None:
        """Raw CEO, PIR and TE labels keep their families and original provenance."""
        for label, canonical, expected in [
            ("CEO Endorsement", "Proposal", ("drop", "proposal_stage")),
            ("PIR", "Project Implementation Report", ("drop", "progress_report")),
            ("TE", "Terminal Evaluation", ("in_scope", "agriculture_or_adaptation_evidence")),
        ]:
            with self.subTest(label=label):
                record = {
                    "id": "1",
                    "title": "Farming project",
                    "doc_type": label,
                    "doc_date": "2020",
                    "country": "Kenya",
                    "project_title": "Farming project",
                }
                decision = classification.decide(gef, record, date(2015, 1, 1), date(2026, 10, 22))
                self.assertEqual(decision[:2], expected)
                self.assertEqual(record["doc_type"], canonical)
                self.assertEqual(record["source_doc_type"], label)


if __name__ == "__main__":
    unittest.main()
