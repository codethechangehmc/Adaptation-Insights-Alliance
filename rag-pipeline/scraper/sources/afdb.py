"""African Development Bank category listings and IDEV evaluation taxonomy.

Source: https://www.afdb.org and https://idev.afdb.org/en/page/evaluations/search
Strategy: PCR and full evaluation umbrella; five runtime IDEV categories.
Pagination: zero-based page, checked against last-page pager (2026-10-15).
Query cap: none advertised; PCR listing exposes page59, IDEV unfiltered page93.
Kept: completion, validation and project evaluation documents.
Dropped: proposals, progress reports, non-English documents and policy support.
Quirks: warm homepage session, gzip/deflate only; optional manual CSV if blocked.
"""

from __future__ import annotations

import csv
import json
import re
from argparse import ArgumentParser, Namespace
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlsplit

from bs4 import BeautifulSoup, Tag

from core.fetch import Client, RequestFailed
from core.matching import find_countries, find_keywords, is_african
from core.searching import SearchResult

SOURCE = "afdb"
REPO = Path(__file__).resolve().parents[3]
SCOPE_FILE = Path(__file__).resolve().parents[1] / "config" / "afdb_scope.json"
SCOPE = json.loads(SCOPE_FILE.read_text(encoding="utf-8"))
BASE = "https://www.afdb.org"
IDEV = "https://idev.afdb.org"
IDEV_SEARCH = IDEV + "/en/page/evaluations/search"
HEADERS = {"Accept-Encoding": "gzip, deflate", "Accept-Language": "en-US,en;q=0.9"}
EXTRA_FIELDS = ["abstract", "topics", "project_code", "retrieval_channel"]
IDEV_TYPES = {value.casefold() for value in SCOPE["idev_categories"]}
PROJECT_CODE = re.compile(r"(?<![A-Z0-9])P-[A-Z0-9]{2}-[A-Z0-9]{3}-\d{3}(?![A-Z0-9])", re.I)


def add_arguments(parser: ArgumentParser) -> None:
    """Allow a complete browser-exported CSV instead of network enumeration."""
    parser.add_argument(
        "--manual-listing",
        type=Path,
        help="Complete CSV listing with title, web_url, doc_date and optional metadata",
    )


def plan_searches(args: Namespace) -> list[dict]:
    """List PCR, the current evaluation umbrella, and the runtime IDEV sweep."""
    if args.manual_listing:
        return [{"name": "afdb_manual_listing", "manual_listing": str(args.manual_listing)}]

    # Legacy subcategory URLs redirect to a different taxonomy; enumerate their full parent.
    return [
        {"name": "afdb_" + name, "url": BASE + path, "channel": "afdb"}
        for name, path in SCOPE["listing_paths"].items()
    ] + [{"name": "afdb_idev", "url": IDEV_SEARCH, "channel": "idev"}]


def publication_date(value: str) -> str:
    """Read the two date formats shown by the source listings."""
    for pattern in ["%d-%b-%Y", "%d/%m/%Y"]:
        try:
            return datetime.strptime(value.strip(), pattern).date().isoformat()
        except ValueError:
            continue
    return value[:10] if re.match(r"\d{4}-\d{2}-\d{2}", value) else ""


def listing_records(page: BeautifulSoup, url: str, channel: str) -> list[dict]:
    """Read the dated document cards of one listing page, without opening each document."""
    records = []
    container = page.select_one("main") or page
    for link in container.select(".view-content .views-field-title a[href]"):
        if not re.search(r"/en/documents?/", link["href"]):
            continue

        # IDEV cards are views-row elements; AfDB cards are the column div three levels
        # above the title link (checked 2026-10-15).
        if channel == "idev":
            card = link.find_parent(class_="views-row")
        else:
            card = link.parent.parent.parent
        date = card.select_one(".views-field-field-publication-date, .views-field-field-date")
        if date is None:
            raise ValueError(f"AfDB listing publication field missing: {link['href']}")
        records.append(card_record(card, link, url, channel, date.get_text(strip=True)))
    return records


def card_record(card: Tag, link: Tag, url: str, channel: str, date: str) -> dict:
    """Return the record for one listing card."""
    title = link.get_text(" ", strip=True)
    web_url = urljoin(url, link["href"])
    code = PROJECT_CODE.search(str(card))
    project_code = code[0].upper() if code else ""

    # The type field is missing on the evaluation umbrella listing; the title stands in elsewhere.
    type_field = card.select_one(".views-field-field-document-type")
    if type_field:
        doc_type = type_field.get_text(strip=True)
    elif urlsplit(url).path.endswith("/evaluation-reports"):
        doc_type = "Evaluation report"
    else:
        doc_type = title
    return {
        "source": SOURCE,
        "id": channel + ":" + web_url.rsplit("/", 1)[-1],
        "title": title,
        "doc_date": publication_date(date),
        "doc_type": doc_type,
        "country": ",".join(find_countries(title)) or "Africa",
        "language": "",
        "web_url": web_url,
        "project_code": project_code,
        "project_id": project_code,
        "pdf_url": "",
        "retrieval_channel": channel,
    }


def url_path(url: str) -> str:
    """Return a URL's path without a trailing slash."""
    return urlsplit(url).path.rstrip("/")


def last_page(page: BeautifulSoup, current: int) -> int:
    """Read the explicit last link or the largest visible pager number."""
    links = page.select(".pager-last a[href], .pager__item--last a[href]")
    if not links:
        links = page.select('a[href*="page="]')
    pages = [int(parse_qs(urlsplit(link["href"]).query)["page"][0]) for link in links]
    return max(pages, default=current)


