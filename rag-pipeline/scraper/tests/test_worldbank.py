"""Tests for the World Bank source, offline, from a saved API page and a fake API."""

from __future__ import annotations

import unittest
from datetime import date, timedelta
from unittest.mock import patch

from sources import worldbank


def api_document(number: int, day: date) -> dict:
    """Return one fake API document."""
    return {
        "id": str(30000000 + number),
        "display_title": f"Kenya project {number}",
        "docdt": f"{day.isoformat()}T05:00:00Z",
        "count": "Kenya",
        "lang": "English",
    }


class FakeAPI:
    """Answers World Bank API queries from a list of documents, like the real API."""

    workers = 1

    def __init__(self, documents: list[dict]) -> None:
        """Hold the documents available to the fake API."""
        self.documents = documents
        self.calls: list[dict] = []

    def get_json(self, url: str, params: dict) -> dict:
        """Filter by the date bounds, then return one page and the total."""
        self.calls.append(params)
        start = params.get("strdate", "0000")
        end = params.get("enddate", "9999")
        matches = [doc for doc in self.documents if start <= doc["docdt"][:10] <= end]
        offset = params["os"]
        page = matches[offset : offset + params["rows"]]
        documents = {f"D{doc['id']}": doc for doc in page}
        documents["facets"] = {}
        return {"total": len(matches), "documents": documents}


class SearchTests(unittest.TestCase):
    """Planning and running searches."""

    def setUp(self) -> None:
        """Build 250 fake documents, one per day from 2016."""
        first_day = date(2016, 1, 1)
        self.documents = [api_document(n, first_day + timedelta(days=n)) for n in range(250)]
        self.search = {
            "name": "Kenya | ICR",
            "count_exact": "Kenya",
            "docty_exact": "ICR",
            "strdate": "2015-01-01",
            "enddate": "2026-10-15",
        }

    def test_capped_query_is_split_and_complete(self) -> None:
        """A total at the cap is split by date until each piece fits; nothing is lost."""
        api = FakeAPI(self.documents)
        with patch.dict(worldbank.SCOPE, {"max_results_per_query": 100}):
            result = worldbank.run_search(api, self.search)
        self.assertEqual(result.error, "")
        self.assertEqual(
            sorted(r["id"] for r in result.records), sorted(doc["id"] for doc in self.documents)
        )
        self.assertIn("split at", result.notes)


if __name__ == "__main__":
    unittest.main()
