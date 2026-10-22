"""Adaptation Fund evaluation documents through Climate Policy Radar.

Source: https://api.climatepolicyradar.org
Strategy: fund, project and regional filters, then complete family expansion.
Pagination: page_token, one-based pages (checked 2026-10-15).
Query cap: none observed through the global total of 63,987 (2026-10-15).
Kept: evaluations and completion reports. Dropped: proposal/progress documents.
Quirks: family approval is not a document date; completion is a fallback only.
"""

from __future__ import annotations

import json
from argparse import Namespace
from pathlib import Path

from core.fetch import Client
from core.searching import SearchResult
from sources import cpr
from sources.cpr import classify as classify
from sources.cpr import pdf_urls as pdf_urls

SOURCE = "af"
REPO = Path(__file__).resolve().parents[3]
SCOPE_FILE = Path(__file__).resolve().parents[1] / "config" / "af_scope.json"
SCOPE = json.loads(SCOPE_FILE.read_text(encoding="utf-8"))
EXTRA_FIELDS = cpr.EXTRA_FIELDS


def plan_searches(args: Namespace) -> list[dict]:
    """List the complete, region-filtered fund enumeration."""
    return [{"name": "af_african_and_international_families"}]


def run_search(client: Client, search: dict) -> SearchResult:
    """Retrieve every African or international project document."""
    return cpr.run_search(
        client, SOURCE, SCOPE["fund"], "AF.", SCOPE["page_size"], SCOPE["regions"]
    )
