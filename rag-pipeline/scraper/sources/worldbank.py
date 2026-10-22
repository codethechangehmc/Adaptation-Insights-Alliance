"""World Bank Documents and Reports scraper.

Source:     https://documents.worldbank.org, through https://search.worldbank.org/api/v3/wds
Strategy:   one API query per evaluation document type and African country or regional
            value, plus keyword queries as an extra recall net; date bounds sent to the API
Pagination: offset (os) and page size (rows); every page reports the total (checked 2026-10-15)
Query cap:  the API rejects offsets above 100,000 ("Value must be between 0 and 100000"),
            so a query with 100,000 or more results is split by date (checked 2026-10-15)
Kept:       Implementation Completion and Results Reports, ICR Reviews (IEG), PPARs
Dropped:    development policy lending and budget support (policy_or_budget_support)
Quirks:     strdate alone omits later years, so enddate is always sent too; country fields
            can list several countries; PDFs are mirrored on documents1.worldbank.org

Run: python rag-pipeline/scraper/run.py worldbank --help
"""

from __future__ import annotations

import argparse
import json
import re
from datetime import date, timedelta
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from core import matching, storage
from core.fetch import Client
from core.searching import SearchResult, combine_pieces

SOURCE = "worldbank"
REPO = Path(__file__).resolve().parents[3]
SCOPE_FILE = Path(__file__).resolve().parents[1] / "config" / "worldbank_scope.json"
SCOPE = json.loads(SCOPE_FILE.read_text(encoding="utf-8"))

API = "https://search.worldbank.org/api/v3/wds"
API_COLUMNS = {
    "id": "id",
    "title": "display_title",
    "pdf_url": "pdfurl",
    "doc_date": "docdt",
    "doc_type": "docty",
    "country": "count",
    "language": "lang",
    "project_id": "projectid",
    "web_url": "url",
    "report_name": "repnme",
    "project_name": "projn",
    "abstract": "abstracts",
    "topics": "teratopic",
    "report_no": "repnb",
}
API_FIELDS = ",".join(API_COLUMNS.values())
EXTRA_FIELDS = [
    "report_name",
    "project_name",
    "abstract",
    "topics",
    "report_no",
    "project_sectors",
    "project_instruments",
    "project_end_date",
]
# Loaded once when planning a run; workers only read this snapshot.
PROJECT_DETAILS: dict[str, dict] = {}
POLICY = re.compile(
    r"Development Policy|Poverty Reduction Support|Budget Support|Policy Financing"
    r"|\b(?:DPO|DPF|DPL|PRSC)\b",
    re.IGNORECASE,
)
PROJECT_CODE = re.compile(r"P\d{6}")
EARLIEST_DATE = date(1900, 1, 1)


def add_arguments(parser: argparse.ArgumentParser) -> None:
    """Add the World Bank options."""
    parser.add_argument(
        "--projects-file",
        type=Path,
        help="project details CSV (default: <output-dir>/worldbank_projects.csv, if present)",
    )
    parser.add_argument(
        "--countries",
        nargs="+",
        help="query only these API country values (default: all, plus regions)",
    )
    parser.add_argument(
        "--skip-keywords",
        action="store_true",
        help="leave out the keyword queries, for quick checks",
    )
    parser.add_argument(
        "--no-server-dates",
        action="store_true",
        help="send no date bounds to the API; dates are still checked locally",
    )


def prepare_run(args: argparse.Namespace) -> None:
    """Load the project details table once; every search worker reads the same copy."""
    project_file = args.projects_file or args.output_dir / "worldbank_projects.csv"
    if args.projects_file and not project_file.exists():
        raise FileNotFoundError(project_file)
    PROJECT_DETAILS.clear()
    if project_file.exists():
        PROJECT_DETAILS.update({row["project_id"]: row for row in storage.read_csv(project_file)})


