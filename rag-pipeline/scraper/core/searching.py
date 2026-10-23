"""Searches: the result shape every source returns, and running all searches of a run."""

from __future__ import annotations

import json
import logging
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

from core import storage
from core.fetch import Client

LOG = logging.getLogger("scraper")

SEARCH_FIELDS = [
    "search_id",
    "name",
    "query",
    "expected",
    "retrieved",
    "pages",
    "complete",
    "error",
    "notes",
    "seconds",
]


@dataclass
class SearchResult:
    """What one search returned.

    expected is the number of records the site says the search has, or None
    when the site reports no total. A non-empty error marks the search incomplete.
    """

    records: list[dict]
    expected: int | None = None
    pages: int = 0
    error: str = ""
    notes: str = ""


def combine_pieces(expected: int, pieces: list[SearchResult], notes: str) -> SearchResult:
    """Join the pieces of a split query.

    The result is complete only when every piece is complete, the pieces add up
    to the original total and no ID appears in two pieces.
    """
    records: list[dict] = []
    seen: set[str] = set()
    errors = [piece.error for piece in pieces if piece.error]
    for piece in pieces:
        for record in piece.records:
            if record["id"] in seen:
                errors.append(f"ID {record['id']} appears in two pieces")
            seen.add(record["id"])
            records.append(record)

    # The pieces must account for every record of the original query.
    piece_total = sum(piece.expected or 0 for piece in pieces)
    if piece_total != expected:
        errors.append(f"pieces report {piece_total} records, the query reported {expected}")
    return SearchResult(
        records=records,
        expected=expected,
        pages=sum(piece.pages for piece in pieces),
        error="; ".join(errors[:5]),
        notes=notes,
    )


def name_searches(searches: list[dict]) -> list[dict]:
    """Give each search a run-local ID (s001, s002 ...) and check that names are unique."""
    names = [search.get("name", "") for search in searches]
    if not all(names) or len(set(names)) != len(names):
        raise ValueError("Every search needs a unique, non-empty 'name'")
    return [{"search_id": f"s{index:03d}", **search} for index, search in enumerate(searches, 1)]


def run_searches(
    source: ModuleType, client: Client, searches: list[dict], workers: int
) -> list[tuple[dict, SearchResult, float]]:
    """Run the searches concurrently and return them in plan order with their timings."""
    results: dict[str, tuple[dict, SearchResult, float]] = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(timed_search, source, client, search): search for search in searches
        }
        for future in as_completed(futures):
            search = futures[future]
            result, seconds = future.result()
            results[search["search_id"]] = (search, result, seconds)
            state = "complete" if not result.error else f"INCOMPLETE: {result.error}"
            LOG.info(
                "Search %s (%s): %d of %s records, %.1fs, %s",
                search["search_id"],
                search["name"],
                len(result.records),
                result.expected,
                seconds,
                state,
            )
    return [results[search["search_id"]] for search in searches]


def timed_search(source: ModuleType, client: Client, search: dict) -> tuple[SearchResult, float]:
    """Run one search, turning any error into an incomplete result."""
    started = time.monotonic()
    try:
        result = source.run_search(client, search)
    except Exception as error:  # One failed search is recorded; the others carry on.
        result = SearchResult(records=[], error=f"{type(error).__name__}: {error}")

    # A search that does not reach the site's own total is incomplete.
    retrieved = len(result.records)
    if not result.error and result.expected is not None and retrieved != result.expected:
        result.error = f"retrieved {retrieved} records, the site reported {result.expected}"
    return result, round(time.monotonic() - started, 2)


def write_searches(path: Path, results: list[tuple[dict, SearchResult, float]]) -> None:
    """Write one row per search: the query, expected and retrieved counts, and any error."""
    rows = []
    for search, result, seconds in results:
        query = {key: value for key, value in search.items() if key not in {"search_id", "name"}}
        rows.append(
            {
                "search_id": search["search_id"],
                "name": search["name"],
                "query": json.dumps(query, ensure_ascii=False, default=str),
                "expected": "" if result.expected is None else result.expected,
                "retrieved": len(result.records),
                "pages": result.pages,
                "complete": not result.error,
                "error": result.error,
                "notes": result.notes,
                "seconds": seconds,
            }
        )
    storage.write_csv(path, rows, SEARCH_FIELDS)


def search_summary(results: list[tuple[dict, SearchResult, float]]) -> dict:
    """Count searches, raw records and incomplete searches for the summary."""
    return {
        "searches": len(results),
        "incomplete_searches": [search["name"] for search, result, _ in results if result.error],
        "raw_records": sum(len(result.records) for _, result, _ in results),
        "search_counts": {search["name"]: len(result.records) for search, result, _ in results},
    }