def enumerate_listing(client: Client, url: str, channel: str, params: dict) -> SearchResult:
    """Reach the actual last page and reject repeated or unexpectedly empty pages."""
    records, seen, index, final, overlaps = [], set(), 0, None, 0
    while final is None or index <= final:
        # Preserve partial counts if DNS or another request failure interrupts a long sweep.
        try:
            page = client.get_html(url, params={**params, "page": index}, headers=HEADERS)
        except RequestFailed as error:
            return SearchResult(
                records,
                pages=index,
                error=str(error),
                notes=f"Stopped before page {index}; pager last {final}",
            )
        # An old category URL can land on another listing; its pager then points elsewhere.
        pager = page.select_one(".pager-last a[href]")
        if pager and url_path(urljoin(url, pager["href"])) != url_path(url):
            return SearchResult(
                records,
                pages=index + 1,
                error="Category resolved to a different taxonomy listing: " + pager["href"],
            )
        reported_last = last_page(page, index)
        final = max(final or 0, reported_last)
        rows = listing_records(page, url, channel)
        ids = [row["id"] for row in rows]
        if not rows or set(ids).issubset(seen):
            return SearchResult(
                records, pages=index + 1, error=f"Empty or repeated {channel} listing page {index}"
            )
        overlaps += len(ids) - len(set(ids) - seen)
        records.extend(row for row in rows if row["id"] not in seen)
        seen.update(ids)
        index += 1
    return SearchResult(
        records,
        pages=index,
        notes=f"Reached pager's final page {final}; {overlaps} overlapping rows",
    )


def idev_search(client: Client) -> SearchResult:
    """Resolve current category identifiers and enumerate each target category."""
    page = client.get_html(IDEV_SEARCH, headers=HEADERS)
    options = page.select('select[name="field_category_doc_target_id"] option')
    categories = {item.get_text(strip=True).lower(): item["value"] for item in options}
    if not IDEV_TYPES.issubset(categories):
        return SearchResult([], error="IDEV target category missing from runtime taxonomy")

    # Facet labels, rather than stored numeric IDs, define the five project-evaluation sweeps.
    results = [
        enumerate_listing(
            client, IDEV_SEARCH, "idev", {"field_category_doc_target_id": categories[name]}
        )
        for name in sorted(IDEV_TYPES)
    ]
    records = {row["id"]: row for result in results for row in result.records}
    return SearchResult(
        list(records.values()),
        pages=sum(result.pages for result in results),
        error="; ".join(result.error for result in results if result.error),
        notes="Enumerated five runtime taxonomy categories to final pager",
    )


def run_search(client: Client, search: dict) -> SearchResult:
    """Read an exported CSV or warm a normal session before live enumeration."""
    if search.get("manual_listing"):
        with Path(search["manual_listing"]).open(encoding="utf-8-sig", newline="") as handle:
            records = list(csv.DictReader(handle))
        for row in records:
            if not row.get("title") or not row.get("web_url"):
                return SearchResult([], error="Manual rows require title and web_url")
            row.update(
                source=SOURCE,
                id=row.get("id") or row["web_url"].rstrip("/"),
                country=row.get("country") or "Africa",
                retrieval_channel="manual",
            )
        return SearchResult(records, len(records), notes="User-supplied complete manual listing")

    # Home warm-up is part of a normal browser-like session, not a block workaround.
    client.get_html(urljoin(search["url"], "/"), headers=HEADERS)
    if search["channel"] == "idev":
        return idev_search(client)
    return enumerate_listing(client, search["url"], "afdb", {})


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Apply evaluation type and agriculture-code or keyword evidence."""
    title = record.get("title", "")
    if record.get("country") and not is_african(record["country"] + " " + title):
        return "drop", "no_african_country", []
    if re.search(r"appraisal|proposal|environmental and social|progress report", title, re.I):
        return "drop", "proposal_or_progress_document", []
    if re.search(r"budget support|policy.based|governance support|fiscal sustain", title, re.I):
        return "drop", "policy_or_budget_support", []
    if not re.search(
        r"complet|evaluat|validation|\bpcr\b|\bpper\b|mid.term review",
        title + " " + record.get("doc_type", ""),
        re.I,
    ):
        return "drop", "non_evaluation_document", []
    code = record.get("project_code") or record.get("project_id", "")
    if re.fullmatch(r"P-[A-Z0-9]{2}-A[A-Z0-9]{2}-\d{3}", code, re.I):
        return "in_scope", "agriculture_project_code", ["project_code:" + code]
    keywords = find_keywords(title + " " + record.get("abstract", ""))
    if keywords:
        return "in_scope", "evaluation_scope_keywords", keywords
    return "drop", "no_agriculture_or_adaptation_evidence", []


def pdf_urls(record: dict) -> list[str]:
    """Return a direct URL when supplied by the manual listing."""
    return [record["pdf_url"]] if record.get("pdf_url") else []


def resolve_pdf_urls(client: Client, record: dict) -> list[str]:
    """Resolve file fields or the AfDB embedded PDF viewer at download time."""
    urls = pdf_urls(record)
    if urls:
        return urls
    page = client.get_html(record["web_url"], headers=HEADERS)
    body = page.select_one("main") or page
    files = body.select("a[href], iframe[data-src], iframe[src]")
    urls = []
    for item in files:
        # R also supports older plain anchors and pdf.js file parameters (checked 2026-10-22).
        target = item.get("data-src") or item.get("href") or item.get("src", "")
        target = parse_qs(urlsplit(target).query).get("file", [target])[0]
        urls.append(urljoin(record["web_url"], target))
    return list(dict.fromkeys(url for url in urls if re.search(r"\.pdf(?:[?#]|$)", url, re.I)))
