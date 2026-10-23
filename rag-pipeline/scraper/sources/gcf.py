"""Green Climate Fund website evaluation listing and CPR gap fill.

Source: https://www.greenclimate.fund/portfolio/projects
Strategy: Africa/adaptation projects across all statuses, document-type listing.
Pagination: zero-based fragment pages with rel=next pager (checked 2026-10-15).
Query cap: none advertised; follow every next page and verify empty terminal page.
Kept: evaluation and completion reports. Dropped: funding proposals.
Quirks: old Drupal /views/ajax is gone; current GET fragments return HTML in JSON.
"""

from __future__ import annotations

import json
import re
from argparse import Namespace
from pathlib import Path
from urllib.parse import urljoin

from bs4 import BeautifulSoup

from core.fetch import Client
from core.matching import parse_date
from core.searching import SearchResult
from sources import cpr
from sources.cpr import classify as classify
from sources.cpr import pdf_urls as pdf_urls

SOURCE = "gcf"
REPO = Path(__file__).resolve().parents[3]
SCOPE_FILE = Path(__file__).resolve().parents[1] / "config" / "gcf_scope.json"
SCOPE = json.loads(SCOPE_FILE.read_text(encoding="utf-8"))
BASE = "https://www.greenclimate.fund"
EXTRA_FIELDS = cpr.EXTRA_FIELDS
DOCUMENT_TYPES = SCOPE["document_types"]


def plan_searches(args: Namespace) -> list[dict]:
    """Plan website discovery and the independent CPR gap-fill channel."""
    return [{"name": "gcf_website", "channel": "website"}, {"name": "gcf_cpr", "channel": "cpr"}]


def fragment_pages(client: Client, kind: str, params: dict) -> list[BeautifulSoup]:
    """Read every fragment page, checking a further empty page at the end."""
    # Verified 2026-10-15: pagers are HTML and expose a normal rel=next link.
    pages, seen, page = [], set(), 0
    expect_empty = False
    selector = 'a[href*="/portfolio/projects/"]'
    if kind == "documents":
        selector = '[data-component="cards:document"] a[href]'
    while True:
        payload = client.get_json(
            BASE + f"/gcf/fragments/{kind}-browse", params={**params, "page": page}
        )
        soup = BeautifulSoup(payload["results_html"], "lxml")
        links = [link["href"] for link in soup.select(selector)]
        if expect_empty and links:
            raise ValueError(f"GCF {kind} pager omitted further results")
        if not links:
            if not pages:
                raise ValueError(f"GCF {kind} listing unexpectedly empty")
            return pages
        if seen.intersection(links) or len(set(links)) != len(links):
            raise ValueError(f"GCF {kind} repeated a page")
        seen.update(links)
        pages.append(soup)
        pager = BeautifulSoup(payload.get("pager_html", ""), "lxml")
        expect_empty = not pager.select_one('a[rel="next"]')
        page += 1


def project_map(pages: list[BeautifulSoup]) -> dict[str, dict]:
    """Extract project identifiers, titles and countries from table fragments."""
    # Table labels are present on current FP305 and SAP067 (2026-10-15).
    projects = {}
    for page in pages:
        for link in page.select('a[href*="/portfolio/projects/"]'):
            identifier = link["href"].rstrip("/").rsplit("/", 1)[-1].upper()
            title = link.select_one('[aria-label="Title"]')
            country = link.select_one('[aria-label="Country"]')
            if title is None or country is None:
                raise ValueError(f"GCF project fields missing: {identifier}")
            projects[identifier] = {
                "project_title": title.get_text(" ", strip=True),
                "country": country.get_text(" ", strip=True),
            }
    return projects


def document_records(pages: list[BeautifulSoup], projects: dict[str, dict]) -> list[dict]:
    """Read document cards and retain the selected African project membership."""
    records = []
    for page in pages:
        for card in page.select('[data-component="cards:document"]'):
            link = card.select_one("a[href]")
            title = card.select_one("p.f-body-bold").get_text(" ", strip=True)
            captions = [item.get_text(" ", strip=True) for item in card.select("p.f-caption")]
            ids = re.findall(r"\b(?:FP|SAP)\d+\b", card.get_text(" ", strip=True))
            project_ids = list(dict.fromkeys(value for value in ids if value in projects))
            if not project_ids:
                continue
            date = next((parse_date(value) for value in captions if parse_date(value)), None)
            url = urljoin(BASE, link["href"])
            records.append(
                {
                    "source": SOURCE,
                    "id": url.rsplit("/", 1)[-1],
                    "title": title,
                    "doc_type": captions[0] if captions else "",
                    "doc_date": date.isoformat() if date else "",
                    "language": "en",
                    "project_id": ";".join(project_ids),
                    "web_url": url,
                    "pdf_url": "",
                    "retrieval_channel": "website",
                    "project_title": "; ".join(
                        projects[value]["project_title"] for value in project_ids
                    ),
                    "country": ",".join(
                        dict.fromkeys(projects[value]["country"] for value in project_ids)
                    ),
                }
            )
    return records


def run_search(client: Client, search: dict) -> SearchResult:
    """Enumerate website listings or every filtered CPR family."""
    if search["channel"] == "cpr":
        return cpr.run_search(client, SOURCE, SCOPE["cpr_fund"], "GCF.")

    # Status is deliberately unfiltered: FP049 has a final evaluation while under implementation.
    project_pages = fragment_pages(
        client,
        "projects",
        {
            "region[]": SCOPE["project_filters"]["region"],
            "theme[]": SCOPE["project_filters"]["theme"],
            "layout": "table",
        },
    )
    projects = project_map(project_pages)
    document_pages = fragment_pages(client, "documents", {"type[]": DOCUMENT_TYPES})
    records = document_records(document_pages, projects)
    return SearchResult(
        records,
        pages=len(project_pages) + len(document_pages),
        notes=f"{len(projects)} African adaptation projects; full document pager",
    )


def resolve_pdf_urls(client: Client, record: dict) -> list[str]:
    """Resolve website document-page file links when downloading a kept record."""
    if record.get("retrieval_channel") != "website":
        return pdf_urls(record)

    # File anchors on current GCF document detail pages point directly to PDFs.
    page = client.get_html(record["web_url"])
    page = page.select_one("main") or page
    return list(
        dict.fromkeys(
            urljoin(BASE, link["href"])
            for link in page.select("a[href]")
            if re.search(r"\.pdf(?:[?#]|$)", link["href"], re.IGNORECASE)
        )
    )
