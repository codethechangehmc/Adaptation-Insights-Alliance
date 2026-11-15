"""Offline regressions for CPR enumeration and Adaptation Fund documents."""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest.mock import Mock

from core.fetch import RequestFailed
from sources import cpr

FIXTURES = Path(__file__).parent / "fixtures" / "af"


class AdaptationFundTests(unittest.TestCase):
    """Exercise the observed family and search response shapes."""

    def setUp(self) -> None:
        """Load trimmed source responses."""
        self.family = json.loads((FIXTURES / "family.json").read_text(encoding="utf8"))["data"]

    def test_gone_family_preserves_partial_evidence_and_marks_incomplete(self) -> None:
        """An indexed 410 family cannot erase retrieved documents or count as complete."""
        hits = [{"id": self.family["import_id"]}, {"id": "AF.family.gone.0"}]
        client = Mock(workers=1)
        client.get_json.side_effect = [
            {"total_size": 2, "results": hits},
            {"data": self.family},
            RequestFailed("https://example.org/gone", "HTTP 410", 410),
        ]
        result = cpr.run_search(client, "af", "fund", "AF.")
        self.assertEqual(len(result.records), len(self.family["documents"]))
        self.assertIn("410", result.error)


if __name__ == "__main__":
    unittest.main()
