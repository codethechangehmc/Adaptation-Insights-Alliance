"""IFAD project documents, through the D-Portal copy of IFAD's IATI data.

Source:     IATI activities of publisher XM-DAC-41108 (IFAD) on https://d-portal.org
Strategy:   complete publisher listing: q.json?select=count for the total, then
            q.xml pages with the full IATI activities; every document link of an
            activity becomes one record (checked 2026-10-15)
Pagination: limit and offset, ordered by activity ID; q.xml reports no total, so the
            total comes from q.json?select=count with the same filters (checked 2026-10-15)
Query cap:  none found: limit=30000 returned all 25,360 activities of GB-GOV-1 in one
            page; max_results_per_query is null. IFAD has 1,280 activities
            (checked 2026-10-15)
Kept:       evaluations, completion reports and mid-term reviews
Dropped:    proposals, supervision and progress documents
Quirks:     website document URLs may be landing pages; resolve them only at download time

Run: python rag-pipeline/scraper/run.py ifad --help
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import date
from pathlib import Path
from urllib.parse import urljoin, urlsplit

from bs4 import Tag

from core import matching
from core.fetch import Client
from core.searching import SearchResult

SOURCE = "ifad"
REPO = Path(__file__).resolve().parents[3]
SCOPE_FILE = Path(__file__).resolve().parents[1] / "config" / "ifad_scope.json"
SCOPE = json.loads(SCOPE_FILE.read_text(encoding="utf-8"))

COUNT_API = "https://d-portal.org/q.json"
ACTIVITY_API = "https://d-portal.org/q.xml"
EXTRA_FIELDS = ["project_title", "description", "project_end_date", "categories", "sectors"]
# IATI recipient-region codes for Africa and its sub-regions.
AFRICAN_REGION_CODES = {"298", "289", "189", "1027", "1028", "1029", "1030", "1031"}


def add_arguments(parser: argparse.ArgumentParser) -> None:
    """Add the IFAD options."""
    # Selection applies after the complete publisher listing.
    parser.add_argument(
        "--countries",
        nargs="+",
        help="list only these ISO country codes, for example KE ET (default: all African)",
    )


def plan_searches(args: argparse.Namespace) -> list[dict]:
    """List the publisher once, retaining regional and multi-country activities."""
    # Country selection applies locally so regional activities remain discoverable.
    codes = [code.upper() for code in args.countries or SCOPE["countries"]]
    unknown = [code for code in codes if code not in SCOPE["countries"]]
    if unknown:
        raise ValueError(f"Not African country codes in ifad_scope.json: {unknown}")
    return [{"name": "IFAD all activities", "countries": codes}]


def list_activities(client: Client) -> SearchResult:
    """Count and list every activity with the same publisher-only filters."""
    # Country and document dates apply locally, preserving regional activities.
    filters = {"reporting_ref": SCOPE["publisher_ref"]}
    payload = client.get_json(COUNT_API, params={**filters, "select": "count"})
    return fetch_activity_pages(client, filters, int(payload["rows"][0]["count"]))


def fetch_activity_pages(client: Client, filters: dict, total: int) -> SearchResult:
    """Page through q.xml until the counted total is reached."""
    # Stable ordering prevents offset pages from overlapping.
    activities: list[dict] = []
    seen: set[str] = set()
    pages = 0
    while len(activities) < total:
        params = {
            **filters,
            "orderby": "aid",
            "limit": SCOPE["page_size"],
            "offset": len(activities),
        }
        tags = client.get_xml(ACTIVITY_API, params=params).find_all("iati-activity")
        page = [parse_activity(tag) for tag in tags]
        pages += 1

        # IDs must not repeat and a page must not be empty before the total.
        for activity in page:
            if activity["id"] in seen:
                return SearchResult(activities, total, pages, f"ID {activity['id']} repeated")
            seen.add(activity["id"])
            activities.append(activity)
        if not page:
            error = f"empty page at offset {len(activities)} of {total}"
            return SearchResult(activities, total, pages, error)
    return SearchResult(activities, total, pages)


def narrative(parent: Tag | None, child: str) -> str:
    """Return the English narrative text of one child element, else the first one."""
    # Preserve a title even when an English translation is unavailable.
    element = parent.find(child, recursive=False) if parent else None
    if element is None:
        return ""
    texts = element.find_all("narrative")
    english = [text for text in texts if text.get("xml:lang", "").lower() == "en"]
    chosen = (english or texts)[:1]
    return " ".join(chosen[0].get_text().split()) if chosen else ""


def activity_dates(tag: Tag) -> dict[str, str]:
    """Return the activity's dates by IATI type: 1 planned start, 2 start, 3 planned end, 4 end."""
    # Planned end dates are not used as completed-project dates.
    dates = {}
    for element in tag.find_all("activity-date", recursive=False):
        dates[element.get("type", "")] = element.get("iso-date", "")[:10]
    return dates


def parse_activity(tag: Tag) -> dict:
    """Read one IATI activity into a plain dict."""
    # Keep regional geography alongside explicit recipient countries.
    activity_id = tag.find("iati-identifier").get_text(strip=True)
    status = tag.find("activity-status", recursive=False)
    countries = [element.get("code", "").upper() for element in tag.find_all("recipient-country")]
    sectors = [element.get("code", "") for element in tag.find_all("sector", recursive=False)]
    return {
        "id": activity_id,
        "title": narrative(tag, "title"),
        "description": narrative(tag, "description"),
        "status": status.get("code", "") if status else "",
        "dates": activity_dates(tag),
        "countries": countries,
        "regions": [element.get("code", "") for element in tag.find_all("recipient-region")],
        "sectors": sectors,
        "documents": [parse_document_link(link) for link in tag.find_all("document-link")],
    }


