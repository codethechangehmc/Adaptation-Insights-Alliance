"""Recover GEF report years from local files, without trusting PDF creation dates.

PDF text uses optional PyMuPDF, restricted to this helper. Month-name dates on
the first eight pages take priority, then filenames, then OOXML creation dates.
Running headers may occur anywhere in extracted text (checked 2026-10-15).
"""

from __future__ import annotations

import argparse
import logging
import re
import unicodedata
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path
from urllib.parse import unquote, urlsplit
from zipfile import BadZipFile, ZipFile

from core.storage import read_csv, write_csv

REPO = Path(__file__).resolve().parents[3]
LOG = logging.getLogger("gef_doc_dates")
MONTHS = (
    "january february march april may june july august september october november december "
    "janvier fevrier mars avril mai juin juillet aout septembre octobre novembre decembre "
    "janeiro fevereiro marco abril maio junho julho agosto setembro outubro novembro dezembro "
    "enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre"
)
MONTH_PATTERN = "|".join(sorted(set(MONTHS.split()), key=len, reverse=True))
DATE_PATTERN = re.compile(
    rf"\b(?:{MONTH_PATTERN})\b\.?,?\s+(?:\d{{1,2}}\s*,?\s+)?(?:de\s+)?((?:19|20)\d{{2}})\b",
    re.IGNORECASE,
)
FIELDS = [
    "id",
    "filename",
    "scanned",
    "year_text",
    "year_filename",
    "year_meta",
    "final_year",
    "method",
    "error",
]


def latest_year(years: list[str]) -> str:
    """Return the latest plausible report year through the current year."""
    # Future planned dates do not establish a report date.
    valid = [int(year) for year in years if 1991 <= int(year) <= date.today().year]
    return str(max(valid)) if valid else ""


def year_from_text(text: str) -> str:
    """Find month-name dates anywhere in text and choose the latest year."""
    # Normalize accents and whitespace without depending on running-header order.
    normalized = "".join(
        char for char in unicodedata.normalize("NFKD", text) if not unicodedata.combining(char)
    )
    return latest_year(DATE_PATTERN.findall(normalized))


def year_from_filename(filename: str) -> str:
    """Read isolated years, excluding digits embedded in identifiers or hashes."""
    # Boundaries reject project numbers and stable URL hash IDs.
    return latest_year(re.findall(r"(?<![A-Za-z0-9])((?:19|20)\d{2})(?![A-Za-z0-9])", filename))


def ooxml_text_and_year(path: Path) -> tuple[str, str]:
    """Read document body text and the original OOXML creation year."""
    # OOXML dates retain authoring provenance, unlike regenerated PDF metadata.
    with ZipFile(path) as archive:
        text, year = "", ""
        if "word/document.xml" in archive.namelist():
            # Match R's raw XML and body bounds; later planned dates skew 10817 (2026-10-22).
            raw = archive.read("word/document.xml").decode("utf-8")[:100000]
            text = re.sub(r"<[^>]+>", " ", raw)[:20000]
        if "docProps/core.xml" in archive.namelist():
            root = ET.fromstring(archive.read("docProps/core.xml"))
            created = root.find("{http://purl.org/dc/terms/}created")
            if created is not None and created.text:
                year = latest_year(re.findall(r"^((?:19|20)\d{2})", created.text))
    return text, year


def pdf_text(path: Path, pages: int | None) -> str:
    """Read the requested PDF pages, or the whole document, using optional PyMuPDF."""
    # This helper is the only retrieval module allowed to import PyMuPDF.
    try:
        import pymupdf
    except ImportError as error:
        raise RuntimeError("PDF date recovery requires optional PyMuPDF") from error
    with pymupdf.open(path) as document:
        count = len(document) if pages is None else min(pages, len(document))
        return "\n".join(document[index].get_text() for index in range(count))


def inspect_file(
    path: Path, identifier: str = "", pages: int = 8, original_name: str = ""
) -> dict:
    """Recover a file's year, and report unreadable and scanned files."""
    row = dict.fromkeys(FIELDS, "")
    row.update(id=identifier, filename=path.name, scanned=False, method="none")

    # Read the first pages of a PDF, or the body and creation date of a Word or Excel file.
    # A file that cannot be read is reported as an error, never as scanned.
    text, deep = "", False
    try:
        if path.suffix.lower() == ".pdf":
            text = pdf_text(path, pages)
            row["scanned"] = len(re.sub(r"\s", "", text)) < 400

            # Some evaluations give the report date only in an annex: read the whole file.
            if not year_from_text(text):
                text, deep = pdf_text(path, None), True
        elif path.suffix.lower() in {".docx", ".xlsx"}:
            text, row["year_meta"] = ooxml_text_and_year(path)
    except (OSError, ValueError, RuntimeError, BadZipFile, ET.ParseError) as error:
        row["error"] = str(error)

    # Prefer the report text, then the original file name, then the Office creation date.
    # Our own gef_... names hold no date evidence.
    row["year_text"] = year_from_text(text)
    name = original_name or ("" if path.name.startswith("gef_") else path.name)
    row["year_filename"] = year_from_filename(name)
    methods = {
        "year_text": "text_deep" if deep else "text",
        "year_filename": "filename",
        "year_meta": "ooxml_created",
    }
    for key, method in methods.items():
        if row[key]:
            row.update(final_year=row[key], method=method)
            break
    return row


def catalogue_files(path: Path) -> dict[str, dict]:
    """Map local filenames to catalogue records for IDs and original source filenames."""
    # Scraper-generated filenames must not be mistaken for original report date evidence.
    rows = read_csv(path) if path.exists() else []
    return {row["filename"]: row for row in rows if row.get("filename")}


def main(argv: list[str] | None = None) -> int:
    """Write recovered years for local GEF files and their stable catalogue IDs."""
    # Defaults match the scraper, with review folders selectable explicitly.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download-dir", "--pdf-dir", type=Path, default=REPO / "downloads/gef")
    parser.add_argument("--output-dir", type=Path, default=REPO / "outputs/gef")
    parser.add_argument("--pages", type=int, default=8)
    args = parser.parse_args(argv)
    if args.pages < 1:
        parser.error("--pages must be positive")
    if not args.download_dir.is_dir():
        parser.error("--download-dir must be an existing directory")
    records = catalogue_files(args.output_dir / "gef_metadata.csv")

    # Keep rows for unsupported formats so missing dates remain visible.
    rows = []
    for path in sorted(args.download_dir.glob("*")):
        if not path.is_file() or path.suffix == ".part":
            continue
        record = records.get(path.name, {})
        original = unquote(urlsplit(record.get("pdf_url", "")).path).rsplit("/", 1)[-1]
        rows.append(inspect_file(path, record.get("id", ""), args.pages, original))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(args.output_dir / "gef_doc_dates.csv", rows, FIELDS)
    LOG.info(
        "Recovered dates for %d files; %d errors",
        len(rows),
        sum(bool(row["error"]) for row in rows),
    )
    return int(any(row["error"] for row in rows))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    raise SystemExit(main())
