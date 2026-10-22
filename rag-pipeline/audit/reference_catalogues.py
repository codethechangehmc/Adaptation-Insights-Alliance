"""Read and normalize saved R retrieval references for audits and explicit inclusion lists."""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

from core import classification
from core.storage import read_csv as read_rows

REPO = Path(__file__).resolve().parents[2]


R_FILES = {
    "worldbank": "catalogues/worldbank/wb_new_method_catalogue.csv",
    "af": "catalogues/af/af_metadata.csv",
    "afdb": "catalogues/afdb/afdb_metadata.csv",
    "cif": "catalogues/cif/cif_metadata.csv",
    "gcf": "catalogues/gcf/gcf_cpe_metadata.csv",
    "gef": "catalogues/gef/gef_all_documents.csv",
}


R_KEPT_STATUSES = {"in_scope", "to_screen", "kept", "kept_global"}
REPORT_EXTENSIONS = {".pdf", ".doc", ".docx", ".xls", ".xlsx"}


def url_key(url: str) -> str:
    """Normalise page identity while retaining query parameters that may select a file."""
    parts = urlsplit(url.strip())
    query = f"?{parts.query}" if parts.query else ""
    host = parts.netloc.lower()
    if host == "documents1.worldbank.org":
        host = "documents.worldbank.org"
    return f"{host}{parts.path.rstrip('/')}{query}"


def baseline_files(source: str) -> list[Path]:
    """Find saved retrieval catalogues, including older snapshots omitted by earlier audits."""
    paths = [REPO / R_FILES[source]] if source in R_FILES else []
    if source == "worldbank":
        paths += [REPO / "catalogues/worldbank/worldbank_metadata.csv"]
    paths += [
        REPO / "outputs" / f"{source}_metadata.csv",
        REPO / f"catalogues/{source}/download_log.csv",
        REPO / "outputs/download_log.csv",
        REPO / "catalogues/doc_index.csv",
    ]
    return [path for path in paths if path.exists()]


def gef_selected(rows: list[dict]) -> list[dict]:
    """Reproduce the R target filter and best-document selection."""
    priority = [
        "Terminal Evaluation",
        "Mid-Term Review",
        "Completion Report",
        "Evaluation",
        "Project Document",
        "Review Sheet",
        "CEO Endorsement",
        "Project Implementation Report",
        "Agency Project Document",
        "Tracking Tool",
        "Project Identification Form",
    ]
    pattern = re.compile(
        r"terminal.evaluation|mid.?term.review|CEO.endorsement|project.document|"
        r"project.identification|PIF|evaluation|completion|PIR|MTR|TE",
        re.I,
    )
    selected = {}
    for row in rows:
        if not any(
            pattern.search(row.get(key, "") or "") for key in ("doc_type", "doc_title", "doc_url")
        ):
            continue
        rank = priority.index(row["doc_type"]) if row["doc_type"] in priority else 99
        code = row["gef_id"]
        if code not in selected or rank < selected[code][0]:
            selected[code] = (rank, row)
    return [row for _, row in selected.values()]


def normalize_reference(source: str, row: dict, path: Path) -> dict:
    """Convert a saved reference row to a standalone inclusion record with provenance."""
    row = {key: "" if value in {None, "NA"} else value for key, value in row.items()}
    if path.name == "doc_index.csv":
        url = row.get("url", "")
        direct = Path(urlsplit(url).path).suffix.lower() in REPORT_EXTENSIONS
        row.update(
            id="corpus_" + row["filename"],
            title=row.get("title") or row["filename"],
            pdf_url=url if direct else "",
            web_url="" if direct else url,
            reference_date=row.get("year", ""),
            doc_date="",
            reference_mapping=row.get("match_method", ""),
            reference_filename=row["filename"],
        )
    if path.name == "download_log.csv":
        row.update(
            id="reference_" + hashlib.sha256(url_key(row["url"]).encode()).hexdigest()[:16],
            pdf_url=row["url"],
            project_id=row.get("project_code", ""),
        )
    if source == "gef" and "doc_url" in row:
        digest = hashlib.sha256(row["doc_url"].encode()).hexdigest()[:16]
        row.update(
            id=f"{row['gef_id']}_{digest}",
            project_id=row["gef_id"],
            pdf_url=row["doc_url"],
            web_url=row["project_url"],
            title=row["project_title"] + ": " + row["doc_title"],
        )
    if source == "worldbank":
        row["project_id"] = ";".join(
            dict.fromkeys(re.findall(r"P\d{6}", row.get("project_id", "")))
        )
    if source in {"af", "gcf"}:
        # These snapshots use family approval as doc_date, never a report publication date.
        row["reference_date"] = row.get("reference_date") or row.get("doc_date", "")
        row["doc_date"] = ""
    identifier = (
        row.get("id") or hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()[:16]
    )
    return {
        **row,
        "id": identifier,
        "source": source,
        "reference_ids": [f"{path.name}:{identifier}"],
        "reference_urls": [row[key] for key in ("pdf_url", "source_url") if row.get(key)],
    }


