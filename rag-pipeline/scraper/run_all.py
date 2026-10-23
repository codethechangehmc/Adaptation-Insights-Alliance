"""Run every source and log one status line each. One failure does not stop the rest.

Usage:
    python rag-pipeline/scraper/run_all.py [--sources worldbank gef ...] [options]

Sources run side by side in the lanes set in run.py; sources in one lane run in
order. Each output line starts with its source name, for example [afdb].
Other options, such as --metadata-only or --max-downloads 5, go to every source.
Each source writes to its usual outputs/<source>/ and downloads/<source>/ folders.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from run import BATCH_COMMANDS, BATCH_LANES

REPO = Path(__file__).resolve().parents[2]
SCRAPER_DIR = Path(__file__).resolve().parent
LOG = logging.getLogger("run_all")
PRINT_LOCK = threading.Lock()


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


def run_command(source: str, command: list[str]) -> int:
    """Run one source in its own process, printing its output prefixed with its name."""
    environment = {**os.environ, "PYTHONIOENCODING": "utf-8"}
    with subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
        env=environment,
    ) as child:
        for line in child.stdout:
            with PRINT_LOCK:
                print(f"[{source}] {line.rstrip()}", flush=True)
    return child.returncode


def run_source(source: str, args: argparse.Namespace, passed_on: list[str]) -> tuple[int, str]:
    """Run one source and return its exit code and status line."""
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
    exit_code = run_command(source, command)
    summary = latest_summary(source, output_dir, written_after)
    return exit_code, status_line(source, exit_code, time.monotonic() - started, summary)


def run_lane(
    lane: list[str], args: argparse.Namespace, passed_on: list[str]
) -> dict[str, tuple[int, str]]:
    """Run the sources of one lane in order."""
    return {source: run_source(source, args, passed_on) for source in lane}


def main(argv: list[str] | None = None) -> int:
    """Run the chosen sources, lanes side by side. Returns 1 if any source failed."""
    args, passed_on = parse_arguments(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

    # Each source runs in its own process, so one crash cannot stop the others.
    lanes = [[source for source in lane if source in args.sources] for lane in BATCH_LANES]
    lanes = [lane for lane in lanes if lane]
    results: dict[str, tuple[int, str]] = {}
    with ThreadPoolExecutor(max_workers=len(lanes)) as pool:
        for lane_results in pool.map(lambda lane: run_lane(lane, args, passed_on), lanes):
            results.update(lane_results)

    # Report in batch order, whatever order the lanes finished in.
    for source in BATCH_COMMANDS:
        if source in results:
            LOG.info("%s", results[source][1])
    return 1 if any(exit_code for exit_code, _ in results.values()) else 0


def parse_arguments(argv: list[str] | None) -> tuple[argparse.Namespace, list[str]]:
    """Read the batch options; every other option is passed on to each source."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--sources",
        nargs="+",
        default=BATCH_COMMANDS,
        help="sources to run (default: every source)",
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
    return args, passed_on


if __name__ == "__main__":
    raise SystemExit(main())
