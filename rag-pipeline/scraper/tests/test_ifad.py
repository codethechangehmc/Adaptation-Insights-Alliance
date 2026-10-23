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

    def test_copy_filed_under_another_project_and_garbled_accents(self) -> None:
        """Wrong-activity copies and audit reports are dropped; garbled accents are repaired."""
        # Seen on 2026-10-22: Paraguay 1100001750 listed under Madagascar 1100001516.
        record = {
            "title": "Paraguay 1100001750: PROMAFI Project Completion Report",
            "project_id": "1100001516",
            "country": "Madagascar",
            "doc_type": "Completion Report",
        }
        self.assertEqual(ifad.classify(record)[:2], ("drop", "filed_under_other_project"))
        self.assertEqual(ifad.document_type("2020-Ministry of Finance-AUDIT_REPORT", []), "Audit")
        self.assertEqual(ifad.repair_text("CÃ´te d'Ivoire"), "Côte d'Ivoire")
        self.assertEqual(ifad.repair_text("Côte d'Ivoire"), "Côte d'Ivoire")


if __name__ == "__main__":
    unittest.main()