def plan_searches(args: argparse.Namespace) -> list[dict]:
    """List one search per document type and country, region or keyword query."""
    selectors = [("count_exact", value) for value in args.countries or SCOPE["countries"]]
    if not args.countries:
        selectors += [("count_exact", value) for value in SCOPE["regions"]]
    if not args.skip_keywords:
        selectors += [("qterm", value) for value in SCOPE["keyword_queries"]]

    # One search per selector and document type. Both date bounds go to the API.
    searches = {}
    for field, value in selectors:
        for doc_type in SCOPE["document_types"]:
            search = {"name": f"{value} | {doc_type}", field: value, "docty_exact": doc_type}
            if not args.no_server_dates:
                search["strdate"] = args.start_date.isoformat()
                search["enddate"] = args.end_date.isoformat()
            searches[search["name"]] = search
    return list(searches.values())


def run_search(client: Client, search: dict) -> SearchResult:
    """Fetch every page of one search, splitting it by date when it reaches the API cap."""
    query = {key: value for key, value in search.items() if key not in {"name", "search_id"}}
    first_page = fetch_page(client, query, 0)
    total = int(first_page["total"])
    if total >= SCOPE["max_results_per_query"]:
        return split_by_date(client, search, total)
    return fetch_all_pages(client, query, first_page)


def fetch_page(client: Client, query: dict, offset: int) -> dict:
    """Fetch one page of API results, sorted by date so that paging is stable."""
    params = {
        "format": "json",
        "fl": API_FIELDS,
        "rows": SCOPE["page_size"],
        "srt": "docdt",
        "order": "asc",
        "os": offset,
        **query,
    }
    return client.get_json(API, params=params)


def fetch_all_pages(client: Client, query: dict, first_page: dict) -> SearchResult:
    """Page through one query until the reported total is reached."""
    total = int(first_page["total"])
    records: list[dict] = []
    seen: set[str] = set()
    payload, pages = first_page, 0
    while True:
        pages += 1

        # The total must not move and IDs must not repeat, or the pages are not one list.
        if int(payload["total"]) != total:
            return SearchResult(
                records, total, pages, error=f"total changed from {total} to {payload['total']}"
            )
        page = page_records(payload)
        for record in page:
            if record["id"] in seen:
                return SearchResult(
                    records, total, pages, error=f"ID {record['id']} repeated while paging"
                )
            seen.add(record["id"])
            records.append(record)

        # Stop at the total. An empty page before it means records are missing.
        if len(records) >= total:
            return SearchResult(records, total, pages)
        if not page:
            return SearchResult(
                records, total, pages, error=f"empty page at offset {len(records)} of {total}"
            )
        payload = fetch_page(client, query, len(records))


def page_records(payload: dict) -> list[dict]:
    """Return the records of one API page. The facets entry is not a document."""
    documents = payload.get("documents", {})
    if not isinstance(documents, dict):
        raise ValueError(f"unexpected documents field: {type(documents).__name__}")
    return [normalize_record(doc) for key, doc in documents.items() if key != "facets"]


def split_by_date(client: Client, search: dict, total: int) -> SearchResult:
    """Split a capped query into two date halves and run each; recurse when needed."""
    start = date.fromisoformat(search.get("strdate", EARLIEST_DATE.isoformat()))
    end = date.fromisoformat(search.get("enddate", date.today().isoformat()))
    if start >= end:
        return SearchResult([], total, error=f"{total} records on {start} alone reach the cap")

    # Halves share no day: [start, middle] and [middle + 1 day, end].
    middle = start + (end - start) // 2
    halves = [(start, middle), (middle + timedelta(days=1), end)]
    pieces = []
    for low, high in halves:
        piece = {**search, "strdate": low.isoformat(), "enddate": high.isoformat()}
        pieces.append(run_search(client, piece))
    notes = f"split at {middle}: {total} results reach the cap of {SCOPE['max_results_per_query']}"
    return combine_pieces(total, pieces, notes)


