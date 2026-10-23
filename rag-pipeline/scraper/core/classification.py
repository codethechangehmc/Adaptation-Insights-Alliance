"""Merge search records, decide each one, and keep documents from an inclusion list.

An inclusion list (--include-listing) names documents that must reach screening,
for example the documents an earlier pipeline found. A listed document that the
rules drop is kept as to_screen with reason reference_recall; the rule's own
decision stays visible in rule_status and rule_reason.
"""

from __future__ import annotations

import json
import re
from datetime import date
from pathlib import Path
from types import ModuleType

from core import matching, storage
from core.searching import SearchResult

STATUS_RANK = {"drop": 0, "to_screen": 1, "in_scope": 2}
SIBLING_LIFTABLE_REASONS = {
    "no_agriculture_or_adaptation_evidence",
    "insufficient_metadata",
    "abstract_keywords_only",
}
INCLUSION_FIELDS = [
    "reference_ids",
    "reference_urls",
    "reference_date",
    "rule_status",
    "rule_reason",
]
LIST_FIELDS = ("reference_ids", "reference_urls", "pdf_urls")
# A listed copy never replaces what the source itself says is unknown.
SOURCE_OWNED_FIELDS = ("doc_date", "project_end_date", "country", "language")


def values(value: str | list | None) -> list[str]:
    """Read a list field: a list, a JSON list from a CSV cell, or one plain value."""
    if not value:
        return []
    if isinstance(value, list):
        return value
    if value.startswith("["):
        return json.loads(value)
    return [value]


def merge(first: dict, later: dict) -> dict:
    """Merge two copies of one record: first wins, later fills its gaps, list fields combine."""
    merged = {**later, **{key: value for key, value in first.items() if value}}
    for field in LIST_FIELDS:
        combined = values(first.get(field)) + values(later.get(field))
        if combined:
            merged[field] = list(dict.fromkeys(combined))
    return merged


def merge_records(source_name: str, results: list[tuple[dict, SearchResult, float]]) -> dict:
    """Merge duplicates by ID; search_ids lists every search that returned the record."""
    records: dict[str, dict] = {}
    for search, result, _ in results:
        for record in result.records:
            doc_id = str(record["id"])
            if doc_id in records:
                records[doc_id] = merge(records[doc_id], record)
                records[doc_id]["search_ids"] += ";" + search["search_id"]
            else:
                records[doc_id] = {
                    **record,
                    "id": doc_id,
                    "source": source_name,
                    "search_ids": search["search_id"],
                }
    return records


def add_inclusions(records: dict, state: dict, paths: list[Path], source: str) -> None:
    """Add listed documents: those listed in earlier runs, then the rows of each new CSV."""
    # Listed documents stay listed in later runs, even when a search no longer returns them.
    for doc_id, entry in state.items():
        if entry["record"].get("reference_ids"):
            records[doc_id] = merge_listed(records.get(doc_id, {}), entry["record"])

    # Each new row needs an ID and title; its file links become download fallbacks.
    for path in paths:
        for row in storage.read_csv(path):
            if row.get("source") not in {None, "", source}:
                raise ValueError(f"Inclusion list source {row['source']!r} differs from {source}")
            if not row.get("id") or not row.get("title"):
                raise ValueError("Inclusion rows require non-empty id and title")
            listed = {**dict.fromkeys(storage.RECORD_FIELDS, ""), **row, "source": source}
            listed["reference_ids"] = values(row.get("reference_ids")) or [row["id"]]
            links = [row[field] for field in ("pdf_url", "source_url") if row.get(field)]
            listed["reference_urls"] = list(
                dict.fromkeys(values(row.get("reference_urls")) + links)
            )
            records[row["id"]] = merge_listed(records.get(row["id"], {}), listed)


def merge_listed(current: dict, listed: dict) -> dict:
    """Merge a listed copy into the current record without overriding source-owned fields."""
    merged = merge(current, listed)
    for field in SOURCE_OWNED_FIELDS:
        if field in current:
            merged[field] = current[field]
    return merged


def decide(source: ModuleType, record: dict, start: date, end: date) -> tuple[str, str, list[str]]:
    """Apply the shared date and language rules, then the source's own classify."""
    # Let the source attach dates and evidence it keeps outside the search results.
    if hasattr(source, "prepare_record"):
        source.prepare_record(record)

    # Date window. A record with no date is kept for screening.
    problem = matching.date_problem(record, start, end)
    if problem == "outside_date_range":
        return "drop", problem, []

    # English only.
    text = f"{record.get('title', '')} {record.get('abstract', '')}"
    if not matching.is_english(record.get("language", ""), text):
        return "drop", "not_english", []

    status, reason, keywords = source.classify(record)
    if status not in STATUS_RANK:
        raise ValueError(f"classify returned unknown status {status!r} for {record['id']}")
    if status != "drop" and problem:
        return "to_screen", problem, list(keywords)
    return status, reason, list(keywords)


def classify_all(source: ModuleType, records: dict, start: date, end: date) -> int:
    """Decide every record, share decisions within projects and keep listed documents.

    Returns the number of records lifted by a project sibling.
    """
    for record in records.values():
        status, reason, keywords = decide(source, record, start, end)
        record.update(screen_status=status, filter_reason=reason)
        record["matched_keywords"] = "; ".join(keywords)
    lifted = apply_project_decisions(records)

    # A listed document reaches screening whatever the rules say; the rule decision stays visible.
    for record in records.values():
        record["rule_status"] = record["screen_status"]
        record["rule_reason"] = record["filter_reason"]
        if record.get("reference_ids") and record["screen_status"] == "drop":
            record.update(screen_status="to_screen", filter_reason="reference_recall")
    return lifted


def project_codes(record: dict) -> list[str]:
    """Split a project_id field that may list several projects."""
    codes = re.split(r"[,;]", record.get("project_id", ""))
    return [code.strip() for code in codes if code.strip()]


def apply_project_decisions(records: dict[str, dict]) -> int:
    """Give documents of one project the strongest decision among them. Returns the count.

    Only records held back for weak evidence are lifted, never those dropped for a
    rule such as date, language, country or proposal stage.
    """
    # Find the strongest decision for each project.
    best: dict[str, tuple[int, str]] = {}
    for record in records.values():
        rank = STATUS_RANK[record["screen_status"]]
        for code in project_codes(record):
            if rank > best.get(code, (-1, ""))[0]:
                best[code] = (rank, record["id"])

    # Lift weak-evidence records to their strongest sibling's decision.
    lifted = 0
    for record in records.values():
        candidates = [best[code] for code in project_codes(record) if code in best]
        if record["filter_reason"] not in SIBLING_LIFTABLE_REASONS or not candidates:
            continue
        rank, sibling_id = max(candidates)
        if rank <= STATUS_RANK[record["screen_status"]]:
            continue
        status = next(name for name, value in STATUS_RANK.items() if value == rank)
        reason = "project_sibling_evidence"

        # A sibling cannot supply this document's missing date.
        if matching.record_date(record)[0] is None:
            status, reason = "to_screen", "unknown_document_date"
        keywords = [word for word in record["matched_keywords"].split("; ") if word]
        record.update(
            screen_status=status,
            filter_reason=reason,
            matched_keywords="; ".join([*keywords, f"sibling:{sibling_id}"]),
        )
        lifted += 1
    return lifted
