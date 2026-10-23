"""Offline regressions for CPR enumeration and Adaptation Fund documents."""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path
from unittest.mock import Mock

from core.fetch import RequestFailed
from sources import af, cpr

FIXTURES = Path(__file__).parent / "fixtures" / "af"


class AdaptationFundTests(unittest.TestCase):
    """Exercise the observed family and search response shapes."""

    def setUp(self) -> None:
        """Load trimmed source responses."""
        self.family = json.loads((FIXTURES / "family.json").read_text(encoding="utf8"))["data"]
        self.page = json.loads((FIXTURES / "page.json").read_text(encoding="utf8"))

    def test_pagination_reaches_last_family(self) -> None:
        """Numbered pages account for the exact reported total."""
        final = copy.deepcopy(self.page["results"][0])
        final["id"] = "AF.family.last.0"
        client = Mock(workers=1)
        client.get_json.side_effect = [self.page, {"total_size": 3, "results": [final]}]
        result = cpr.list_families(client, "agent::Adaptation Fund")
        self.assertEqual(len(result.records), 3)
        self.assertEqual(result.error, "")
        self.assertEqual(client.get_json.call_args.kwargs["params"]["page_token"], 2)

    def test_capped_or_repeated_page_is_incomplete(self) -> None:
        """An endpoint repeating its first page cannot appear complete."""
        client = Mock(workers=1)
        client.get_json.side_effect = [self.page, self.page]
        self.assertIn("repeated", cpr.list_families(client, "fund").error)

    def test_search_preserves_country_separate_from_mena_region(self) -> None:
        """Raw API labels cannot turn a Pakistan family into African evidence."""
        family = copy.deepcopy(self.family)
        family["import_id"] = "AF.family.006MPKDR.0"
        # Label shape returned by the live API on 2026-10-22.
        hit = {
            "id": family["import_id"],
            "labels": [
                {
                    "type": "geography",
                    "value": {"type": "region", "value": "Middle East & North Africa"},
                },
                {"type": "geography", "value": {"type": "country", "value": "Pakistan"}},
            ],
        }
        client = Mock(workers=1)
        client.get_json.side_effect = [{"total_size": 1, "results": [hit]}, {"data": family}]
        result = cpr.run_search(client, "af", "agent::Adaptation Fund", "AF.")
        self.assertEqual(result.records[0]["country"], "Pakistan")
        self.assertIn("North Africa", result.records[0]["region_labels"])
        self.assertEqual(af.classify(result.records[2])[1], "no_african_country")

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
