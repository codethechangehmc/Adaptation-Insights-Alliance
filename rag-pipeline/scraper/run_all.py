"""Run every source in turn and log one status line each. One failure does not stop the rest.

Usage:
    python rag-pipeline/scraper/run_all.py [--sources worldbank gef ...] [options]

Other options, such as --metadata-only or --max-downloads 5, go to every source.
Each source writes to its usual outputs/<source>/ and downloads/<source>/ folders.
"""

from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
import time
from pathlib import Path

from run import BATCH_COMMANDS

REPO = Path(__file__).resolve().parents[2]
SCRAPER_DIR = Path(__file__).resolve().parent
LOG = logging.getLogger("run_all")


def latest_summary(source: str, output_dir: Path, started: float = 0) -> dict:
    """Return the newest summary written by this invocation, or an empty dict."""
    runs = output_dir / ("project_runs" if source == "worldbank_projects" else "runs")
    paths = sorted(runs.glob("*/summary.json"))
    if not paths or paths[-1].stat().st_mtime < started:
        return {}
    try:
        return json.loads(paths[-1].read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def status_line(source: str, exit_code: int, seconds: float, summary: dict) -> str:
    """Describe one source's run in one line."""
    parts = [f"{source}: exit {exit_code}", summary.get("status", "no summary")]
    if summary.get("mode") and summary["mode"] != "live_search":
        parts.append(summary["mode"])
    if "kept" in summary:
        parts.append(f"{summary['kept']} kept of {summary.get('unique_records', '?')}")
    if summary.get("failed_ids"):
        parts.append(f"{len(summary['failed_ids'])} failed downloads")
    if summary.get("drift_warnings"):
        parts.append(f"{len(summary['drift_warnings'])} drift warnings")
    parts.append(f"{seconds:.0f}s")
    return ", ".join(parts)


def main(argv: list[str] | None = None) -> int:
    """Run the chosen sources one after another. Returns 1 if any source failed."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--sources",
        nargs="+",
        default=BATCH_COMMANDS,
        help="sources to run, in order (default: every source)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO / "outputs",
        help="base folder; each source gets its own subfolder",
    )
    parser.add_argument(
        "--download-dir",
        type=Path,
        default=REPO / "downloads",
        help="base folder; each source gets its own subfolder",
    )
    args, passed_on = parser.parse_known_args(argv)
    unknown = set(args.sources) - set(BATCH_COMMANDS)
    if unknown:
        parser.error(f"Unknown sources: {', '.join(sorted(unknown))}")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

    # Run each source in its own process, so one crash cannot stop the others.
    lines, failures = [], 0
    for source in args.sources:
        started = time.monotonic()
        written_after = time.time()
        folder = "worldbank" if source == "worldbank_projects" else source
        output_dir = args.output_dir / folder
        command = [
            sys.executable,
            str(SCRAPER_DIR / "run.py"),
            source,
            "--output-dir",
            str(output_dir),
            "--download-dir",
            str(args.download_dir / folder),
            *passed_on,
        ]
        exit_code = subprocess.run(command, check=False).returncode
        failures += exit_code != 0
        summary = latest_summary(source, output_dir, written_after)
        lines.append(status_line(source, exit_code, time.monotonic() - started, summary))

    for line in lines:
        LOG.info("%s", line)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
