"""List processing work or record a successful parse/extraction against its exact input."""

from __future__ import annotations

import argparse
import hashlib
import sqlite3
from pathlib import Path

from core import storage


def status(
    connection: sqlite3.Connection,
    parse_recipe: str = "",
    extract_recipe: str = "",
    doc_id: str = "",
) -> list[dict]:
    """Compare content receipts and, when supplied, the desired tool/configuration versions."""
    cursor = connection.execute(
        "SELECT * FROM processing_status" + (" WHERE id=?" if doc_id else " ORDER BY source, id"),
        (doc_id,) if doc_id else (),
    )
    rows = [
        dict(zip((column[0] for column in cursor.description), row, strict=True)) for row in cursor
    ]
    for row in rows:
        row["available"] = bool(row["available"] and row["sha256"])
        row["needs_parse"] = bool(
            row["needs_parse"] or (parse_recipe and row["parse_recipe"] != parse_recipe)
        )
        row["needs_extract"] = bool(
            row["needs_parse"]
            or row["needs_extract"]
            or (extract_recipe and row["extract_recipe"] != extract_recipe)
        )
        row["extract_input_sha256"] = hashlib.sha256(
            (row["parsed_sha256"] + row["metadata_json"]).encode("utf-8")
        ).hexdigest()
    return rows


def complete(
    connection: sqlite3.Connection,
    doc_id: str,
    stage: str,
    input_sha256: str,
    recipe: str,
    artifact: Path,
) -> None:
    """Save a successful result only if its input still matches the current upstream content."""
    row = next(iter(status(connection, doc_id=doc_id)), None)
    if row is None or not row["available"]:
        raise ValueError("Document has no verified available download")
    expected = row["sha256"] if stage == "parse" else row["extract_input_sha256"]
    if stage == "extract" and row["needs_parse"]:
        raise ValueError("Parse the current document before recording extraction")
    if not recipe.strip() or not input_sha256 or input_sha256 != expected:
        raise ValueError("Missing recipe or input checksum differs from current content")

    # Hash a finished artifact, never record the mere existence of an output folder.
    output_sha256 = storage.sha256_of(artifact)
    if not artifact.stat().st_size:
        raise ValueError("Processing artifact is empty")
    with connection:
        connection.execute(
            "INSERT INTO processing VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id, stage) "
            "DO UPDATE SET input_sha256=excluded.input_sha256, recipe=excluded.recipe, "
            "output_sha256=excluded.output_sha256, completed_at=excluded.completed_at, "
            "metadata_json=excluded.metadata_json",
            (
                doc_id,
                stage,
                row["sha256"] if stage == "parse" else row["parsed_sha256"],
                recipe,
                output_sha256,
                storage.utc_now(),
                row["metadata_json"] if stage == "extract" else "",
            ),
        )


def main(argv: list[str] | None = None) -> int:
    """Export processing status, optionally recording one explicitly completed stage first."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="one source's state folder")
    parser.add_argument(
        "--parse-recipe", default="", help="desired parser version/options fingerprint"
    )
    parser.add_argument(
        "--extract-recipe", default="", help="desired model/prompt/schema fingerprint"
    )
    parser.add_argument("--stage", choices=("parse", "extract"))
    parser.add_argument("--id", dest="doc_id")
    parser.add_argument("--input-sha256")
    parser.add_argument("--recipe")
    parser.add_argument("--artifact", type=Path, help="successfully completed output file")
    args = parser.parse_args(argv)
    receipt = [args.doc_id, args.input_sha256, args.recipe, args.artifact]
    if bool(args.stage) != all(receipt) or (not args.stage and any(receipt)):
        parser.error(
            "recording success requires --stage, --id, --input-sha256, --recipe and --artifact"
        )
    path = args.output_dir / "state.sqlite3"
    if not path.is_file():
        parser.error(f"No saved state: {path}")

    # Use the same folder lock as retrieval so a receipt cannot race a scraper update.
    with storage.directory_lock(args.output_dir / ".run.lock"):
        connection = storage.open_state(path)
        try:
            if args.stage:
                complete(
                    connection,
                    args.doc_id,
                    args.stage,
                    args.input_sha256,
                    args.recipe,
                    args.artifact,
                )
            rows = status(connection, args.parse_recipe, args.extract_recipe)
            fields = [
                "source",
                "id",
                "filename",
                "available",
                "needs_parse",
                "needs_extract",
                "sha256",
                "extract_input_sha256",
            ]
            storage.write_csv(args.output_dir / "processing_status.csv", rows, fields)
            ready = [row for row in rows if row["available"]]
            print(
                f"{len(rows)} retained; {len(ready)} verified downloads; "
                f"{sum(row['needs_parse'] for row in ready)} need parsing; "
                f"{sum(row['needs_extract'] for row in ready)} need extraction"
            )
        finally:
            connection.close()
    return 0
