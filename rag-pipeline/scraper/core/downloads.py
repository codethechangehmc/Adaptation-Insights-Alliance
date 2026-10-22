"""Download the kept records: skip checked local copies, fetch the rest, save each result."""

from __future__ import annotations

import argparse
import logging
import sqlite3
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from types import ModuleType

from core import classification, storage
from core.fetch import Client, RequestFailed

LOG = logging.getLogger("scraper")

PROGRESS_EVERY = 10


def download_records(
    source: ModuleType,
    client: Client,
    connection: sqlite3.Connection,
    state: dict[str, dict],
    kept: list[dict],
    args: argparse.Namespace,
) -> list[dict]:
    """Skip checked local copies, download the rest concurrently and save each result."""
    # Settle records whose local file is already good, without any request.
    rows, jobs = [], []
    owners = Counter(entry["download"].get("filename", "") for entry in state.values())
    for record in sorted(kept, key=lambda item: item["id"]):
        previous = state[record["id"]]["download"]
        destination = local_path(source, record, previous, args.download_dir, owners)
        local = local_result(record, previous, destination, args.refresh)
        if local:
            storage.save_download(connection, record["id"], local)
            rows.append(local)
        else:
            jobs.append((record, previous, destination))
    if args.max_downloads is not None:
        jobs = jobs[: args.max_downloads]
    LOG.info("Downloads: %d already on disk, %d to fetch", len(rows), len(jobs))

    # Fetch the rest. Only this thread writes to the state database.
    versions_dir = args.output_dir / "versions"
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [
            pool.submit(safe_download, source, client, record, previous, destination, versions_dir)
            for record, previous, destination in jobs
        ]
        for done, future in enumerate(as_completed(futures), 1):
            result = future.result()
            storage.save_download(connection, result["id"], result)
            rows.append(result)
            if result["status"] != "downloaded":
                LOG.warning("Download %s failed: %s", result["id"], result["error"])
            if done % PROGRESS_EVERY == 0 or done == len(jobs):
                LOG.info("Checked %d of %d download jobs", done, len(jobs))
    return rows


def local_path(
    source: ModuleType, record: dict, previous: dict, folder: Path, owners: Counter
) -> Path:
    """Return where the record's file lives: its saved file, or the standard name."""
    # A recovered date changes the standard name. Reuse the saved file instead,
    # unless another record claims the same file (an old name collision).
    old_name = previous.get("filename", "")
    owned = old_name and Path(old_name).name == old_name and owners[old_name] == 1
    if owned and (folder / old_name).is_file():
        return folder / old_name
    return folder / storage.document_filename(source.SOURCE, record)


def base_result(record: dict, destination: Path) -> dict:
    """Return the fields every download result carries."""
    return {
        "source": record["source"],
        "id": record["id"],
        "title": record.get("title", ""),
        "filename": destination.name,
        "checked_at": storage.utc_now(),
    }


def local_result(record: dict, previous: dict, destination: Path, refresh: bool) -> dict | None:
    """Return a result for a good local file, or None when the file must be downloaded."""
    if refresh or not destination.exists():
        return None
    try:
        info = storage.check_document(destination)
    except (OSError, ValueError) as error:
        LOG.info("Local %s fails the file check (%s); downloading again", destination.name, error)
        return None

    # A file with a known checksum is skipped; a file state does not know is adopted.
    if previous.get("sha256") == info["sha256"]:
        status, reason = "skipped_valid", "local_file_matches_checksum"
    elif not previous.get("sha256"):
        status, reason = "adopted_local", "local_file_passes_check"
    else:
        LOG.warning(
            "Local %s changed since it was downloaded; downloading again", destination.name
        )
        return None
    return {
        **previous,
        **base_result(record, destination),
        **info,
        "status": status,
        "reason": reason,
        "error": "",
    }


def safe_download(
    source: ModuleType,
    client: Client,
    record: dict,
    previous: dict,
    destination: Path,
    versions_dir: Path,
) -> dict:
    """Download one record, turning any unexpected error into a failed result."""
    try:
        return download_one(source, client, record, previous, destination, versions_dir)
    except Exception as error:  # One failed download is recorded; the others carry on.
        return {
            **previous,
            **base_result(record, destination),
            "status": "failed",
            "reason": "unexpected_error",
            "error": f"{type(error).__name__}: {error}",
        }


def candidate_urls(source: ModuleType, client: Client, record: dict) -> tuple[list[str], list]:
    """Return the record's download links, best first, and any error from resolving them."""
    # Listed fallback links come after the source's own links.
    urls = source.pdf_urls(record) + classification.values(record.get("reference_urls"))
    errors = []

    # Some sources link to a landing page; the file links are read from it now.
    if hasattr(source, "resolve_pdf_urls"):
        try:
            urls = source.resolve_pdf_urls(client, record) + urls
        except (RequestFailed, ValueError, KeyError) as error:
            if not urls:
                raise
            errors.append(str(error))
    return list(dict.fromkeys(urls)), errors


def download_one(
    source: ModuleType,
    client: Client,
    record: dict,
    previous: dict,
    destination: Path,
    versions_dir: Path,
) -> dict:
    """Try each link until one gives a file that passes its format check."""
    result = {**previous, **base_result(record, destination)}
    urls, errors = candidate_urls(source, client, record)
    if not urls:
        error = "The record has no PDF link"
        return {**result, "status": "no_pdf_url", "reason": "no_pdf_url", "error": error}

    # A failed attempt leaves any earlier good file, and its checksum, untouched.
    part_path = destination.with_name(destination.name + ".part")
    for url in urls:
        try:
            fetched = client.download(url, part_path)
            fetched_path = destination.with_suffix(
                saved_extension(part_path, url, fetched["resolved_url"], destination.suffix)
            )
            info = storage.check_document(part_path, fetched_path.suffix)
            changed = storage.install_document(
                part_path, fetched_path, versions_dir, info["sha256"], destination
            )
        except (RequestFailed, ValueError, OSError) as error:
            errors.append(f"{url}: {error}")
            continue
        finally:
            part_path.unlink(missing_ok=True)
        reason = "new_file"
        if previous.get("sha256"):
            reason = "content_changed" if changed else "content_unchanged"
        return {
            **result,
            **info,
            "filename": fetched_path.name,
            "status": "downloaded",
            "reason": reason,
            "error": "",
            "url": url,
            "resolved_url": fetched["resolved_url"],
        }
    error = " | ".join(errors)
    return {
        **result,
        "status": "failed",
        "reason": "all_links_failed",
        "error": error,
        "url": urls[0],
    }


def saved_extension(part_path: Path, url: str, resolved_url: str, default: str) -> str:
    """Choose the file's extension from the link, the final URL and the file's own content."""
    extension = storage.document_extension(url, default)

    # A PDF link that redirects to an HTML page is an error page, not an HTML report.
    resolved = storage.document_extension(resolved_url, extension)
    if resolved not in storage.HTML_FORMATS:
        extension = resolved
    return storage.office_extension(part_path, extension)


def download_summary(rows: list[dict]) -> dict:
    """Count download results and list the IDs that failed."""
    failed = [row["id"] for row in rows if row["status"] in {"failed", "no_pdf_url"}]
    return {"download_counts": dict(Counter(row["status"] for row in rows)), "failed_ids": failed}
