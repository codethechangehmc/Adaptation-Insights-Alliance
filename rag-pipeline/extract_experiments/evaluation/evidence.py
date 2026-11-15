"""Check source occurrences separately from human judgements of meaning."""

import re
from functools import lru_cache
from pathlib import Path

from common.files import contains, fingerprint, norm


def prediction_id(job: dict, fact: dict, index: int) -> str:
    """Bind human judgements to answer content, not merely a reusable task position."""
    return job["id"] + ":" + fingerprint([index, fact])[:16]


@lru_cache(maxsize=16)
def pdf_pages(path: Path) -> tuple[str, ...]:
    """Read an independent PDF text layer for offline citation checks.

    A word split by a line-end hyphen ("im-\\nproves") is also kept joined, so a
    correct quote still matches (P007 page 6). The original text stays first, so
    real hyphenated words still match too.
    """
    import pymupdf

    with pymupdf.open(path) as document:
        pages = [page.get_text() for page in document]
    joined = [re.sub(r"(\w)-[ \t]*\n[ \t]*(\w)", r"\1\2", text) for text in pages]
    return tuple(
        text if text == fixed else text + "\n" + fixed
        for text, fixed in zip(pages, joined, strict=True)
    )


def quote_pages(quote: str, pages: tuple[str, ...]) -> list[int]:
    """Return the 1-based pages whose text contains the quote."""
    if len(norm(quote)) < 8:
        return []
    return [number for number, text in enumerate(pages, 1) if contains(quote, text)]


def check_quote(evidence: dict, pages: tuple[str, ...]) -> str:
    """Check exactly cited PDF pages, without neighboring-page or digit-only shortcuts."""
    if not evidence["quote"].strip():
        return "not_recorded"
    cited = evidence["pages"]
    if not cited or any(type(p) is not int or p < 1 or p > len(pages) for p in cited):
        return "invalid_page"
    quote = evidence["quote"].strip()
    if not quote or len(norm(quote)) < 8:
        return "too_short_to_verify"
    text = "\n".join(pages[p - 1] for p in cited)
    if quote in text and contains(quote, text):
        return "exact"
    if contains(quote, text):
        return "normalized"
    parts = quote.split(" ... ")
    if len(parts) > 1 and all(len(norm(part)) >= 8 and contains(part, text) for part in parts):
        return "joined_passages"
    if quote_pages(quote, pages):
        return "found_other_page"
    return "needs_visual_review" if len(norm(text)) < 30 else "not_found_needs_review"


def span_in_chunks(span: dict, chunks: list[dict]) -> bool:
    """Require a quotation on compatible pages; page overlap alone is insufficient."""
    quote = norm(span.get("quote", ""))
    if not quote:
        return False
    required = set(span.get("pages", []))
    compatible = [
        c
        for c in chunks
        if not required or required.intersection(range(c["pages"][0], c["pages"][1] + 1))
    ]
    return contains(span["quote"], "\n".join(c["text"] for c in compatible))


def evidence_covered(label: dict, chunks: list[dict]) -> bool | None:
    """Require every evidence group, allowing alternative spans within each group."""
    groups = label.get("evidence_groups", [])
    if not groups or any(
        not group or any(not s.get("quote") or not s.get("pages") for s in group)
        for group in groups
    ):
        return None
    return all(any(span_in_chunks(span, chunks) for span in group) for group in groups)
