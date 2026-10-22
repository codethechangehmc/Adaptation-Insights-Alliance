"""Offline IFAD regressions for complete listings and document provenance."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from bs4 import BeautifulSoup

from core.searching import SearchResult
from sources import ifad

FIXTURE = Path(__file__).parent / "fixtures/ifad/activity.xml"


class IFADTests(unittest.TestCase):
    """Check activity completeness before expanding documents."""

    def setUp(self) -> None:
        """Read one trimmed activity from saved API evidence."""
        self.xml = BeautifulSoup(FIXTURE.read_text(encoding="utf-8"), "xml")
        self.activity = ifad.parse_activity(self.xml.find("iati-activity"))

    def test_all_pages_and_repeated_ids(self) -> None:
        """An overlapping or missing page is incomplete rather than silently truncated."""
        client = Mock()
        second = BeautifulSoup(str(self.xml).replace("1100000025", "1100000026"), "xml")
        client.get_xml.side_effect = [self.xml, second]
        result = ifad.fetch_activity_pages(client, {}, 2)
        self.assertFalse(result.error)
        self.assertEqual(len(result.records), 2)
        self.assertEqual(client.get_xml.call_args.kwargs["params"]["offset"], 1)
        client.get_xml.side_effect = [self.xml, self.xml]
        self.assertIn("repeated", ifad.fetch_activity_pages(client, {}, 2).error)

    def test_empty_page_and_activity_count_mismatch(self) -> None:
        """Document expansion never conceals an incomplete activity listing."""
        client = Mock()
        client.get_xml.return_value = BeautifulSoup("<iati-activities/>", "xml")
        self.assertIn("empty page", ifad.fetch_activity_pages(client, {}, 2).error)
        with patch.object(ifad, "list_activities", return_value=SearchResult([self.activity], 2)):
            self.assertTrue(ifad.run_search(client, {}).error)

    def test_relative_links_and_actual_end_date(self) -> None:
        """Resolve URLs against IFAD and preserve actual project completion dates."""
        document = self.activity["documents"][0]
        record = ifad.document_record(self.activity, document, ["KE"])
        self.assertTrue(record["pdf_url"].startswith("https://www.ifad.org/"))
        self.assertEqual(record["country"], "Kenya")
        self.assertEqual(record["project_end_date"], "1990-06-30")
        self.assertEqual(ifad.classify(record)[:2], ("drop", "other_document_type"))

    def test_document_families_precede_category(self) -> None:
        """Completion evidence survives a broad supervision category."""
        self.assertEqual(
            ifad.document_type("Project completion report", ["A06"]), "Completion Report"
        )
        self.assertEqual(ifad.document_type("Supervision report", ["A06"]), "Progress Report")
        self.assertEqual(ifad.document_type("President's report", ["A04"]), "Proposal")
        self.assertEqual(ifad.title_year("2000001156 PCR 2019"), "2019")
        self.assertEqual(ifad.title_year("2000001156 PCR"), "")


if __name__ == "__main__":
    unittest.main()
