"""Run one source from start to finish, the same way for every source.

A source module provides SOURCE, REPO and four functions: plan_searches,
run_search, classify and pdf_urls. Optional extras:

- SCOPE_FILE: its checksum goes in the summary.
- EXTRA_FIELDS: catalogue columns after the shared ones.
- HEADERS: default request headers.
- add_arguments(parser): the source's own options.
- prepare_run(args): load lookup tables once, before any record is decided.
- prepare_record(record): attach those tables' evidence before the shared rules.
- resolve_pdf_urls(client, record): read file links from a landing page at download time.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import sqlite3
import statistics
import sys
import time
import uuid
from collections import Counter
from datetime import date, datetime, timezone
from pathlib import Path
from types import ModuleType

from core import classification, downloads, searching, storage
from core.fetch import Client

LOG = logging.getLogger("scraper")
DRIFT_DROP_SHARE = 0.20


def main(source: ModuleType, argv: list[str] | None = None) -> int:
    """Parse the shared options, lock the output folder and run the source."""
    args = parse_arguments(source, argv)
    args.output_dir = args.output_dir.resolve()
    args.download_dir = args.download_dir.resolve()
    args.download_dir.mkdir(parents=True, exist_ok=True)
    run_dir = new_run_dir(args.output_dir / "runs")

    # Lock the output folder so two runs cannot write the same state.
    handlers = start_logging(run_dir / "run.log")
    try:
        with storage.directory_lock(args.output_dir / ".run.lock"):
            return run(source, args, run_dir)
    except KeyboardInterrupt:
        LOG.error("Interrupted. Finished downloads are saved; rerun to continue.")
        return 130
    except RuntimeError as error:
        LOG.error("%s", error)
        return 1
    finally:
        stop_logging(handlers)


def parse_arguments(source: ModuleType, argv: list[str] | None) -> argparse.Namespace:
    """Define the shared options, add the source's own and parse them."""
    parser = argparse.ArgumentParser(
        description=(source.__doc__ or "").strip(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=source.REPO / "outputs" / source.SOURCE,
        help="state, catalogue and run folders (default: outputs/<source>)",
    )
    parser.add_argument(
        "--download-dir",
        type=Path,
        default=source.REPO / "downloads" / source.SOURCE,
        help="document folder (default: downloads/<source>)",
    )
    parser.add_argument(
        "--start-date",
        type=date.fromisoformat,
        default=date(2015, 1, 1),
        help="earliest document date kept, YYYY-MM-DD (default: 2015-01-01)",
    )
    parser.add_argument(
        "--end-date",
        type=date.fromisoformat,
        default=date.today(),
        help="latest document date kept, YYYY-MM-DD (default: today)",
    )
    parser.add_argument(
        "--metadata-only", action="store_true", help="search and classify, but download nothing"
    )
    parser.add_argument(
        "--download-only",
        action="store_true",
        help="no search: decide the stored and listed records again and retry their downloads",
    )
    parser.add_argument(
        "--include-listing",
        type=Path,
        action="append",
        default=[],
        help="CSV of documents to keep for screening whatever the rules say; repeatable",
    )
    parser.add_argument("--max-downloads", type=int, help="download at most this many new files")
    parser.add_argument(
        "--refresh", action="store_true", help="download again even if a checked copy exists"
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=16,
        help="requests in flight at once: searches, pages or downloads (default: 16)",
    )
    parser.add_argument(
        "--request-interval",
        type=float,
        help="seconds between requests to one host, for every host "
        "(default: 0.5, or 0.1 for the fast hosts in core/fetch.py)",
    )
    if hasattr(source, "add_arguments"):
        source.add_arguments(parser)
    args = parser.parse_args(argv)

    # Reject settings that cannot work before any request is made.
    if args.start_date > args.end_date:
        parser.error("--start-date is after --end-date")
    if args.workers < 1 or (args.request_interval or 0) < 0:
        parser.error("--workers must be at least 1 and --request-interval at least 0")
    if args.max_downloads is not None and args.max_downloads < 0:
        parser.error("--max-downloads must be 0 or more")
    return args


def new_run_dir(runs: Path) -> Path:
    """Create runs/<UTC timestamp>_<random suffix> and return it."""
    now = datetime.now(timezone.utc)
    run_dir = runs / f"{now:%Y%m%dT%H%M%S}{now.microsecond // 1000:03d}Z_{uuid.uuid4().hex[:6]}"
    run_dir.mkdir(parents=True)
    return run_dir


def run(source: ModuleType, args: argparse.Namespace, run_dir: Path) -> int:
    """Run every step and always write summary.json. Returns the exit code."""
    summary = new_summary(source, args, run_dir)
    storage.write_json(run_dir / "summary.json", summary)
    connection = storage.open_state(args.output_dir / "state.sqlite3")
    started = time.monotonic()
    try:
        summary["status"] = run_steps(source, args, run_dir, connection, summary)
    except KeyboardInterrupt:
        summary["status"] = "interrupted"
        raise
    except Exception as error:
        summary.update(status="failed", error=f"{type(error).__name__}: {error}")
        LOG.exception("Run failed")
        raise
    finally:
        summary["finished_at"] = storage.utc_now()
        summary["seconds"]["total"] = round(time.monotonic() - started, 1)
        storage.write_json(run_dir / "summary.json", summary)
        connection.close()
        LOG.info("Run %s: %s. Summary: %s", run_dir.name, summary["status"], run_dir)
    return 0 if summary["status"] == "complete" else 1


def run_steps(
    source: ModuleType,
    args: argparse.Namespace,
    run_dir: Path,
    connection: sqlite3.Connection,
    summary: dict,
) -> str:
    """Search, classify, save, download and report. Returns the run status."""
    # Run every search. Stop before touching state if any is incomplete.
    client = Client(
        args.request_interval, headers=getattr(source, "HEADERS", None), workers=args.workers
    )
    if hasattr(source, "prepare_run"):
        source.prepare_run(args)
    results = search_step(source, client, args, run_dir, summary)
    if summary["incomplete_searches"]:
        LOG.error(
            "%d searches are incomplete. Catalogue, state and files are unchanged.",
            len(summary["incomplete_searches"]),
        )
        return "incomplete_search"

    records = classify_step(source, args, run_dir, connection, summary, results)
    download_step(source, client, args, run_dir, connection, summary)
    publish_step(source, args, run_dir, connection, summary, records)
    summary["requests"] = client.request_count
    return "complete"


def search_step(
    source: ModuleType, client: Client, args: argparse.Namespace, run_dir: Path, summary: dict
) -> list[tuple[dict, searching.SearchResult, float]]:
    """Plan and run every search, write searches.csv and add the counts to the summary."""
    started = time.monotonic()
    results = []
    if not args.download_only:
        searches = searching.name_searches(source.plan_searches(args))
        LOG.info("%s: %d searches. Run folder: %s", source.SOURCE, len(searches), run_dir)
        results = searching.run_searches(source, client, searches, args.workers)
    searching.write_searches(run_dir / "searches.csv", results)

    # Keep what an incomplete search found, for diagnosis only; it is never published.
    if any(result.error for _, result, _ in results):
        partial = classification.merge_records(source.SOURCE, results)
        storage.write_csv(run_dir / "partial_records.csv", partial.values(), fields_of(source))
    summary["seconds"]["search"] = round(time.monotonic() - started, 1)
    summary.update(searching.search_summary(results))
    return results


def classify_step(
    source: ModuleType,
    args: argparse.Namespace,
    run_dir: Path,
    connection: sqlite3.Connection,
    summary: dict,
    results: list[tuple[dict, searching.SearchResult, float]],
) -> dict[str, dict]:
    """Merge and decide the records, save them all and write this run's decisions."""
    # Decide this run's records, or with --download-only every stored record, plus listed ones.
    started = time.monotonic()
    records = classification.merge_records(source.SOURCE, results)
    seen_ids = set(records)
    state = storage.load_state(connection)
    if args.download_only:
        records = {doc_id: dict(entry["record"]) for doc_id, entry in state.items()}
    classification.add_inclusions(records, state, args.include_listing, source.SOURCE)
    summary["sibling_decisions"] = classification.classify_all(
        source, records, args.start_date, args.end_date
    )

    # Save every record, drops included. Only records a search returned count as seen.
    storage.save_records(connection, records.values(), summary["started_at"], seen_ids)
    state = storage.load_state(connection)
    decisions = [storage.with_state_fields(records[doc_id], state[doc_id]) for doc_id in records]
    storage.write_csv(run_dir / "decisions.csv", decisions, fields_of(source))
    summary["seconds"]["classify"] = round(time.monotonic() - started, 1)
    summary.update(decision_summary(records, state))
    log_decisions(summary)
    return records


def download_step(
    source: ModuleType,
    client: Client,
    args: argparse.Namespace,
    run_dir: Path,
    connection: sqlite3.Connection,
    summary: dict,
) -> None:
    """Download every stored kept record that has no good local copy."""
    started = time.monotonic()
    rows: list[dict] = []
    if not args.metadata_only:
        state = storage.load_state(connection)
        kept = [entry["record"] for entry in state.values() if is_kept(entry["record"])]
        rows = downloads.download_records(source, client, connection, state, kept, args)
    storage.write_csv(run_dir / "downloads.csv", rows, storage.DOWNLOAD_FIELDS)
    summary["seconds"]["download"] = round(time.monotonic() - started, 1)
    summary.update(downloads.download_summary(rows))


def publish_step(
    source: ModuleType,
    args: argparse.Namespace,
    run_dir: Path,
    connection: sqlite3.Connection,
    summary: dict,
    records: dict[str, dict],
) -> None:
    """Write the catalogue and log drift warnings against the previous complete run."""
    # The size estimate now includes this run's downloads.
    state = storage.load_state(connection)
    summary.update(decision_summary(records, state))
    catalogue = storage.catalogue_rows(state)
    storage.write_csv(
        args.output_dir / f"{source.SOURCE}_metadata.csv", catalogue, fields_of(source)
    )
    summary["catalogue_records"] = len(catalogue)

    # Warnings point to a changed website; they never fail the run.
    summary["drift_warnings"] = drift_warnings(run_dir, summary)
    for warning in summary["drift_warnings"]:
        LOG.warning("Drift: %s", warning)


def is_kept(record: dict) -> bool:
    """Return True for in_scope and to_screen records."""
    return record.get("screen_status") != "drop"


def fields_of(source: ModuleType) -> list[str]:
    """Return the catalogue columns: the shared ones, the inclusion ones, then the source's."""
    extra = list(getattr(source, "EXTRA_FIELDS", []))
    return storage.RECORD_FIELDS + classification.INCLUSION_FIELDS + extra


def new_summary(source: ModuleType, args: argparse.Namespace, run_dir: Path) -> dict:
    """Start the summary with the run's identity, options and scope file checksum."""
    scope_file = Path(getattr(source, "SCOPE_FILE", "") or "")
    is_file = scope_file.is_file()
    return {
        "source": source.SOURCE,
        "run_id": run_dir.name,
        "status": "running",
        "mode": "download_only" if args.download_only else "live_search",
        "started_at": storage.utc_now(),
        "options": {key: str(value) for key, value in vars(args).items()},
        "scope_file": scope_file.name if is_file else "",
        "scope_sha256": hashlib.sha256(scope_file.read_bytes()).hexdigest() if is_file else "",
        "seconds": {},
    }


def decision_summary(records: dict[str, dict], state: dict[str, dict]) -> dict:
    """Count statuses and reasons, and estimate the download size of the kept records."""
    # The size sample is the downloaded files of records kept now, not old files on disk.
    kept = [doc_id for doc_id, record in records.items() if is_kept(record)]
    sizes = []
    for doc_id in kept:
        download = state.get(doc_id, {}).get("download", {})
        if download.get("sha256") and str(download.get("bytes", "")).isdigit():
            sizes.append(int(download["bytes"]))
    median = int(statistics.median(sizes)) if sizes else None
    reasons = Counter(record["filter_reason"] for record in records.values())
    return {
        "unique_records": len(records),
        "status_counts": dict(Counter(record["screen_status"] for record in records.values())),
        "reason_counts": dict(reasons),
        "kept": len(kept),
        "reference_documents": sum(
            bool(record.get("reference_ids")) for record in records.values()
        ),
        "reference_retained": reasons["reference_recall"],
        "median_pdf_bytes": median,
        "estimated_download_bytes": len(kept) * median if median else None,
    }


def log_decisions(summary: dict) -> None:
    """Log the kept count and the download size estimate."""
    LOG.info(
        "%d raw records, %d unique, %d kept: %s",
        summary["raw_records"],
        summary["unique_records"],
        summary["kept"],
        summary["status_counts"],
    )
    if summary["estimated_download_bytes"]:
        LOG.info(
            "Estimated download size: %.1f MB (%d kept x median %.1f MB)",
            summary["estimated_download_bytes"] / 1e6,
            summary["kept"],
            summary["median_pdf_bytes"] / 1e6,
        )
    else:
        LOG.info("Download size unknown until some files are downloaded (try --max-downloads 5)")


def previous_summary(run_dir: Path) -> dict | None:
    """Return the summary of the latest earlier complete live run, if there is one."""
    earlier = sorted(path for path in run_dir.parent.iterdir() if path.name < run_dir.name)
    for path in reversed(earlier):
        try:
            summary = json.loads((path / "summary.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        live = summary.get("mode", "live_search") == "live_search"
        if summary.get("status") == "complete" and "search_counts" in summary and live:
            return summary
    return None


def drift_warnings(run_dir: Path, summary: dict) -> list[str]:
    """Compare a live run with the previous complete live run."""
    previous = previous_summary(run_dir)
    if previous is None or summary["mode"] == "download_only":
        return []

    # A search that found records last time and none now.
    warnings = []
    old_counts = previous["search_counts"]
    for name, count in summary["search_counts"].items():
        if old_counts.get(name, 0) > 0 and count == 0:
            warnings.append(f"search '{name}' found {old_counts[name]} records last time, 0 now")

    # Fewer unique records, compared only when both runs made the same searches.
    old_unique = previous.get("unique_records") or 0
    same_searches = set(old_counts) == set(summary["search_counts"])
    if same_searches and summary["unique_records"] < old_unique * (1 - DRIFT_DROP_SHARE):
        warnings.append(
            f"unique records fell from {old_unique} to {summary['unique_records']} "
            f"(run {previous['run_id']})"
        )
    return warnings


def start_logging(log_path: Path) -> list[logging.Handler]:
    """Send scraper logs to the console and to run.log."""
    logger = logging.getLogger("scraper")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(errors="backslashreplace")
    handlers: list[logging.Handler] = [
        logging.StreamHandler(sys.stderr),
        logging.FileHandler(log_path, encoding="utf-8"),
    ]
    for handler in handlers:
        handler.setFormatter(formatter)
        logger.addHandler(handler)
    return handlers


def stop_logging(handlers: list[logging.Handler]) -> None:
    """Detach and close the handlers added by start_logging."""
    logger = logging.getLogger("scraper")
    for handler in handlers:
        logger.removeHandler(handler)
        handler.close()
