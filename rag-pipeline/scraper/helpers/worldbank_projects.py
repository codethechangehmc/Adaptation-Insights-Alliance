"""Retrieve World Bank project details for the projects in a document catalogue.

Source:     https://search.worldbank.org/api/v2/projects
Strategy:   exact project ID lookups from worldbank_metadata.csv
Pagination: each exact lookup must return exactly its requested ID (checked 2026-10-15)
Query cap:  not applicable to exact single-project lookups
Quirks:     v2 supplies lendinginstr; v3 omits it by default (P119662, 2026-10-15).
            Commitment and cost fields are USD; curr_* fields use millions instead.

Writes worldbank_projects.csv atomically only after every lookup succeeds. It
never removes document records or downloads. Shared download/date options are
accepted for run_all compatibility but do not filter project metadata.
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from core import runner, storage
from core.fetch import Client, RequestFailed

SOURCE = "worldbank"
REPO = Path(__file__).resolve().parents[3]
API = "https://search.worldbank.org/api/v2/projects"
LOG = logging.getLogger("scraper")
PROJECT_CODE = re.compile(r"\bP\d{6}\b", re.IGNORECASE)
FIELDS = [
    "project_id",
    "project_name",
    "country",
    "sectors",
    "major_sectors",
    "themes",
    "lending_instrument",
    "approval_date",
    "closing_date",
    "total_commitment_usd",
    "ibrd_commitment_usd",
    "ida_commitment_usd",
    "project_cost_usd",
    "web_url",
    "retrieved_at",
    "retrieval_status",
    "status",
    "region",
    "borrower",
    "implementing_agency",
    "team_leader",
    "environmental_category",
    "raw_metadata",
]


def add_arguments(parser: argparse.ArgumentParser) -> None:
    """Add the input catalogue path to the shared command options."""
    parser.add_argument(
        "--catalogue",
        type=Path,
        help="input documents (default: <output-dir>/worldbank_metadata.csv)",
    )


def project_ids(path: Path) -> list[str]:
    """Read every distinct project code from the catalogue's project_id column."""
    rows = storage.read_csv(path)
    if rows and "project_id" not in rows[0]:
        raise ValueError(f"Catalogue has no project_id column: {path}")

    # A document can cover several projects, separated by commas or semicolons.
    return sorted(
        {code.upper() for row in rows for code in PROJECT_CODE.findall(row.get("project_id", ""))}
    )


def names(value: object) -> str:
    """Join API name values without including taxonomy codes or percentages."""
    if isinstance(value, list):
        return "; ".join(dict.fromkeys(filter(None, (names(item) for item in value))))
    if isinstance(value, dict):
        return str(value.get("name") or value.get("Name") or "").strip()
    return str(value or "").strip()


def project_date(value: object) -> str:
    """Convert the API's ISO or US timestamp to an ISO calendar date."""
    text = str(value or "").strip()
    if not text:
        return ""

    # The v2 closingdate uses US timestamps (P119662, checked 2026-10-15).
    for date_format in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%SZ", "%m/%d/%Y %I:%M:%S %p"):
        try:
            return datetime.strptime(text, date_format).date().isoformat()
        except ValueError:
            continue
    raise ValueError(f"Unrecognised project date: {text!r}")


def normalize_project(project: dict) -> dict:
    """Map the v2 project response to named fields with explicit amount units."""
    row = {
        "project_id": project["id"],
        "project_name": names(project.get("project_name")),
        "country": names(project.get("countryname")),
        "sectors": names(project.get("sector_namecode") or project.get("sector")),
        "major_sectors": names(project.get("mjsector_namecode")),
        "themes": names(project.get("theme_namecode") or project.get("theme_list")),
        "lending_instrument": names(project.get("lendinginstr")),
        "approval_date": project_date(project.get("boardapprovaldate")),
        "closing_date": project_date(project.get("closingdate")),
        "web_url": names(project.get("url")),
        "retrieved_at": storage.utc_now(),
        "retrieval_status": "found",
        "status": names(project.get("projectstatusdisplay") or project.get("status")),
        "region": names(project.get("regionname")),
        "borrower": names(project.get("borrower")),
        "implementing_agency": names(project.get("impagency")),
        "team_leader": names(project.get("teamleadname")),
        "environmental_category": names(project.get("envassesmentcategorycode")),
        "raw_metadata": json.dumps(project, ensure_ascii=False, sort_keys=True),
    }

    # Use absolute USD fields, never the similarly named current amounts in millions.
    for column, field in (
        ("total_commitment_usd", "totalcommamt"),
        ("ibrd_commitment_usd", "ibrdcommamt"),
        ("ida_commitment_usd", "idacommamt"),
        ("project_cost_usd", "lendprojectcost"),
    ):
        row[column] = str(project.get(field) or "").replace(",", "").strip()
    return row


