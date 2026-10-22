"""Climate Policy Radar family enumeration shared by AF and GCF.

Pagination: page_token is a one-based page number, checked 2026-10-15.
Query cap: none observed; page 63,988 at size one is empty after total 63,987.
Quirks: published_date on a family is approval, never a document date.
"""

from __future__ import annotations

import json
import re
from urllib.parse import unquote

from core.fetch import Client, RequestFailed, run_parallel
from core.matching import find_keywords, is_african, parse_date
from core.searching import SearchResult

API = "https://api.climatepolicyradar.org"
# Catalogue columns of every CPR record, used by AF and GCF.
EXTRA_FIELDS = [
    "source_country",
    "region_labels",
    "family_id",
    "project_title",
    "abstract",
    "topics",
    "project_end_date",
    "source_url",
    "retrieval_channel",
]
EVALUATION = re.compile(
    r"evaluat|mid[- ]?term review|completion (?:report|summary)", re.IGNORECASE
)


def search_filters(agent: str, regions: list[str] | None = None) -> dict:
    """Select principal fund projects and African or international regions."""
    # These label identifiers were returned by AF search on 2026-10-15.
    filters = [
        {"field": "labels.value.id", "op": "contains", "value": value}
        for value in [agent, "status::Principal", "entity_type::Project"]
    ]
    filters.append(
        {
            "op": "or",
            "filters": [
                {"field": "labels.value.id", "op": "contains", "value": value}
                for value in (regions or ["region::SSF", "region::MEA", "country::XAB"])
            ],
        }
    )
    return {"op": "and", "filters": filters}


def list_families(
    client: Client, agent: str, page_size: int = 100, regions: list[str] | None = None
) -> SearchResult:
    """Read numbered pages until every reported family has been retrieved."""
    # Stable title order and duplicate checks detect a repeated or capped page.
    records, seen, page, total = [], set(), 1, None
    while True:
        payload = client.get_json(
            API + "/search/documents",
            params={
                "filters": json.dumps(search_filters(agent, regions)),
                "page_size": page_size,
                "page_token": page,
                "order_by": "title asc",
            },
        )
        expected = int(payload["total_size"])
        if total is not None and total != expected:
            return SearchResult(records, total, page, "CPR total changed during pagination")
        total = expected
        rows = payload.get("results", [])
        ids = [row["id"] for row in rows]
        if len(set(ids)) != len(ids) or seen.intersection(ids):
            return SearchResult(records, total, page, "CPR repeated family IDs")
        records.extend(rows)
        seen.update(ids)
        if len(records) >= total or not rows:
            error = "" if len(records) == total else "CPR ended before reported total"
            return SearchResult(records, total, page, error)
        page += 1


def document_date(document: dict) -> str:
    """Read document events or an explicit day-month-year in its source filename."""
    # Do not use ingestion timestamps or the family's approval date.
    dates = [
        event.get("date", "")
        for event in document.get("events", [])
        if re.search(r"publish|evaluat|complet", event.get("event_type", ""), re.I)
    ]
    for value in dates:
        found = parse_date(value)
        if found:
            return found.isoformat()

    # AF Senegal n0002 has an explicit '14 August 2015' filename (2026-10-15).
    filename = unquote(document.get("source_url") or "").replace("_", " ")
    match = re.search(r"\b(\d{1,2} [A-Za-z]+ \d{4})\b", filename)
    found = parse_date(match[1]) if match else None
    return found.isoformat() if found else ""


def project_identifier(family: dict, source: str) -> str:
    """Use the GCF portfolio code across channels while preserving other fund IDs."""
    if source != "gcf":
        return family["import_id"]

    # FP049.14920 and SAP007.19290 were returned by CPR on 2026-10-15.
    for value in family.get("metadata", {}).get("project_id", []):
        if re.fullmatch(r"(?:FP|SAP)\d+", value, re.I):
            return value.upper()
    match = re.match(r"GCF\.family\.((?:FP|SAP)\d+)\.", family["import_id"])
    if not match:
        raise ValueError("Unrecognized GCF family project identifier")
    return match[1]


