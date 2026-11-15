"""Offline IFAD regressions for complete listings and document provenance."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import Mock

from bs4 import BeautifulSoup

from sources import ifad

FIXTURE = Path(__file__).parent / "fixtures/ifad/activity.xml"


class IFADTests(unittest.TestCase):
    """Check activity completeness before expanding documents."""

    def setUp(self) -> None:
        """Read one trimmed activity from saved API evidence."""
        self.xml = BeautifulSoup(FIXTURE.read_text(encoding="utf-8"), "xml")

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
        saved = {
            "title": "Project page",
            "pdf_url": "/w/projects/1027",
            "categories": "A12",
            "country": "Kenya",
        }
        ifad.prepare_record(saved)
        self.assertEqual(saved["pdf_url"], "https://www.ifad.org/w/projects/1027")
        self.assertEqual(ifad.classify(saved)[:2], ("drop", "other_document_type"))


if __name__ == "__main__":
    unittest.main()