def parse_document_link(tag: Tag) -> dict:
    """Read one IATI document link into a plain dict."""
    # Relative IATI URLs refer to IFAD, not to the D-Portal mirror.
    document_date = tag.find("document-date")
    title = narrative(tag, "title")
    return {
        "url": urljoin("https://www.ifad.org", tag.get("url", "").strip()),
        "format": tag.get("format", "").strip(),
        "title": title,
        "categories": [element.get("code", "") for element in tag.find_all("category")],
        "languages": [element.get("code", "") for element in tag.find_all("language")],
        "date": document_date.get("iso-date", "")[:10] if document_date else title_year(title),
    }


def title_year(title: str) -> str:
    """Recover a document title's explicit year without mistaking a project ID for a date."""
    # IATI document titles often provide a year while document-date is absent.
    years = [int(year) for year in re.findall(r"(?<!\d)((?:19|20)\d{2})(?!\d)", title)]
    valid = [year for year in years if 1991 <= year <= date.today().year]
    return str(max(valid)) if valid else ""


def run_search(client: Client, search: dict) -> SearchResult:
    """Verify all activities before expanding them into document records."""
    # Activity totals cannot be compared directly with expanded document counts.
    activities = list_activities(client)
    if activities.expected != len(activities.records) and not activities.error:
        activities.error = "Activity listing did not reach its counted total"
    records = [
        document_record(activity, document, search.get("countries", list(SCOPE["countries"])))
        for activity in activities.records
        for document in activity["documents"]
    ]
    notes = (
        f"activities {len(activities.records)}/{activities.expected}; "
        f"document links {len(records)}"
    )
    return SearchResult(records, None, activities.pages, activities.error, notes)


def document_record(activity: dict, document: dict, countries: list[str]) -> dict:
    """Preserve activity provenance and dates on each document link."""
    # Hash URLs so IDs remain stable across page order and duplicate titles.
    digest = hashlib.sha256(document["url"].encode()).hexdigest()[:16]
    names = [SCOPE["countries"][code] for code in activity["countries"] if code in countries]
    text = f"{activity['title']} {activity['description']}"
    regional = bool(AFRICAN_REGION_CODES.intersection(activity["regions"]))
    if not names and not activity["countries"]:
        names = matching.find_countries(text)
        if regional or matching.is_african(text):
            names.append("Africa")
    return {
        "source": SOURCE,
        "id": f"{activity['id']}_{digest}",
        "title": document["title"] or activity["title"],
        "project_title": activity["title"],
        "description": activity["description"],
        "project_id": activity["id"].rsplit("-", 1)[-1],
        "country": ",".join(names),
        "language": ",".join(document["languages"]),
        "doc_date": document["date"],
        "project_end_date": activity["dates"].get("4", ""),
        "pdf_url": document["url"],
        "web_url": document["url"],
        "categories": ",".join(document["categories"]),
        "sectors": ",".join(activity["sectors"]),
        "doc_type": document_type(document["title"], document["categories"]),
    }


def document_type(title: str, categories: list[str]) -> str:
    """Identify evaluation families before applying broad IATI categories."""
    # Completion reports can carry the same IATI category as supervision documents.
    for name, pattern in SCOPE["document_types"].items():
        if re.search(pattern, title, re.IGNORECASE):
            return name
    if "A12" in categories:
        return "Administrative"
    if "A08" in categories or "B05" in categories or "B09" in categories:
        return "Evaluation"
    if set(categories) & {"A01", "A02", "A04"}:
        return "Proposal"
    if set(categories) & {"A06", "A07"}:
        return "Progress Report"
    return "Other"


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Return status, reason and matched keywords for one IFAD document."""
    # Apply document family before agriculture evidence.
    if not matching.is_african(record.get("country", "")):
        return "drop", "no_african_country", []
    kind = record.get("doc_type", "Other")
    if kind == "Proposal":
        return "drop", "proposal_stage", []
    if kind == "Progress Report":
        return "drop", "progress_report", []
    if kind == "Administrative":
        return "drop", "other_document_type", []
    if kind == "Other":
        return "to_screen", "unknown_document_type", []
    keywords = matching.find_keywords(f"{record['title']} {record.get('project_title', '')}")
    agriculture = any(
        code.startswith(("311", "312", "313")) for code in record.get("sectors", "").split(",")
    )
    if keywords or agriculture:
        return "in_scope", "agriculture_or_adaptation_evidence", keywords
    return "to_screen", "insufficient_metadata", []


def pdf_urls(record: dict) -> list[str]:
    """Return the document link of one record."""
    # Keep original landing links available in metadata-only runs.
    return [record["pdf_url"]] if record.get("pdf_url") else []


def resolve_pdf_urls(client: Client, record: dict) -> list[str]:
    """Resolve a public landing page without changing the stored document link."""
    # Direct PDF URLs do not need a landing-page request.
    url = record.get("pdf_url", "")
    if (
        not url
        or urlsplit(url).path.lower().endswith(".pdf")
        or "/documents/" in urlsplit(url).path
    ):
        return pdf_urls(record)
    page = client.get_html(url)
    links = [
        urljoin(url, tag["href"])
        for tag in page.select("a[href]")
        if ".pdf" in tag["href"].lower() or "/documents/" in tag["href"]
    ]
    return list(dict.fromkeys(links))
