"""Global Environment Facility project documents.

Source:     https://www.thegef.org/projects-operations/database
Strategy:   union of LDCF, SCCF, Land Degradation and Climate Change listings;
            inspect project pages, retaining African national and regional projects
Pagination: page=N and a Displaying a-b of N count (saved HTML, 2026-10-15)
Query cap:  unknown: filtered requests returned HTTP 403 on 2026-10-15;
            completeness cannot be verified live; no local result limit
Kept:       terminal evaluations, mid-term reviews, evaluations, completion reports
Dropped:    proposal stage, progress reports, enabling activities, administrative files
Quirks:     stop on a blocked request; never fall back to an unfiltered listing.
            Document dates come from a saved gef_doc_dates.csv on later runs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

from bs4 import BeautifulSoup

from core import matching, storage
from core.fetch import Client, run_parallel
from core.searching import SearchResult

SOURCE = "gef"
REPO = Path(__file__).resolve().parents[3]
SCOPE_FILE = Path(__file__).resolve().parents[1] / "config" / "gef_scope.json"
SCOPE = json.loads(SCOPE_FILE.read_text(encoding="utf-8"))
SITE = "https://www.thegef.org"
DATABASE_URL = f"{SITE}/projects-operations/database"
EXTRA_FIELDS = [
    "project_title",
    "project_end_date",
    "focal_areas",
    "project_type",
    "doc_title",
    "source_doc_type",
]
TOTAL = re.compile(r"Displaying\s+[\d,]+\s*[-–]\s*[\d,]+\s+of\s+([\d,]+)")
LISTING_COLUMNS = {
    "views-field-title": "project_title",
    "views-field-field-countries": "country",
    "views-field-field-focal-areas": "focal_areas",
    "views-field-field-project-type": "project_type",
}
DOCUMENT_DATES: dict[str, str] = {}


def add_arguments(parser: argparse.ArgumentParser) -> None:
    """Add the optional recovered document dates table."""
    parser.add_argument(
        "--doc-dates", type=Path, help="saved gef_doc_dates.csv (default: output dir)"
    )


def plan_searches(args: argparse.Namespace) -> list[dict]:
    """List all four sweeps without excluding regional and multi-country projects."""
    # One sweep per facet avoids Drupal ANDing mutually exclusive values.
    return [{"name": name, "facet": facet} for name, facet in SCOPE["sweeps"].items()]


def prepare_run(args: argparse.Namespace) -> None:
    """Load the recovered report years, by document ID, from gef_doc_dates.csv if present."""
    # Years stay year-only values, so the date window covers the whole year.
    path = args.doc_dates or args.output_dir / "gef_doc_dates.csv"
    rows = storage.read_csv(path) if path.exists() else []
    DOCUMENT_DATES.clear()
    DOCUMENT_DATES.update(
        {row["id"]: row["final_year"] for row in rows if row.get("id") and row.get("final_year")}
    )


def prepare_record(record: dict) -> None:
    """Normalize stored source families and attach recovered years before shared rules."""
    # Historical CEO/PIF labels must retain proposal rules when reference rows are restored.
    kind = record.get("doc_type", "")
    if kind not in SCOPE["document_decisions"]:
        record.setdefault("source_doc_type", kind)
        normalized = document_type(kind)
        if normalized == "Other":
            label = record.get("doc_title") or record.get("title", "")
            path = unquote(urlsplit(record.get("pdf_url", "")).path)
            normalized = document_type(f"{label} {path}")
        record["doc_type"] = normalized

    # Recovered dates also apply to references when live enumeration remains blocked.
    if record.get("id") in DOCUMENT_DATES:
        record["doc_date"] = DOCUMENT_DATES[record["id"]]


def parse_listing(page: BeautifulSoup) -> list[dict]:
    """Read project rows using stable Drupal field classes."""
    # Keep projects without document links in the project count.
    projects = []
    for row in page.select("table tbody tr"):
        link = row.select_one("a[href*='/projects-operations/projects/']")
        if link is None:
            continue
        record = {
            "id": link["href"].rstrip("/").rsplit("/", 1)[-1],
            "web_url": urljoin(SITE, link["href"]),
        }
        for selector, field in LISTING_COLUMNS.items():
            cell = row.select_one(f".{selector}")
            record[field] = cell.get_text(" ", strip=True) if cell else ""
        projects.append(record)
    return projects


def list_projects(client: Client, search: dict) -> SearchResult:
    """Fetch every filtered listing page, rejecting repeats and count changes."""
    # The count must be present to establish completeness after the observed block.
    records, seen, total, pages = [], set(), None, 0
    while total is None or len(records) < total:
        page = client.get_html(
            DATABASE_URL,
            {"f[0]": search["facet"], "page": pages, **SCOPE["listing_order"]},
        )
        match = TOTAL.search(page.get_text(" ", strip=True))
        if not match:
            return SearchResult(records, total, pages + 1, "Missing listing total")
        count = int(match[1].replace(",", ""))
        if total is not None and count != total:
            return SearchResult(records, total, pages + 1, "Listing total changed during paging")
        total = count
        projects = parse_listing(page)
        pages += 1
        if not projects and len(records) < total:
            return SearchResult(records, total, pages, "Empty page before reported total")
        for project in projects:
            if project["id"] in seen:
                return SearchResult(records, total, pages, "Repeated project ID during paging")
            seen.add(project["id"])
            records.append(project)
    error = "Project count exceeds total" if len(records) != total else ""
    return SearchResult(records, total, pages, error)


def project_details(page: BeautifulSoup, project: dict) -> dict:
    """Read explicitly labelled geography and actual completion fields when present."""
    # Drupal field/table labels are conservative candidates, unverified on live detail pages.
    details = {**project, "project_end_date": ""}
    for field in page.select(".field, table tr, dl"):
        label = field.select_one(".field__label, th, dt")
        value = field.select_one(".field__item, td, dd")
        if label is None or value is None:
            continue
        key = label.get_text(" ", strip=True).strip(":").casefold()
        text = value.get_text(" ", strip=True)
        if key in {"country", "countries"}:
            values = field.select(".field__item") or [value]
            details["country"] = ",".join(item.get_text(" ", strip=True) for item in values)
        if key in {
            "completion date",
            "project completion",
            "project completion date",
            "closing date",
            "project closing date",
            "actual completion date",
        }:
            stamp = value.select_one("time[datetime]")
            found = matching.parse_date(stamp["datetime"] if stamp else text)
            if found:
                details["project_end_date"] = found.isoformat()
    details["geography_unknown"] = unknown_geography(details.get("country", ""))
    return details


def unknown_geography(country: str) -> bool:
    """Identify broad or missing country values that require checking project details."""
    # Explicitly named non-African countries can be skipped; Global/Regional cannot.
    return not country.strip() or bool(
        re.search(r"\b(global|regional|worldwide|world)\b", country, re.IGNORECASE)
    )


def document_type(text: str) -> str:
    """Apply ordered document-family rules to link labels and decoded filenames."""
    # Specific families precede general evaluation and proposal matches.
    for rule in SCOPE["document_types"]:
        if re.search(rule["pattern"], text, re.IGNORECASE):
            return rule["doc_type"]
    return "Other"


def project_documents(page: BeautifulSoup, project: dict) -> list[dict]:
    """Return one record per document link on a project page, Word and Excel files included."""
    # The website gives no document dates (checked 2026-10-15); prepare_record adds recovered ones.
    records, seen = [], set()
    for link in page.select("a[href]"):
        url = urljoin(project["web_url"], link["href"])
        path = unquote(urlsplit(url).path)
        if url in seen or Path(path).suffix.lower() not in storage.DOCUMENT_EXTENSIONS:
            continue
        seen.add(url)
        digest = hashlib.sha256(url.encode()).hexdigest()[:16]
        identifier = f"{project['id']}_{digest}"
        label = link.get_text(" ", strip=True) or path.rsplit("/", 1)[-1]
        records.append(
            {
                **project,
                "source": SOURCE,
                "id": identifier,
                "project_id": project["id"],
                "doc_title": label,
                "title": f"{project['project_title']}: {label}",
                "pdf_url": url,
                "language": "",
                "doc_date": "",
                "doc_type": document_type(f"{label} {path}"),
            }
        )
    return records


def run_search(client: Client, search: dict) -> SearchResult:
    """Verify project totals before expanding African projects to document records."""
    # Any blocked listing or detail page aborts this search without partial persistence.
    projects = list_projects(client, search)
    if projects.error:
        return SearchResult([], None, projects.pages, projects.error)
    # Open the African and unknown-geography project pages in parallel.
    selected = [
        project
        for project in projects.records
        if matching.is_african(f"{project['country']} {project['project_title']}")
        or unknown_geography(project["country"])
    ]
    pages = run_parallel(client, lambda project: client.get_html(project["web_url"]), selected)
    records = []
    for project, page in zip(selected, pages, strict=True):
        records.extend(project_documents(page, project_details(page, project)))
    notes = f"projects {len(projects.records)}/{projects.expected}; document links {len(records)}"
    return SearchResult(records, None, projects.pages, notes=notes)


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Apply document-family and agricultural adaptation evidence rules."""
    # Enabling activities and progress documents are outside implemented-action evaluations.
    if record.get("project_type") in SCOPE["enabling_activity_types"]:
        return "drop", "enabling_activity", []
    decision, reason = SCOPE["document_decisions"].get(
        record.get("doc_type", "Other"), SCOPE["document_decisions"]["Other"]
    )
    if decision == "drop":
        return "drop", reason, []
    if not matching.is_african(f"{record.get('country', '')} {record.get('project_title', '')}"):
        if record.get("geography_unknown"):
            return "to_screen", "unknown_country", []
        return "drop", "no_african_country", []
    if decision == "to_screen":
        return "to_screen", reason, []
    words = matching.find_keywords(record.get("project_title", ""))
    if words:
        return "in_scope", "agriculture_or_adaptation_evidence", words
    return "to_screen", "insufficient_metadata", []


def pdf_urls(record: dict) -> list[str]:
    """Return the document link when it is a supported file type (PDF, Word, Excel ...)."""
    url = record.get("pdf_url", "")
    return [url] if Path(urlsplit(url).path).suffix.lower() in storage.DOCUMENT_EXTENSIONS else []
