"""Run a small, reproducible extraction comparison; live calls require --execute."""

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

from common.api import Client, load_key
from common.files import ROOT, read_json, write_json
from common.inputs import load_manifest
from common.runner import dry_plan, execute, jobs, prepare, start_run
from common.tasks import GROUPS, METHODS
from common.workbook import export_xlsx
from evaluation.benchmark import seed
from evaluation.r_baseline import import_baseline
from evaluation.report import report
from evaluation.scoring import evaluate


def parser() -> argparse.ArgumentParser:
    """Expose one small CLI with no implicit live mode."""
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("command", choices=["prepare", "run", "evaluate", "report", "import-r"])
    result.add_argument("--manifest", type=Path, default=ROOT / "inputs/manifest.json")
    result.add_argument("--config", type=Path, default=ROOT / "config.json")
    result.add_argument("--documents", nargs="+")
    result.add_argument("--methods", nargs="+", choices=METHODS, default=list(METHODS))
    result.add_argument("--groups", nargs="+", choices=GROUPS, default=list(GROUPS))
    result.add_argument("--repeats", type=int, default=1)
    result.add_argument("--run-id", default="")
    result.add_argument("--resume", action="store_true")
    result.add_argument(
        "--xlsx",
        action="store_true",
        help="Fill the supplied workbook from saved exports without additional model calls.",
    )
    mode = result.add_mutually_exclusive_group()
    mode.add_argument(
        "--execute", action="store_true", help="Allow paid embeddings and extraction."
    )
    mode.add_argument("--dry-run", action="store_true", help="Preview only (also the default).")
    result.add_argument("--max-cost-usd", type=float)
    result.add_argument("--env-file", type=Path, default=ROOT.parents[1] / ".env")
    result.add_argument("--benchmark", type=Path, default=ROOT / "benchmarks/review.json")
    result.add_argument("--r-manifest", type=Path, help="Explicit saved raw R group JSON files.")
    result.add_argument(
        "--init-review", action="store_true", help="Seed unreviewed labels; never overwrite."
    )
    return result


def run_path(identifier: str) -> Path:
    """Constrain generated runs to this experiment's results folder."""
    if not re.fullmatch(r"[A-Za-z0-9_-]+", identifier):
        raise ValueError("--run-id must contain only letters, digits, underscores or hyphens.")
    return ROOT / "results" / identifier


def main() -> int:
    """Dispatch offline work before constructing any authenticated API client."""
    args = parser().parse_args()
    try:
        if args.command in ("report", "evaluate", "import-r"):
            return review_command(args)
        if (
            args.repeats < 1
            or len(set(args.methods)) != len(args.methods)
            or len(set(args.groups)) != len(args.groups)
        ):
            raise ValueError("Repeats must be positive; methods and groups must be unique.")
        documents = load_manifest(args.manifest.resolve(), args.documents)
        config = read_json(args.config)
        if args.max_cost_usd is not None:
            config["budget_usd"] = args.max_cost_usd
        if config["budget_usd"] <= 0:
            raise ValueError("Budget must be greater than zero.")
        prepared, errors = prepare(documents)
        planned = jobs(documents, args.methods, args.groups, args.repeats)
        preview = dry_plan(documents, planned, prepared, errors, config)
        errors = preview["errors"]
        print(
            json.dumps(
                {key: value for key, value in preview.items() if key != "estimates"}, indent=2
            )
        )
        if args.command == "prepare":
            for name, value in prepared.items():
                write_json(ROOT / "results/prepared" / f"{name}.json", value)
            write_json(ROOT / "results/prepared/plan.json", preview)
            return 2 if errors else 0
        if not args.execute or errors:
            return 2 if errors else 0
        identifier = args.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        output = run_path(identifier)
        start_run(output, planned, prepared, config, args.resume)
        client = Client(config, output, ROOT / "cache", load_key(args.env_file))
        success = execute(planned, prepared, config, client, output, ROOT / "cache")
        report(output)
        if args.xlsx:
            print(export_xlsx(output))
        return 0 if success else 1
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"Error: {error}")
        return 2


def review_command(args: argparse.Namespace) -> int:
    """Initialize labels or evaluate/report saved outputs with no API client."""
    if args.init_review:
        seed(args.benchmark, load_manifest(args.manifest.resolve(), args.documents))
        print(f"Unreviewed labels: {args.benchmark}")
        return 0
    if not args.run_id:
        raise ValueError("Specify --run-id to evaluate or report saved outputs.")
    output = run_path(args.run_id)
    if args.command == "import-r":
        if not args.r_manifest:
            raise ValueError(
                "Specify --r-manifest; this command reads saved R output and never runs R."
            )
        print(f"Imported {import_baseline(output, args.r_manifest.resolve())} raw R tasks.")
    if args.command == "evaluate":
        print(json.dumps(evaluate(output, args.benchmark), indent=2))
    for path in report(output):
        print(path)
    if args.xlsx:
        print(export_xlsx(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