def fetch_project(client: Client, project_id: str) -> dict:
    """Require one exact API match so ignored filters cannot corrupt the output."""
    payload = client.get_json(API, params={"format": "json", "id": project_id, "rows": 1})
    projects = payload.get("projects", {})
    # Some catalogue codes have no public project record (P156317, checked 2026-10-15).
    # Record an explicit absence; a successful empty lookup is not a network failure.
    if int(payload.get("total", -1)) == 0 and projects == {}:
        return {
            "project_id": project_id,
            "retrieval_status": "not_found",
            "retrieved_at": storage.utc_now(),
        }
    if int(payload.get("total", -1)) != 1 or set(projects) != {project_id}:
        raise ValueError(f"Expected one exact result for {project_id}")
    project = projects[project_id]
    if project.get("id") != project_id:
        raise ValueError(f"Response ID differs from {project_id}")
    return normalize_project(project)


def collect_projects(client: Client, ids: list[str], workers: int) -> tuple[list[dict], dict]:
    """Fetch all project IDs and record failures without publishing a partial table."""
    rows, failures = [], {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(fetch_project, client, code): code for code in ids}
        for future in as_completed(futures):
            code = futures[future]
            try:
                rows.append(future.result())
            except (RequestFailed, ValueError, KeyError, TypeError) as error:
                failures[code] = str(error)
                LOG.error("Project %s: %s", code, error)
            if (len(rows) + len(failures)) % 50 == 0:
                LOG.info("Projects: %d of %d checked", len(rows) + len(failures), len(ids))
    return sorted(rows, key=lambda row: row["project_id"]), failures


def run(args: argparse.Namespace, run_dir: Path) -> int:
    """Write a run summary and replace the project table only on full success."""
    catalogue = args.catalogue or args.output_dir / "worldbank_metadata.csv"
    summary = {
        "source": "worldbank_projects",
        "status": "running",
        "started_at": storage.utc_now(),
    }
    try:
        ids = project_ids(catalogue)
        client = Client(args.request_interval)
        rows, failures = collect_projects(client, ids, args.workers)
        summary.update(expected=len(ids), retrieved=len(rows), failed_ids=failures)
        summary["not_found_ids"] = [
            row["project_id"] for row in rows if row["retrieval_status"] == "not_found"
        ]
        summary["status"] = "incomplete_search" if failures else "complete"
        if not failures:
            storage.write_csv(args.output_dir / "worldbank_projects.csv", rows, FIELDS)
        LOG.info("Projects: %d of %d, %s", len(rows), len(ids), summary["status"])
    except (OSError, ValueError) as error:
        summary.update(status="failed", error=str(error))
        LOG.error("%s", error)
    except KeyboardInterrupt:
        summary["status"] = "interrupted"
        return 130
    finally:
        summary["finished_at"] = storage.utc_now()
        storage.write_json(run_dir / "summary.json", summary)
    return 0 if summary["status"] == "complete" else 1


def main(argv: list[str] | None = None) -> int:
    """Parse shared options and lock the World Bank output directory."""
    args = runner.parse_arguments(sys.modules[__name__], argv)
    args.output_dir = args.output_dir.resolve()
    run_dir = runner.new_run_dir(args.output_dir / "project_runs")

    # Use the document runner's lock because both commands share the output folder.
    handlers = runner.start_logging(run_dir / "run.log")
    try:
        with storage.directory_lock(args.output_dir / ".run.lock"):
            return run(args, run_dir)
    except RuntimeError as error:
        LOG.error("%s", error)
        return 1
    finally:
        runner.stop_logging(handlers)


if __name__ == "__main__":
    raise SystemExit(main())
