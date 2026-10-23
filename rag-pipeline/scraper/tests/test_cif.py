"""Offline CIF index, pagination and family-selection regressions."""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path
from unittest.mock import Mock

from sources import cif

FIXTURES = Path(__file__).parent / "fixtures" / "cif"


class CifTests(unittest.TestCase):
    """Check complete offset enumeration and substantive evaluation selection."""

    def setUp(self) -> None:
        """Load a trimmed live index response."""
        self.payload = json.loads((FIXTURES / "documents.json").read_text(encoding="utf8"))
        self.payload["count"] = 3

    def test_pagination_reaches_reported_total(self) -> None:
        """The next request starts after the rows actually returned."""
        final = copy.deepcopy(self.payload["data"][0])
        final["_id"]["nid"] = "last"
        final["data"][0]["nid"] = "last"
        client = Mock()
        client.post.side_effect = [
            Mock(json=Mock(return_value=self.payload)),
            Mock(json=Mock(return_value={"count": 3, "data": [final]})),
        ]
        result = cif.run_search(client, {"content_type": "documents"})
        self.assertEqual(result.error, "")
        self.assertEqual(len(result.records), 3)
        self.assertEqual(client.post.call_args.kwargs["data"]["s"], 2)

    def test_repeated_capped_page_is_incomplete(self) -> None:
        """An ignored offset is reported rather than silently truncated."""
        client = Mock()
        client.post.return_value.json.return_value = self.payload
        self.assertIn("repeated", cif.run_search(client, {"content_type": "documents"}).error)

    def test_proposals_and_framework_are_dropped(self) -> None:
        """Known evaluation-title false positives retain their actual node IDs."""
        rows = json.loads((FIXTURES / "admin_records.json").read_text(encoding="utf8"))
        self.assertTrue(
            {"8543", "6159", "7372", "17072", "24703"}.issubset({row["id"] for row in rows})
        )
        for row in rows:
            with self.subTest(id=row["id"]):
                self.assertEqual(cif.classify(row)[0], "drop")


if __name__ == "__main__":
    unittest.main()
