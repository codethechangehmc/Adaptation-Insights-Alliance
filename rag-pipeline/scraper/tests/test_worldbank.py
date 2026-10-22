"""Tests for the World Bank source, offline, from a saved API page and a fake API."""

from __future__ import annotations

import json
import unittest
from datetime import date, timedelta
from pathlib import Path
from unittest.mock import patch

from sources import worldbank

FIXTURE = Path(__file__).parent / "fixtures" / "worldbank" / "kenya_icr_review_page.json"


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

    def __init__(self, documents: list[dict], repeat_page: bool = False) -> None:
        """Hold the documents. With repeat_page, every offset returns the first page."""
        self.documents = documents
        self.repeat_page = repeat_page
        self.calls: list[dict] = []

    def get_json(self, url: str, params: dict) -> dict:
        """Filter by the date bounds, then return one page and the total."""
        self.calls.append(params)
        start = params.get("strdate", "0000")
        end = params.get("enddate", "9999")
        matches = [doc for doc in self.documents if start <= doc["docdt"][:10] <= end]
        offset = 0 if self.repeat_page else params["os"]
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

    def test_pagination_reaches_the_last_page(self) -> None:
        """250 records over pages of 100 are all fetched, in three requests."""
        api = FakeAPI(self.documents)
        result = worldbank.run_search(api, self.search)
        self.assertEqual((len(result.records), result.expected, result.error), (250, 250, ""))
        self.assertEqual([call["os"] for call in api.calls], [0, 100, 200])

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

    def test_cap_on_a_single_day_is_incomplete(self) -> None:
        """When one day alone reaches the cap, the search is reported incomplete."""
        same_day = [api_document(n, date(2020, 1, 1)) for n in range(5)]
        with patch.dict(worldbank.SCOPE, {"max_results_per_query": 3}):
            result = worldbank.run_search(FakeAPI(same_day), self.search)
        self.assertIn("reach the cap", result.error)

    def test_repeated_page_is_incomplete(self) -> None:
        """A site that serves the same page twice gives an incomplete search."""
        result = worldbank.run_search(FakeAPI(self.documents, repeat_page=True), self.search)
        self.assertIn("repeated while paging", result.error)


class RecordTests(unittest.TestCase):
    """Normalising and classifying records."""

    def setUp(self) -> None:
        """Load the saved Kenya ICR Review page."""
        payload = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.records = worldbank.page_records(payload)
        self.record = dict(self.records[0], abstract="", topics="")

    def test_abstract_keyword_is_to_screen(self) -> None:
        """An abstract-only keyword parks the record for screening."""
        self.record.update(title="Kenya - Roads Project", abstract="Farmers reached markets.")
        self.assertEqual(
            worldbank.classify(self.record)[:2], ("to_screen", "abstract_keywords_only")
        )

    def test_policy_lending_is_dropped(self) -> None:
        """Development policy lending is dropped by title."""
        self.record["title"] = "Kenya - Agriculture Development Policy Operation"
        self.assertEqual(worldbank.classify(self.record)[1], "policy_or_budget_support")

    def test_papua_new_guinea_is_not_african(self) -> None:
        """Document 33757973's country, Papua New Guinea, is not read as Guinea."""
        self.record.update(country="Papua New Guinea", title="Agriculture project")
        self.assertEqual(worldbank.classify(self.record)[1], "no_african_country")


if __name__ == "__main__":
    unittest.main()
