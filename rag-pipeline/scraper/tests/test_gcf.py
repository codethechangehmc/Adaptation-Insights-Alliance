"""Offline current GCF fragment and document regressions."""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest.mock import Mock

from bs4 import BeautifulSoup

from sources import gcf

FIXTURES = Path(__file__).parent / "fixtures" / "gcf"


class GcfTests(unittest.TestCase):
    """Check current fragments rather than removed Drupal AJAX responses."""

    def setUp(self) -> None:
        """Read the observed card responses."""
        self.projects = json.loads((FIXTURES / "projects.json").read_text(encoding="utf8"))
        self.documents = json.loads((FIXTURES / "documents.json").read_text(encoding="utf8"))

    def test_pagination_checks_terminal_empty_page(self) -> None:
        """A complete listing reads beyond the final nonempty page."""
        self.projects["pager_html"] = ""
        client = Mock()
        client.get_json.side_effect = [self.projects, {"results_html": "", "pager_html": ""}]
        self.assertEqual(len(gcf.fragment_pages(client, "projects", {})), 1)
        self.assertEqual(client.get_json.call_args.kwargs["params"]["page"], 1)

    def test_repeated_page_is_incomplete(self) -> None:
        """An endpoint ignoring page cannot silently truncate the listing."""
        client = Mock()
        client.get_json.return_value = self.projects
        with self.assertRaisesRegex(ValueError, "repeated"):
            gcf.fragment_pages(client, "projects", {})

    def test_under_implementation_final_evaluation_and_date(self) -> None:
        """FP049 final evaluation has its document date, independent of status."""
        projects = {
            "FP049": {
                "project_title": "Building climate resilience of farmers",
                "country": "Senegal",
            }
        }
        page = BeautifulSoup(self.documents["results_html"], "lxml")
        rows = gcf.document_records([page], projects)
        self.assertEqual(rows[0]["doc_date"], "2025-06-30")
        self.assertIn("final-evaluation-report-fp049", rows[0]["id"])
        self.assertEqual(gcf.classify(rows[0])[0], "in_scope")
        self.assertEqual(gcf.classify(rows[2])[:2], ("drop", "proposal_stage"))


if __name__ == "__main__":
    unittest.main()
