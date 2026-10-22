"""Compare a Python scraper run with the R catalogue of the same source. Audit only.

Usage:
    python rag-pipeline/audit/compare_with_r.py <source> [--run RUN_DIR | --state DB]
        [--r-file CSV ...] [--download-dir DIR] [--adopt-local] [--export-inclusions CSV]

Reads persistent review state by default, or decisions.csv from --run, and the
saved R reference tables in catalogues/<source>/ and outputs/.
Writes rag-pipeline/data/<source>_review/r_comparison.csv
with one row per document kept by either side (both, r_only, python_only), with
the Python status and reason, and logs the counts.

This checks the new code. Nothing in scraper/ imports it; delete it when R is retired.
"""

from __future__ import annotations

import argparse
import logging
import re
import shutil
import sqlite3
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scraper"))
from core import classification, storage  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from reference_catalogues import (  # noqa: E402
    REPO,
    baseline_files,
    document_urls,
    is_document_page,
    load_baseline,
    read_rows,
    selected_rows,
    url_key,
)

LOG = logging.getLogger("audit")

FIELDS = [
    "id",
    "title",
    "membership",
    "r_status",
    "python_status",
    "python_reason",
    "match_key",
    "r_id",
    "python_id",
    "match_method",
    "filename",
    "sha256",
    "file_status",
    "rule_reason",
    "reference_ids",
    "reference_mapping",
    "reference_filename",
]


def is_kept(row: dict) -> bool:
    """Return True when Python keeps the record (in_scope or to_screen)."""
    return row.get("screen_status") in {"in_scope", "to_screen"}


def build_index(python_rows: list[dict]) -> dict[str, dict]:
    """Index the Python records by ID, stored reference label, file URL and document page."""
    index = {"id": {row["id"]: row for row in python_rows}, "alias": {}, "file": {}, "page": {}}
    for row in python_rows:
        # Reference labels count only on kept records.
        if is_kept(row):
            for label in classification.values(row.get("reference_ids")):
                index["alias"].setdefault(label, {})[row["id"]] = row
        for url in document_urls(row):
            index["file"].setdefault(url, []).append(row)
        if row.get("web_url"):
            index["page"].setdefault(url_key(row["web_url"]), []).append(row)
    return index


def match_one(reference: dict, index: dict[str, dict]) -> tuple[dict, dict, str]:
    """Return the reference, its Python record (or {}) and how they were matched.

    Tried in order: a stored reference label on exactly one kept record (it beats
    a dropped record with the same ID), the same ID, the same file URL (a kept copy
    first), and the same document page when only one record has it.
    """
    by_id = index["id"].get(reference["id"])
    labels = classification.values(reference.get("reference_ids"))
    aliases = {
        row["id"]: row for label in labels for row in index["alias"].get(label, {}).values()
    }
    if len(aliases) == 1 and (by_id is None or by_id.get("screen_status") == "drop"):
        return reference, next(iter(aliases.values())), "reference_alias"
    if by_id:
        return reference, by_id, "id"
    files = [row for url in document_urls(reference) for row in index["file"].get(url, [])]
    if files:
        return reference, max(files, key=is_kept), "file_url"
    page = reference.get("web_url", "")
    pages = index["page"].get(url_key(page), []) if page else []
    if len(pages) == 1 and is_document_page(page):
        return reference, pages[0], "document_page"
    return reference, {}, "unmatched"


def match_references(python_rows: list[dict], r_rows: list[dict]) -> list[tuple[dict, dict, str]]:
    """Match every reference row to a Python record."""
    index = build_index(python_rows)
    return [match_one(reference, index) for reference in r_rows]


def compare(python_rows: list[dict], r_rows: list[dict]) -> list[dict]:
    """Return one row per reference, then one per kept Python record no reference matched."""
    rows, matched = [], set()
    for reference, current, method in match_references(python_rows, r_rows):
        if current:
            matched.add(current["id"])
        rows.append(
            {
                "id": current.get("id", reference["id"]),
                "r_id": reference["id"],
                "python_id": current.get("id", ""),
                "title": reference.get("title", ""),
                "membership": "both" if is_kept(current) else "r_only",
                "r_status": reference.get("screen_status") or reference.get("status") or "listed",
                "python_status": current.get("screen_status", "not_retrieved"),
                "python_reason": current.get("filter_reason", "not_retrieved"),
                "match_method": method,
                "match_key": reference["id"],
                "filename": current.get("filename", ""),
                "sha256": current.get("sha256", ""),
                "rule_reason": current.get("rule_reason", ""),
                "reference_ids": reference.get("reference_ids", ""),
                "reference_mapping": reference.get("reference_mapping", ""),
                "reference_filename": reference.get("reference_filename", ""),
            }
        )
    for current in python_rows:
        if current["id"] not in matched and is_kept(current):
            rows.append(
                {
                    "id": current["id"],
                    "python_id": current["id"],
                    "title": current.get("title", ""),
                    "membership": "python_only",
                    "python_status": current["screen_status"],
                    "python_reason": current.get("filter_reason", ""),
                    "filename": current.get("filename", ""),
                }
            )
    return rows


def export_inclusions(path: Path, python_rows: list[dict], baseline: list[dict]) -> None:
    """Write the references as an --include-listing CSV, under current IDs where matched."""
    rows = {}
    for reference, current, _ in match_references(python_rows, baseline):
        reference = {**reference, "id": current.get("id", reference["id"])}
        rows[reference["id"]] = classification.merge(rows.get(reference["id"], {}), reference)
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(dict.fromkeys(key for row in rows.values() for key in row))
    storage.write_csv(path, rows.values(), fields)


