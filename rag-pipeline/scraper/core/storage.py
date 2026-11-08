"""Everything on disk: the state database, CSV and JSON files, document files and the run lock."""

from __future__ import annotations

import csv
import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
from collections.abc import Iterable, Iterator
from contextlib import closing, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit
from zipfile import BadZipFile, ZipFile

LOG = logging.getLogger("scraper")

SCHEMA_VERSION = 2
RECORD_FIELDS = [
    "title",
    "source",
    "doc_date",
    "doc_type",
    "country",
    "project_id",
    "project_title",
    "report_no",
    "language",
    "url",
    "filename",
    "download_status",
    "screen_status",
    "filter_reason",
    "id",
]
DOWNLOAD_FIELDS = [
    "source",
    "id",
    "title",
    "status",
    "reason",
    "error",
    "url",
    "resolved_url",
    "filename",
    "bytes",
    "sha256",
    "checked_at",
]
DOWNLOAD_LABELS = dict.fromkeys(("downloaded", "skipped_valid", "adopted_local"), "available")
STATE_COLUMNS = ["id", "record_json", "download_json", "first_seen", "last_seen"]
OLD_STATE_COLUMNS = ["id", "metadata", "first_seen", "last_seen", "download"]
STATE_ONLY_FIELDS = {"first_seen", "last_seen", "filename", "download_status", "sha256", "bytes"}
EDITABLE_FIELDS = set(RECORD_FIELDS) - {
    "source",
    "id",
    "filename",
    "download_status",
    "screen_status",
    "filter_reason",
}
REPORT_TYPES = {
    "Completion review": r"implementation completion report review|icr.?review",
    "Completion report": r"complet|\bpcr\b|\bicr\b",
    "Performance assessment": r"performance assessment",
    "Performance evaluation": r"performance evaluation|\bpper\b",
    "Mid-term evaluation": r"mid.?term|interim eval",
    "Terminal evaluation": r"terminal eval|final eval|^te$",
    "Progress report": r"progress|implementation report|^pir$",
    "Evaluation": r"evaluat|^eval$",
}

# Document checks. Each format must start with its signature; ZIP formats must open.
MIN_FILE_BYTES = 10 * 1024
EOF_WINDOW_BYTES = 64 * 1024
OLE = bytes.fromhex("D0CF11E0A1B11AE1")
SIGNATURES = {
    ".pdf": (b"%PDF-",),
    ".doc": (OLE,),
    ".xls": (OLE,),
    ".rtf": (b"{\\rtf",),
    ".7z": (bytes.fromhex("377ABCAF271C"),),
    ".tif": (b"II*\x00", b"MM\x00*", b"II+\x00", b"MM\x00+"),
}
ZIP_FORMATS = {".docx": "word/document.xml", ".xlsx": "xl/workbook.xml", ".zip": ""}
HTML_FORMATS = {".htm", ".html"}
DOCUMENT_EXTENSIONS = set(SIGNATURES) | set(ZIP_FORMATS) | HTML_FORMATS