def corpus_filename(source: str, row: dict) -> str:
    """Reproduce exact AF and CIF download names where the R naming rule is unambiguous."""
    value = row.get("doc_type", "") if source == "af" else row.get("id", "")
    plain = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    safe = re.sub(r"_+", "_", re.sub(r"[^A-Za-z0-9_-]", "_", plain)).strip("_")[:120]
    if source == "af":
        suffix = Path(urlsplit(row.get("pdf_url", "")).path).suffix or ".pdf"
        return f"af_{row.get('project_id', '')}_{safe}_{row.get('family_year', 'XXXX')}{suffix}"
    if source == "cif":
        return f"cif_{safe}_{row.get('doc_date', '')}"[:100] + ".pdf"
    return ""


def is_document_page(url: str) -> bool:
    """Exclude project-explorer family pages while allowing unique fund document pages."""
    parts = urlsplit(url)
    return bool(parts.path.strip("/")) and (
        "climateprojectexplorer.org" not in parts.netloc.lower()
        and not re.search(r"/(?:families|family|projects|project)(?:/|$)", parts.path, re.I)
    )


def selected_rows(source: str, path: Path) -> list[dict]:
    """Read each output according to its status, selection and source rules."""
    rows = read_rows(path)
    if path.name == "download_log.csv":
        return [
            row
            for row in rows
            if row.get("source") == source and row.get("status") == "success" and row.get("url")
        ]
    if path.name == "doc_index.csv":
        return [row for row in rows if row.get("source") == source]
    if source == "gef" and rows and "gef_id" in rows[0]:
        return gef_selected(rows)
    return r_kept(rows)


def load_baseline(source: str, paths: list[Path]) -> list[dict]:
    """Union saved snapshots by native ID, preserving all known direct file URLs."""
    combined = {}
    seen = {"url": {}, "name": {}, "page": {}}
    for path in paths:
        for row in selected_rows(source, path):
            reference = normalize_reference(source, row, path)

            # Log and index rows describe files; attach each to the reference it belongs to.
            if path.name in {"download_log.csv", "doc_index.csv"}:
                reference["id"] = known_id(reference, row, seen)
            key = reference["id"]
            combined[key] = classification.merge(combined.get(key, {}), reference)

            # Remember how this reference can be recognised by later log and index rows.
            for url in document_urls(reference):
                seen["url"].setdefault(url, key)
            if path.name != "doc_index.csv":
                name = corpus_filename(source, reference)
                if name:
                    seen["name"].setdefault(name, set()).add(key)
                if reference.get("web_url"):
                    seen["page"].setdefault(url_key(reference["web_url"]), set()).add(key)
    return list(combined.values())


def known_id(reference: dict, row: dict, seen: dict[str, dict]) -> str:
    """Return the ID of the earlier reference a log or index row describes, else its own ID.

    Tried in order: a shared file URL, the only reference with the same corpus file
    name, and the only reference with the same document page.
    """
    for url in sorted(document_urls(reference)):
        if url in seen["url"]:
            return seen["url"][url]
    names = seen["name"].get(row.get("filename", ""), set())
    if len(names) == 1:
        return next(iter(names))
    page = reference.get("web_url", "")
    if page and is_document_page(page):
        pages = seen["page"].get(url_key(page), set())
        if len(pages) == 1:
            return next(iter(pages))
    return reference["id"]


def document_urls(row: dict) -> set[str]:
    """Return file identities, excluding project and family pages shared by many documents."""
    urls = [row.get(field, "") for field in ("pdf_url", "source_url")]
    urls += classification.values(row.get("reference_urls"))
    return {
        url_key(value)
        for value in urls
        if value
        and (
            Path(urlsplit(value).path).suffix.lower() in REPORT_EXTENSIONS
            or is_document_page(value)
        )
    }


def r_kept(rows: list[dict]) -> list[dict]:
    """Return the R rows that R kept. Without a status column, every row counts as kept."""
    if not rows:
        return []
    status_column = next((name for name in ("screen_status", "status") if name in rows[0]), "")
    if not status_column:
        return rows
    return [row for row in rows if row[status_column] in R_KEPT_STATUSES]
