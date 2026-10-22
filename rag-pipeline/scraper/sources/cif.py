"""Climate Investment Funds document and knowledge-document enumeration.

Source: https://www.cif.org/search-data
Strategy: enumerate three document collections with the site's own JSON POST.
Pagination: s offset and l page size, count checked (2026-10-15).
Query cap: none observed; offset 6500 returned final 728 of 7228 documents.
Kept: evaluations, learning reviews, completion and performance reviews.
Dropped: proposals, meeting and Evaluation and Learning administration papers.
Quirks: old sitemap changed; date filter returned zero for known dated rows.
"""

from __future__ import annotations

import json
import re
from argparse import Namespace
from pathlib import Path
from urllib.parse import urljoin

from core.fetch import Client
from core.matching import find_keywords, is_african
from core.searching import SearchResult

SOURCE = "cif"
REPO = Path(__file__).resolve().parents[3]
SCOPE_FILE = Path(__file__).resolve().parents[1] / "config" / "cif_scope.json"
SCOPE = json.loads(SCOPE_FILE.read_text(encoding="utf-8"))
BASE = "https://www.cif.org"
HEADERS = {"X-Requested-With": "XMLHttpRequest", "Referer": BASE + "/knowledge"}
EXTRA_FIELDS = ["abstract", "topics", "pdf_urls", "retrieval_channel"]
EVALUATION = re.compile(
    r"evaluat|mid[- ]?term|completion|performance review|learning review|"
    r"lessons learned|impact assessment",
    re.I,
)
PROPOSAL = re.compile(r"\bproposal\b|\bappraisal\b|monitoring and evaluation framework", re.I)
# Planning, method and meeting papers: by document type, then by title.
ADMIN_TYPE = re.compile(r"presentations?|agenda|minutes|toolkit|guideline", re.I)
ADMIN_TITLE = re.compile(
    r"toolkits?|guidelines?|guidance note|\bframework\b|evaluation and learning initiative|"
    r"annual report|work ?plan|business plan|terms of reference|\btor\b|"
    r"workshop|webinar|agenda|committee|meeting|presentation|concept note|"
    r"^(?:Developmental|Formative|Impact|Outcome) Evaluation$",
    re.I,
)
NON_AFRICA = re.compile(
    r"\b(?:Bangladesh|Nepal|India|Indonesia|Brazil|Mexico|Ukraine|"
    r"Tajikistan|Cambodia|Philippines|Vietnam|Honduras|Jamaica|"
    r"Bolivia|Peru|Chile|Turkey|Türkiye|Papua New Guinea)\b",
    re.I,
)


def plan_searches(args: Namespace) -> list[dict]:
    """List three complete document collections without unreliable date filters."""
    return [{"name": "cif_" + kind, "content_type": kind} for kind in SCOPE["collections"]]


def parse_records(payload: dict) -> list[dict]:
    """Flatten the observed grouped index entries into stable node records."""
    # The API groups rows by title/date/nid and stores fields in a nested data array.
    records = []
    for group in payload.get("data", []):
        for item in group["data"]:
            row = {**group["_id"], **item}
            for field in ["category", "country", "topic", "program"]:
                if isinstance(row.get(field), dict):
                    row[field] = list(row[field].values())
            urls = [urljoin(BASE, value) for value in row.get("downloads", [])]
            records.append(
                {
                    "source": SOURCE,
                    "id": str(row["nid"]),
                    "title": row.get("title", ""),
                    "doc_date": row.get("date", ""),
                    "doc_type": ",".join(row.get("category", [])),
                    "country": ",".join(row.get("country", [])),
                    "language": document_language(row),
                    "topics": ",".join(row.get("topic", []) + row.get("program", [])),
                    "web_url": urljoin(BASE, row["path"]),
                    "pdf_url": urls[0] if urls else "",
                    "pdf_urls": urls,
                    "retrieval_channel": "website_index",
                }
            )
    return records


def document_language(row: dict) -> str:
    """Preserve explicit index language, otherwise use only a clear title label."""
    language = str(row.get("language") or row.get("lang") or "").strip()
    if language:
        return language

    # Nodes 3926, 4049 and 4050 label French files in English titles (checked 2026-10-22).
    if re.search(r"(?:\(\s*French\s*\)|-\s*French)\s*$", row.get("title", ""), re.I):
        return "fr"
    return ""


def run_search(client: Client, search: dict) -> SearchResult:
    """Fetch offset pages until the reported collection count is reached."""
    records, seen, pages, total = [], set(), 0, None
    while True:
        response = client.post(
            BASE + "/search-data",
            data={
                "qs": json.dumps({"content_type": search["content_type"]}),
                "l": SCOPE["page_size"],
                "s": len(records),
                "f": 1,
                "o": "old",
                "t": "",
                "x": "or",
                "k": "type_governance",
                "rk": "",
                "u": "",
            },
            headers=HEADERS,
        )
        payload = response.json()
        expected = int(payload["count"])
        pages += 1
        if total is not None and expected != total:
            return SearchResult(records, total, pages, "CIF total changed during pagination")
        total = expected
        rows = parse_records(payload)
        ids = [row["id"] for row in rows]
        if seen.intersection(ids) or len(set(ids)) != len(ids):
            return SearchResult(records, total, pages, "CIF repeated node IDs")
        records.extend(rows)
        seen.update(ids)
        if len(records) >= total or not rows:
            error = "" if len(records) == total else "CIF ended before reported total"
            return SearchResult(records, total, pages, error)


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Select substantive evaluations and distinguish global from country evidence."""
    title = record.get("title", "")
    if PROPOSAL.search(title):
        return "drop", "proposal_stage", []
    if ADMIN_TYPE.search(record.get("doc_type", "")) or ADMIN_TITLE.search(title):
        return "drop", "administrative_document", []
    if not EVALUATION.search(title):
        return "drop", "non_evaluation_document", []

    # Global programme evaluations may include African pilots without naming them in the title.
    text = " ".join(record.get(key, "") for key in ["title", "topics", "country"])
    african = is_african(text)
    country = record.get("country", "").casefold()
    explicit_country = country and country not in {"global", "international", "world"}
    if not african and (explicit_country or NON_AFRICA.search(text)):
        return "drop", "no_african_country", []
    keywords = find_keywords(text)
    if african and keywords:
        return "in_scope", "evaluation_scope_keywords", keywords
    if not african:
        return "to_screen", "global_evaluation_geography_uncertain", keywords
    return "drop", "no_agriculture_or_adaptation_evidence", []


def pdf_urls(record: dict) -> list[str]:
    """Return indexed direct download links in stable order."""
    urls = record.get("pdf_urls") or [record.get("pdf_url", "")]
    return list(dict.fromkeys(url for url in urls if url))


def resolve_pdf_urls(client: Client, record: dict) -> list[str]:
    """Keep indexed files and add detail-page alternatives for stale or malformed links."""
    urls = pdf_urls(record)

    # Node 18282 has a broken %2520 link and a working %20 link (checked 2026-10-22).
    page = client.get_html(record["web_url"])
    body = page.select_one("main") or page
    return list(
        dict.fromkeys(
            urls
            + [
                urljoin(BASE, link["href"])
                for link in body.select("a[href]")
                if re.search(r"\.pdf(?:[?#]|$)", link["href"], re.I)
            ]
        )
    )