def utc_now() -> str:
    """Return the current UTC time as an ISO 8601 string, to the second."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def open_state(path: Path) -> sqlite3.Connection:
    """Open the state database, creating or upgrading it to the current schema."""
    connection = sqlite3.connect(path)
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version > SCHEMA_VERSION:
        connection.close()
        raise RuntimeError(f"{path} has schema {version}; this code reads up to {SCHEMA_VERSION}")
    if version < SCHEMA_VERSION:
        # Back up existing state, including committed WAL data, before changing its schema.
        columns = [row[1] for row in connection.execute("PRAGMA table_info(documents)")]
        renames = []
        if columns:
            with closing(
                sqlite3.connect(path.with_name(f"{path.name}.schema{version}.bak"))
            ) as backup:
                connection.backup(backup)
            if columns == OLD_STATE_COLUMNS:
                renames += [
                    "ALTER TABLE documents RENAME COLUMN metadata TO record_json;",
                    "ALTER TABLE documents RENAME COLUMN download TO download_json;",
                ]
            elif sorted(columns) != sorted(STATE_COLUMNS):
                connection.close()
                raise RuntimeError(f"{path} has unexpected columns: {columns}")
            renames.append("ALTER TABLE documents RENAME TO retrieval_state;")

        # Human metadata and processing receipts have ordinary SQL columns, not JSON cells.
        with connection:
            connection.executescript(
                "BEGIN IMMEDIATE;\n"
                + "\n".join(renames)
                + Path(__file__).with_name("schema.sql").read_text()
            )
            for entry in load_state(connection).values():
                sync_document(connection, with_state_fields(entry["record"], entry))
            connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    connection.execute("PRAGMA foreign_keys = ON")
    return connection


def normalize_record(record: dict) -> dict:
    """Combine legacy names without discarding distinct source evidence."""
    record = dict(record)
    for old, new in (("project_name", "project_title"), ("project_code", "project_id")):
        value = record.pop(old, "")
        if value and value != record.get(new):
            if record.get(new):
                record.setdefault("source_metadata", {})[old] = value
            else:
                record[new] = value
    label = record.pop("doc_title", "")
    if label:
        record["title"] = label
    if record.get("report_name") == record.get("title"):
        record.pop("report_name", None)
    return record


def human_record(record: dict) -> dict:
    """Return the compact document metadata, with one usable public URL."""
    row = normalize_record(record)
    # GEF and CPR provide project/API pages; use the report link for people instead.
    row["url"] = (
        row.get("url")
        or (row.get("pdf_url") if row.get("source") == "gef" or row.get("family_id") else "")
        or row.get("web_url")
        or row.get("pdf_url", "")
    )

    # Keep report dates readable without inventing missing month/day precision.
    row["doc_date"] = re.sub(r"T\d.*$", "", row.get("doc_date") or "")
    language = (row.get("language") or "").strip().casefold()
    row["language"] = {"english": "en", "eng": "en", "french": "fr", "fra": "fr", "fre": "fr"}.get(
        language, language
    )

    # Generic link labels need project context to identify a report in Zotero.
    title, project = row.get("title", ""), row.get("project_title", "")
    if (
        project
        and (row.get("source") == "gef" or title == row.get("doc_type"))
        and project.casefold() not in title.casefold()
    ):
        row["title"] = f"{project}: {title}"
    if row.get("project_title") == title:
        row["project_title"] = ""
    kind = row.get("doc_type") or ""
    row["doc_type"] = next(
        (label for label, pattern in REPORT_TYPES.items() if re.search(pattern, kind, re.I)),
        "" if kind == title or len(kind) > 100 else kind,
    )
    row["download_status"] = DOWNLOAD_LABELS.get(
        row.get("download_status"), row.get("download_status", "pending")
    )
    if row["download_status"] != "available":
        row["filename"] = ""
    if row.get("filter_reason") == "reference_recall" and row.get("rule_reason"):
        row["filter_reason"] = f"reference_recall: {row['rule_reason']}"
    return {field: row.get(field) or "" for field in RECORD_FIELDS}


def sync_document(
    connection: sqlite3.Connection, record: dict, previous: dict | None = None
) -> None:
    """Refresh metadata while preserving bibliographic corrections made in the SQL table."""
    row, old = human_record(record), human_record(previous or {})
    fields = ", ".join(RECORD_FIELDS)
    updates = ", ".join(
        f"{field} = CASE WHEN documents.{field} = ? THEN excluded.{field} "
        f"ELSE documents.{field} END"
        if field in EDITABLE_FIELDS
        else f"{field}=excluded.{field}"
        for field in RECORD_FIELDS
        if field != "id"
    )
    connection.execute(
        f"INSERT INTO documents ({fields}) VALUES ({','.join('?' for _ in row)}) "
        f"ON CONFLICT(id) DO UPDATE SET {updates}",
        [*row.values(), *(old[field] for field in RECORD_FIELDS if field in EDITABLE_FIELDS)],
    )


def save_records(
    connection: sqlite3.Connection, records: Iterable[dict], seen_at: str, seen_ids: set[str]
) -> None:
    """Insert or update records. first_seen is kept and nothing is ever deleted.

    last_seen moves to seen_at only for the records a search returned (seen_ids).
    """
    for record in records:
        record = normalize_record(record)
        previous = connection.execute(
            "SELECT record_json, download_json FROM retrieval_state WHERE id = ?", (record["id"],)
        ).fetchone()
        last_seen = (
            "excluded.last_seen" if record["id"] in seen_ids else "retrieval_state.last_seen"
        )
        stored = {key: value for key, value in record.items() if key not in STATE_ONLY_FIELDS}
        connection.execute(
            "INSERT INTO retrieval_state (id, record_json, download_json, first_seen, last_seen) "
            "VALUES (?, ?, '{}', ?, ?) ON CONFLICT(id) DO UPDATE SET "
            f"record_json = excluded.record_json, last_seen = {last_seen}",
            (record["id"], json.dumps(stored, ensure_ascii=False), seen_at, seen_at),
        )
        enriched = with_state_fields(
            record, {"download": json.loads(previous[1]) if previous else {}}
        )
        sync_document(connection, enriched, json.loads(previous[0]) if previous else None)
    connection.commit()


def load_state(connection: sqlite3.Connection) -> dict[str, dict]:
    """Return every stored document as {id: {record, download, first_seen, last_seen}}."""
    # Read old databases too, so the R audit can remain strictly read-only.
    table = (
        "retrieval_state"
        if connection.execute("PRAGMA table_info(retrieval_state)").fetchone()
        else "documents"
    )
    columns = [row[1] for row in connection.execute(f"PRAGMA table_info({table})")]
    names = "metadata, download" if "metadata" in columns else "record_json, download_json"
    rows = connection.execute(
        f"SELECT id, {names}, first_seen, last_seen FROM {table} ORDER BY id"
    )
    return {
        doc_id: {
            "record": normalize_record(json.loads(record_json)),
            "download": json.loads(download_json),
            "first_seen": first_seen,
            "last_seen": last_seen,
        }
        for doc_id, record_json, download_json, first_seen, last_seen in rows
    }


def save_download(connection: sqlite3.Connection, doc_id: str, result: dict) -> None:
    """Store one download result at once, so an interruption loses nothing."""
    connection.execute(
        "UPDATE retrieval_state SET download_json = ? WHERE id = ?",
        (json.dumps(result, ensure_ascii=False), doc_id),
    )
    status = result.get("status") or "pending"
    status = DOWNLOAD_LABELS.get(status, status)
    filename = result.get("filename", "") if status == "available" else ""
    connection.execute(
        "UPDATE documents SET filename = ?, download_status = ? WHERE id = ?",
        (filename, status, doc_id),
    )
    connection.commit()


def catalogue_rows(connection: sqlite3.Connection) -> list[dict]:
    """Read retained human metadata, including corrections, in a stable order."""
    rows = connection.execute(
        f"SELECT {', '.join(RECORD_FIELDS)} FROM documents "
        "WHERE screen_status != 'drop' ORDER BY doc_date DESC, title COLLATE NOCASE, id"
    )
    return [dict(zip(RECORD_FIELDS, row, strict=True)) for row in rows]


def with_state_fields(record: dict, entry: dict) -> dict:
    """Attach download checks and sighting times to a source record for internal audits."""
    download = entry.get("download", {})
    return {
        **record,
        "first_seen": entry.get("first_seen", ""),
        "last_seen": entry.get("last_seen", ""),
        "filename": download.get("filename", ""),
        "download_status": download.get("status", "pending"),
        "sha256": download.get("sha256", ""),
        "bytes": download.get("bytes", ""),
    }


def write_csv(path: Path, rows: Iterable[dict], fields: list[str] | None = None) -> Path:
    """Write a UTF-8 CSV atomically and return the path written. Lists are written as JSON.

    When the file is open in Excel on Windows, the rename fails; the rows then go
    to a dated copy next to it, and the next run writes the usual name again.
    """
    rows = list(rows)
    fields = fields or list(dict.fromkeys(key for row in rows for key in row))
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    key: json.dumps(value, ensure_ascii=False)
                    if isinstance(value, (list, dict))
                    else value
                    for key, value in row.items()
                }
            )
    try:
        os.replace(temporary, path)
        return path
    except PermissionError:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        fallback = path.with_name(f"{path.stem}_{stamp}{path.suffix}")
        os.replace(temporary, fallback)
        LOG.warning("%s is locked (open in Excel?); wrote %s instead", path.name, fallback.name)
        return fallback


def write_json(path: Path, value: object) -> None:
    """Write JSON atomically: a .tmp file first, then a rename."""
    temporary = path.with_name(path.name + ".tmp")
    text = json.dumps(value, indent=2, ensure_ascii=False, default=str)
    temporary.write_text(text + "\n", encoding="utf-8")
    os.replace(temporary, path)


def read_csv(path: Path) -> list[dict]:
    """Read a UTF-8 CSV, with or without a byte order mark."""
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def sha256_of(path: Path) -> str:
    """Return the SHA-256 checksum of a file."""
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def check_document(path: Path, extension: str = "") -> dict:
    """Return the size and checksum of a plausible document; raise ValueError otherwise.

    The extension (default: the file's own) picks the format; unknown ones are
    checked as PDF. This catches HTML error pages and cut downloads, not every
    broken file.
    """
    suffix = extension or path.suffix.lower()
    if suffix not in DOCUMENT_EXTENSIONS:
        suffix = ".pdf"

    # Read the size, the start and, for a PDF, the end of the file.
    size = path.stat().st_size
    with path.open("rb") as handle:
        head = handle.read(4096)
        handle.seek(max(0, size - EOF_WINDOW_BYTES))
        tail = handle.read()
    if suffix not in ZIP_FORMATS and size < MIN_FILE_BYTES:
        raise ValueError(f"File has {size} bytes, below the {MIN_FILE_BYTES} byte minimum")

    # Check the format's signature, or that a ZIP or Office file opens.
    if suffix in SIGNATURES and not head.startswith(SIGNATURES[suffix]):
        raise ValueError(f"File does not start like a {suffix} file")
    if suffix == ".pdf" and b"%%EOF" not in tail:
        raise ValueError("No %%EOF marker near the end of the file")
    if suffix in HTML_FORMATS and not re.search(rb"<!doctype\s+html|<html\b", head, re.I):
        raise ValueError("File is not an HTML document")
    if suffix in ZIP_FORMATS:
        check_zip(path, ZIP_FORMATS[suffix])
    return {"bytes": size, "sha256": sha256_of(path)}


def check_zip(path: Path, required: str) -> None:
    """Check that a ZIP file opens, has no corrupt entry and holds the required Office part."""
    try:
        with ZipFile(path) as archive:
            names = archive.namelist()
            if required and not {"[Content_Types].xml", required}.issubset(names):
                raise ValueError("File does not contain the expected Office document")
            if archive.testzip() is not None:
                raise ValueError("Document has a corrupt ZIP entry")
    except BadZipFile as error:
        raise ValueError("File is not a valid ZIP container") from error


def safe_part(text: str, limit: int = 60) -> str:
    """Make text safe inside a file name: letters, digits, dots and hyphens only."""
    return re.sub(r"[^A-Za-z0-9.-]+", "-", text).strip("-.")[:limit].strip("-.")


def document_filename(source: str, record: dict) -> str:
    """Return <source>_<id>_<project>_<year><extension>, with noproj and XXXX when unknown."""
    first_project = re.split(r"[,;\s]+", record.get("project_id", "").strip())[0]
    project = safe_part(first_project) or "noproj"
    year_match = re.match(r"\d{4}", record.get("doc_date", "") or "")
    year = year_match.group() if year_match else "XXXX"

    # Long IDs keep a checksum, so two IDs with the same start get different names.
    identifier = safe_part(record["id"], len(record["id"]))
    if len(identifier) > 100:
        digest = hashlib.sha256(record["id"].encode("utf-8")).hexdigest()[:12]
        identifier = f"{identifier[:87].rstrip('-.')}-{digest}"
    extension = document_extension(record.get("pdf_url", ""))
    return f"{source}_{identifier}_{project}_{year}{extension}"


def document_extension(url: str, default: str = ".pdf") -> str:
    """Return the URL's extension when it is a supported document format, else default."""
    extension = Path(urlsplit(url).path).suffix.lower()
    return extension if extension in DOCUMENT_EXTENSIONS else default


def office_extension(path: Path, default: str) -> str:
    """Return .docx or .xlsx when the file is really a Word or Excel file, else default."""
    # GEF 4709 serves a .docx file at a .doc URL (checked 2026-10-22, document eaeedc1caefe3809).
    with path.open("rb") as handle:
        if handle.read(4) != b"PK\x03\x04":
            return default
    try:
        with ZipFile(path) as archive:
            names = set(archive.namelist())
    except BadZipFile:
        return default
    for extension in (".docx", ".xlsx"):
        if {"[Content_Types].xml", ZIP_FORMATS[extension]}.issubset(names):
            return extension
    return default


def install_document(
    part_path: Path, destination: Path, versions_dir: Path, sha256: str, previous_path: Path
) -> bool:
    """Move a checked .part file to destination. Returns True when the content changed.

    An older file at previous_path or destination with other content moves to
    versions_dir first, so no earlier version is lost.
    """
    old_checksums = {
        path: sha256_of(path)
        for path in dict.fromkeys([previous_path, destination])
        if path.exists()
    }
    for path, old_sha256 in old_checksums.items():
        if path == destination and old_sha256 == sha256:
            continue
        versions_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), versions_dir / f"{path.stem}_{old_sha256[:12]}{path.suffix}")
    os.replace(part_path, destination)
    return old_checksums.get(previous_path) != sha256


@contextmanager
def directory_lock(path: Path) -> Iterator[None]:
    """Hold an operating-system lock on path; raise RuntimeError if another run holds it.

    The lock is released when the process ends, so a crash leaves no stale lock.
    """
    with path.open("a+b") as handle:
        try:
            if path.stat().st_size == 0:
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            lock_file(handle.fileno())
        except OSError as error:
            raise RuntimeError(f"Another run is using {path.parent}") from error
        try:
            yield
        finally:
            handle.seek(0)
            unlock_file(handle.fileno())


if os.name == "nt":
    import msvcrt

    def lock_file(descriptor: int) -> None:
        """Take a non-blocking lock on the first byte of a file (Windows)."""
        msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)

    def unlock_file(descriptor: int) -> None:
        """Release the lock taken by lock_file (Windows)."""
        msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)

else:
    import fcntl

    def lock_file(descriptor: int) -> None:
        """Take a non-blocking exclusive lock on a file (Unix)."""
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def unlock_file(descriptor: int) -> None:
        """Release the lock taken by lock_file (Unix)."""
        fcntl.flock(descriptor, fcntl.LOCK_UN)
