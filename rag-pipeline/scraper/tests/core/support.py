"""Small synthetic records, responses and sources for offline core tests."""

from __future__ import annotations

import io
import types
from pathlib import Path

import requests

from core.fetch import Client, RequestFailed
from core.searching import SearchResult

PDF = b"%PDF-1.7\n" + b"padding " * 2000 + b"\n%%EOF\n"
OTHER_PDF = b"%PDF-1.7\n" + b"changed " * 2000 + b"\n%%EOF\n"


def record(doc_id: str, title: str = "Kenya farm project", **fields: str) -> dict:
    """Return a minimal record for runner tests."""
    return {
        "id": doc_id,
        "title": title,
        "pdf_url": f"https://example.org/{doc_id}.pdf",
        "doc_date": "2020-01-01",
        "country": "Kenya",
        "language": "English",
        "project_id": "",
        **fields,
    }


def fake_source(root: Path, searches: dict[str, list[dict]], errors: dict | None = None) -> object:
    """Build a source module whose searches return the given records."""
    errors = errors or {}
    source = types.ModuleType("fake")
    source.__doc__ = "Fake source for tests."
    source.SOURCE = "fake"
    source.REPO = root
    source.plan_searches = lambda args: [{"name": name} for name in searches]
    source.run_search = lambda client, search: SearchResult(
        [dict(item) for item in searches[search["name"]]],
        expected=len(searches[search["name"]]),
        error=errors.get(search["name"], ""),
    )
    source.classify = lambda item: (
        ("in_scope", "title_keywords", ["farm"])
        if "farm" in item["title"]
        else ("drop", "no_agriculture_or_adaptation_evidence", [])
    )
    source.pdf_urls = lambda item: [item["pdf_url"]] if item.get("pdf_url") else []
    return source


def response(status: int, headers: dict | None = None) -> requests.Response:
    """Return a bare HTTP response with an empty body."""
    reply = requests.Response()
    reply.status_code = status
    reply.headers.update(headers or {})
    reply.raw = io.BytesIO(b"")
    return reply


def write_pdf(client: Client, url: str, part_path: Path) -> dict:
    """Stand in for Client.download: write a valid PDF."""
    part_path.write_bytes(PDF)
    return {"resolved_url": url, "bytes": len(PDF)}


def fail_download(client: Client, url: str, part_path: Path) -> dict:
    """Stand in for Client.download: fail like a dead link."""
    raise RequestFailed(url, "HTTP 404", 404)