def flatten(value: object) -> str:
    """Turn an API value (text, list or nested dict) into one string."""
    if value is None:
        return ""
    if isinstance(value, dict):
        return "; ".join(part for part in (flatten(item) for item in value.values()) if part)
    if isinstance(value, list):
        return "; ".join(part for part in (flatten(item) for item in value) if part)
    return str(value).strip()


def normalize_record(doc: dict) -> dict:
    """Map one API document to a record with the catalogue's column names."""
    record = {column: flatten(doc.get(field)) for column, field in API_COLUMNS.items()}
    if not re.fullmatch(r"\d+", record["id"]):
        raise ValueError(f"API record without a numeric document ID: {record['id']!r}")

    # Some records have no projectid; the project name often ends with its P-code.
    if not record["project_id"]:
        record["project_id"] = ";".join(
            dict.fromkeys(PROJECT_CODE.findall(record["project_name"]))
        )
    add_project_details(record, PROJECT_DETAILS)
    return record


def add_project_details(record: dict, projects: dict[str, dict]) -> None:
    """Attach sector, instrument and closing dates for every referenced project."""
    details = [
        projects[code] for code in PROJECT_CODE.findall(record["project_id"]) if code in projects
    ]
    record["project_sectors"] = "; ".join(
        value
        for row in details
        for value in (row.get("sectors", ""), row.get("major_sectors", ""))
        if value
    )
    record["project_instruments"] = "; ".join(
        row["lending_instrument"] for row in details if row.get("lending_instrument")
    )

    # A multi-project document can outlast the first project's completion date.
    dates = [row["closing_date"] for row in details if row.get("closing_date")]
    record["project_end_date"] = max(dates, default="")


def is_african(record: dict) -> bool:
    """Return True when the country field is African, or is World with an African title."""
    if matching.is_african(record["country"]):
        return True
    values = [value.strip().casefold() for value in record["country"].split(",")]
    return "world" in values and matching.is_african(record["title"])


def prepare_record(record: dict) -> None:
    """Attach refreshed project evidence before date filtering stored records."""
    if PROJECT_DETAILS and record.get("project_id"):
        add_project_details(record, PROJECT_DETAILS)


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Return status, reason and matched keywords for one World Bank record."""
    if not is_african(record):
        return "drop", "no_african_country", []
    headline = " ".join(
        record.get(field, "") for field in ("title", "report_name", "project_name")
    )
    if POLICY.search(headline) or POLICY.search(record.get("project_instruments", "")):
        return "drop", "policy_or_budget_support", []

    # Official Agriculture sector evidence adds recall without broadening to water or finance.
    if matching.find_keywords(record.get("project_sectors", ""), ["Agriculture", "Agricultural"]):
        return "in_scope", "agriculture_project_sector", ["project_sector:agriculture"]

    # A title keyword or the Bank's Agriculture topic is strong evidence; the abstract is weak.
    headline_keywords = matching.find_keywords(headline)
    agriculture_topic = matching.find_keywords(record.get("topics", ""), ["Agriculture"])
    if headline_keywords or agriculture_topic:
        return "in_scope", "agriculture_topic_or_headline_keywords", headline_keywords
    abstract_keywords = matching.find_keywords(record.get("abstract", ""))
    if abstract_keywords:
        return "to_screen", "abstract_keywords_only", abstract_keywords

    # No evidence: say whether the metadata was empty or really negative.
    if not record.get("abstract") and not record.get("topics"):
        return "drop", "insufficient_metadata", []
    return "drop", "no_agriculture_or_adaptation_evidence", []


def pdf_urls(record: dict) -> list[str]:
    """Return the documents1 mirror first, then the API's own link, both over HTTPS."""
    if not record.get("pdf_url"):
        return []
    parts = urlsplit(record["pdf_url"])
    host = parts.netloc.lower()
    own_link = urlunsplit(("https", host, parts.path, parts.query, ""))
    if host != "documents.worldbank.org":
        return [own_link]
    mirror = urlunsplit(("https", "documents1.worldbank.org", parts.path, parts.query, ""))
    return [mirror, own_link]