def family_records(family: dict, source: str) -> list[dict]:
    """Preserve one record per document with family and document provenance."""
    # Only completed/closed events provide a defensible project-date fallback.
    metadata = family.get("metadata", {})
    end_dates = [
        event.get("date", "")
        for event in family.get("events", [])
        if re.search(r"complet|clos", event.get("event_type", ""), re.IGNORECASE)
    ]
    country = ",".join(family.get("geographies", []) + metadata.get("region", []))
    records = []
    for document in family.get("documents", []):
        records.append(
            {
                "source": source,
                "id": document["import_id"],
                "title": document.get("title") or "",
                "project_title": family.get("title", ""),
                "abstract": family.get("summary", ""),
                "topics": ",".join(metadata.get("sector", [])),
                "country": country,
                "language": document.get("language") or "",
                "project_id": project_identifier(family, source),
                "family_id": family["import_id"],
                "doc_date": document_date(document),
                "project_end_date": max(end_dates, default=""),
                "doc_type": document.get("title") or "",
                "pdf_url": document.get("cdn_object") or document.get("source_url") or "",
                "source_url": document.get("source_url") or "",
                "web_url": API + "/families/" + family["import_id"],
                "retrieval_channel": "climate_policy_radar",
            }
        )
    return records


def run_search(
    client: Client,
    source: str,
    agent: str,
    prefix: str,
    page_size: int = 100,
    regions: list[str] | None = None,
) -> SearchResult:
    """List every filtered family, then fetch each family's documents in parallel."""
    families = list_families(client, agent, page_size, regions)
    if families.error:
        return families
    if any(not family["id"].startswith(prefix) for family in families.records):
        return SearchResult([], error="CPR fund filter returned another corpus")

    # Fetch every detail first, then read them in listing order.
    details = run_parallel(client, lambda family: family_detail(client, family), families.records)
    records = []
    for family, detail in zip(families.records, details, strict=True):
        if isinstance(detail, RequestFailed):
            # GCF FP221 is still listed but its detail returns 410 (checked 2026-10-22).
            notes = f"Stopped at {family['id']}; listing total {families.expected}"
            return SearchResult(records, pages=families.pages, error=str(detail), notes=notes)
        rows = family_records(detail, source)
        if not rows:
            return SearchResult(records, error=f"No documents for {family['id']}")
        labels = place_labels(family)
        for row in rows:
            row.update(labels)
        records.extend(rows)
    notes = f"Families expected/retrieved: {families.expected}/{len(families.records)}"
    return SearchResult(records, None, families.pages, notes=notes)


def family_detail(client: Client, family: dict) -> dict | RequestFailed:
    """Return one family's detail, or the failure so the caller can report where it stopped."""
    try:
        return client.get_json(API + "/families/" + family["id"])["data"]
    except RequestFailed as error:
        return error


def place_labels(family: dict) -> dict:
    """Return the search hit's country and region labels as record fields.

    Country labels decide geography; region labels count only when no country
    is named, so a MENA region label cannot make a Pakistan family African.
    """
    places = {"geography": [], "region": []}
    labels = []
    for label in family.get("labels", []):
        if label.get("type") in places:
            places[label["type"]].append(label["value"]["value"])
            labels.append(label["value"]["value"])
    return {
        "country": ",".join(places["geography"] or places["region"]),
        "source_country": ",".join(labels),
        "region_labels": ",".join(places["region"]),
    }


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Keep evaluations with African agriculture or adaptation evidence."""
    # Explicit country labels take precedence over broad MENA regional labels.
    country = record.get("country", "")
    if (
        country
        and country.casefold() not in {"international", "global", "world"}
        and not is_african(country)
    ):
        return "drop", "no_african_country", []

    # Progress reports and proposals are not evaluation documents.
    if not EVALUATION.search(record.get("doc_type", record.get("title", ""))):
        reason = "non_evaluation_document"
        if re.search(
            r"proposal|project document|concept",
            record.get("title", "") + " " + record.get("doc_type", ""),
            re.I,
        ):
            reason = "proposal_stage"
        return "drop", reason, []
    text = " ".join(
        str(record.get(key, ""))
        for key in ["title", "project_title", "abstract", "topics", "country"]
    )
    if not is_african(text):
        if "international" in record.get("country", "").lower():
            return "to_screen", "uncertain_geography", []
        return "drop", "no_african_country", []
    keywords = find_keywords(text)
    if keywords:
        return "in_scope", "evaluation_scope_keywords", keywords
    return "drop", "no_agriculture_or_adaptation_evidence", []


def pdf_urls(record: dict) -> list[str]:
    """Return the hosted PDF and original source as fallbacks."""
    urls = [record.get("pdf_url"), record.get("source_url")]
    return list(dict.fromkeys(url for url in urls if url))