def check_downloads(rows: list[dict], directory: Path) -> None:
    """Set file_status from the local file itself: missing, valid or invalid."""
    for row in rows:
        name = row.get("filename", "")
        if not name or Path(name).name != name or not (directory / name).is_file():
            row["file_status"] = "missing"
            continue
        try:
            info = storage.check_document(directory / name)
            if row.get("sha256") and info["sha256"] != row["sha256"]:
                raise ValueError("checksum differs from stored download")
            row["file_status"] = "valid"
        except (OSError, ValueError) as error:
            row["file_status"] = "invalid: " + str(error)


def adopt_local(source: str, python_rows: list[dict], destination: Path) -> int:
    """Copy checked files from the old corpus to destination; originals stay. Returns the count.

    A record's file is found under its own name, or through a successful row of
    an old download log with the same URL.
    """
    folder = REPO / "downloads" / source
    by_url = {}
    for path in (
        REPO / "outputs/download_log.csv",
        REPO / f"catalogues/{source}/download_log.csv",
    ):
        for row in selected_rows(source, path) if path.exists() else []:
            name = re.split(r"[\\/]", row.get("filepath") or row.get("filename", ""))[-1]
            if name and (folder / name).is_file():
                by_url[url_key(row["url"])] = folder / name

    destination.mkdir(parents=True, exist_ok=True)
    adopted = 0
    for row in python_rows:
        name = storage.document_filename(source, row)
        candidates = [folder / name] if (folder / name).is_file() else []
        candidates += [by_url[url] for url in document_urls(row) if url in by_url]
        if not candidates or (destination / name).exists():
            continue
        try:
            storage.check_document(candidates[0])
        except (OSError, ValueError):
            continue
        shutil.copy2(candidates[0], destination / name)
        adopted += 1
    return adopted


def parse_arguments(argv: list[str] | None) -> argparse.Namespace:
    """Parse the audit options."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("source")
    parser.add_argument("--run", type=Path, help="Python run folder containing decisions.csv")
    parser.add_argument("--state", type=Path, help="audit all persistent state instead of one run")
    parser.add_argument(
        "--r-file",
        type=Path,
        action="append",
        help="R catalogue CSV; repeatable (default: union saved snapshots)",
    )
    parser.add_argument("--export-inclusions", type=Path, help="write CSV for --include-listing")
    parser.add_argument("--download-dir", type=Path, help="verify local document files")
    parser.add_argument(
        "--adopt-local", action="store_true", help="copy logged corpus files to --download-dir"
    )
    parser.add_argument(
        "--require-superset",
        action="store_true",
        help="exit 1 for any baseline-only or missing/invalid baseline file",
    )
    args = parser.parse_args(argv)
    if args.adopt_local and not args.download_dir:
        parser.error("--adopt-local requires --download-dir")
    return args


def read_python(args: argparse.Namespace, review: Path) -> tuple[list[dict], str]:
    """Return the Python records and where they came from: --state, --run or the review state."""
    state_path = args.state
    if state_path is None and args.run is None and (review / "outputs/state.sqlite3").exists():
        state_path = review / "outputs/state.sqlite3"
    if state_path:
        uri = state_path.resolve().as_uri() + "?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            state = storage.load_state(connection)
        rows = [storage.with_state_fields(entry["record"], entry) for entry in state.values()]
        return rows, str(state_path)
    if args.run:
        return read_rows(args.run / "decisions.csv"), str(args.run)
    LOG.info("No Python state supplied or found; all references are initially unmatched")
    return [], "none"


def main(argv: list[str] | None = None) -> int:
    """Compare one source and write r_comparison.csv."""
    args = parse_arguments(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    # Read both sides; optionally export the references or copy old corpus files.
    review = REPO / "rag-pipeline/data" / f"{args.source}_review"
    paths = args.r_file or baseline_files(args.source)
    if not paths:
        raise SystemExit(f"No R catalogue for {args.source}; pass --r-file")
    python_rows, python_input = read_python(args, review)
    r_rows = load_baseline(args.source, paths)
    if args.export_inclusions:
        export_inclusions(args.export_inclusions, python_rows, r_rows)
    if args.adopt_local:
        copied = adopt_local(args.source, python_rows, args.download_dir)
        LOG.info("Copied %d checked local documents", copied)

    # Write the comparison and log the counts.
    rows = compare(python_rows, r_rows)
    if args.download_dir:
        check_downloads(rows, args.download_dir)
    output = review / "r_comparison.csv"
    output.parent.mkdir(parents=True, exist_ok=True)
    storage.write_csv(output, rows, FIELDS)
    references = [row for row in rows if row["membership"] != "python_only"]
    r_only = Counter(row["python_reason"] for row in rows if row["membership"] == "r_only")
    file_statuses = Counter(row.get("file_status", "unchecked") for row in references)
    LOG.info("Python input: %s", python_input)
    LOG.info("R catalogues: %s (%d retained reference rows)", paths, len(r_rows))
    LOG.info("Membership: %s", dict(Counter(row["membership"] for row in rows)))
    LOG.info("R-only, by Python reason: %s", dict(r_only.most_common()))
    LOG.info("Wrote %s", output)
    LOG.info("Baseline files: %s", dict(file_statuses))

    # With --require-superset, every reference must be kept and have a valid local file.
    missing = [row for row in references if row["membership"] == "r_only"]
    missing += [row for row in references if row.get("file_status") != "valid"]
    return int(args.require_superset and (not r_rows or bool(missing)))


if __name__ == "__main__":
    sys.exit(main())
