"""Offline current GCF fragment and document regressions."""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest.mock import Mock

from sources import gcf

FIXTURES = Path(__file__).parent / "fixtures" / "gcf"


class GcfTests(unittest.TestCase):
    """Check current fragments rather than removed Drupal AJAX responses."""

    def setUp(self) -> None:
        """Read the observed card responses."""
        self.projects = json.loads((FIXTURES / "projects.json").read_text(encoding="utf8"))

    def test_pagination_checks_terminal_empty_page(self) -> None:
        """A complete listing reads beyond the final nonempty page."""
        self.projects["pager_html"] = ""
        client = Mock()
        client.get_json.side_effect = [self.projects, {"results_html": "", "pager_html": ""}]
        self.assertEqual(len(gcf.fragment_pages(client, "projects", {})), 1)
        self.assertEqual(client.get_json.call_args.kwargs["params"]["page"], 1)


if __name__ == "__main__":
    unittest.main()
