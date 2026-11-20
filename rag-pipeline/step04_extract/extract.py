"""
extract.py - step 04: ask the model to extract project facts from each report.

You choose what the model reads (the "method"):
    full_pdf      the original PDF, uploaded as a file
    full_parsed   every block of step 02's parsed output, in reading order, with page markers
    hybrid        about 12,000 tokens of step 03's chunks, picked by BM25 + embeddings (retrieval.py)

All methods use the same model, prompts and output format, so step 05 can compare them fairly.
Each report gets five separate tasks: identity, geography, rationale, results, finance.
Which reports: config/manifest.json. Model, budget and search settings: config/config.json.

Run from rag-pipeline/:
    python -m step04_extract.extract                                    # free preview: jobs, inputs, cost estimate
    python -m step04_extract.extract --execute --run-id pilot03         # paid: every method, every report
    python -m step04_extract.extract --methods hybrid --documents P001 --execute --run-id h01
    python -m step04_extract.extract --execute --run-id pilot03 --resume   # finish an interrupted run
    python -m step04_extract.extract --run-id pilot03 --export-only --xlsx # rebuild exports; no API calls

Only --execute spends money. The API key comes from the OPENAI_API_KEY environment variable or
from rag-pipeline/.env (a line OPENAI_API_KEY=...; .env is gitignored).

Outputs (data/04_extracted/<run-id>/):
    run.json            the frozen settings, inputs and code fingerprints of the run
    t01/<method>/<report>/<task>/   evidence sent, request, raw reply and checked result for each job
    exports/            results.csv (checked results), projects.csv (project fields), every report
    exports/<paper_id>/ the same two files for one report, plus facts.csv (everything the model said)
    ledger.json         every API call with its cost

From Python (this is what run.py does):
    from step04_extract import extract
    extract.run(methods=["hybrid"], documents=["P001"], execute=True, run_id="h01")
"""

import argparse
import json
import re
from datetime import datetime, timezone

from paths import EXTRACTED, ROOT
from step04_extract import runner
from step04_extract.api import Client, load_key
from step04_extract.exports import export_run
from step04_extract.files import CONFIG, MANIFEST, read_json
from step04_extract.inputs import load_manifest
from step04_extract.tasks import GROUPS, METHODS
from step04_extract.workbook import export_xlsx

CACHE = EXTRACTED / "cache"  # embeddings and PDF upload ids, shared by every run
ENV_FILE = ROOT / ".env"  # OPENAI_API_KEY=... (gitignored)


def run_folder(run_id):
    """data/04_extracted/<run_id>, refusing names that could escape that folder."""
    if not re.fullmatch(r"[A-Za-z0-9_-]+", run_id):
        raise ValueError("--run-id must contain only letters, digits, underscores or hyphens.")
    return EXTRACTED / run_id


def write_exports(output, xlsx):
    """Write the run's tables (exports.py) and, if asked, the filled results workbook."""
    tables = export_run(output)
    print(
        ", ".join(f"{len(rows)} {name} rows" for name, rows in tables.items()),
        "->",
        output / "exports",
    )
    if xlsx:
        print(export_xlsx(output, tables["results"], tables["projects"]))


def run(
    documents=None,
    methods=METHODS,
    groups=GROUPS,
    repeats=1,
    run_id="",
    execute=False,
    resume=False,
    max_cost_usd=None,
    xlsx=False,
    export_only=False,
):
    """Preview (the default) or run extraction. Returns the run folder, or None for a preview.

    documents = project codes or paper ids from the manifest (None = every report).
    """
    if export_only:
        if not run_id:
            raise ValueError("--export-only needs --run-id.")
        output = run_folder(run_id)
        write_exports(output, xlsx)
        return output

    methods, groups = list(methods), list(groups)
    if repeats < 1 or len(set(methods)) != len(methods) or len(set(groups)) != len(groups):
        raise ValueError("Repeats must be positive; methods and groups must be unique.")
    docs = load_manifest(MANIFEST, documents)
    config = read_json(CONFIG / "config.json")
    if max_cost_usd is not None:
        config["budget_usd"] = max_cost_usd
    if config["budget_usd"] <= 0:
        raise ValueError("Budget must be greater than zero.")

    # 1. Read every input and plan the jobs (report x method x task x trial). Free.
    prepared, errors = runner.prepare(docs)
    planned = runner.jobs(docs, methods, groups, repeats)
    preview = runner.dry_plan(docs, planned, prepared, errors, config)
    print(json.dumps({k: v for k, v in preview.items() if k != "estimates"}, indent=2))
    if preview["errors"]:
        raise ValueError("Fix the input errors above first.")
    if not execute:
        print("Preview only: nothing was sent. Add --execute to run it (paid).")
        return None

    # 2. Run the jobs. Paid.
    run_id = run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = run_folder(run_id)
    runner.start_run(output, planned, prepared, config, resume)
    client = Client(config, output, CACHE, load_key(ENV_FILE))
    success = runner.execute(planned, prepared, config, client, output, CACHE)

    # 3. Write the tables. Free.
    write_exports(output, xlsx)
    print(
        f"Run {run_id}: "
        + ("all jobs completed." if success else "some jobs failed; see the run folder.")
    )
    print(f"Next: python -m step05_evaluate.evaluate --run-id {run_id}")
    return output


def main():
    ap = argparse.ArgumentParser(description="Step 04: extract project facts from each report.")
    ap.add_argument(
        "--documents",
        nargs="+",
        metavar="ID",
        help="project codes or paper ids from the manifest (default: all)",
    )
    ap.add_argument("--methods", nargs="+", choices=METHODS, default=list(METHODS))
    ap.add_argument(
        "--groups", nargs="+", choices=GROUPS, default=list(GROUPS), help="tasks to run"
    )
    ap.add_argument(
        "--repeats", type=int, default=1, help="trials per job, to see run-to-run variation"
    )
    ap.add_argument("--run-id", default="", help="run folder name under data/04_extracted/")
    ap.add_argument(
        "--execute", action="store_true", help="make the paid API calls (default: preview)"
    )
    ap.add_argument(
        "--resume", action="store_true", help="continue an interrupted run with the same settings"
    )
    ap.add_argument("--max-cost-usd", type=float, help="override the budget in config.json")
    ap.add_argument("--xlsx", action="store_true", help="also fill the results workbook")
    ap.add_argument(
        "--export-only",
        action="store_true",
        help="rebuild an existing run's exports; no API calls",
    )
    args = ap.parse_args()
    try:
        run(
            documents=args.documents,
            methods=args.methods,
            groups=args.groups,
            repeats=args.repeats,
            run_id=args.run_id,
            execute=args.execute,
            resume=args.resume,
            max_cost_usd=args.max_cost_usd,
            xlsx=args.xlsx,
            export_only=args.export_only,
        )
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f"Error: {error}") from error


if __name__ == "__main__":
    main()
