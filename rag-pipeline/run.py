"""
run.py - run the pipeline steps in order.

Run from rag-pipeline/:
    python run.py                                   # steps 02 to 05 (step 04 only previews: free)
    python run.py --from 03 --to 03                 # just one step
    python run.py --only P001_doc3                  # one paper through every step
    python run.py --check                           # also run each step's quick check after it
    python run.py --from 04 --execute --run-id pilot03   # paid extraction, then evaluation
    python run.py --from 05 --run-id pilot03        # evaluate a run that already exists

Every step skips work that is already done, so rerunning is cheap. Step 04 spends money only
with --execute. To redo finished work or change a step's settings, run that step on its own,
e.g. python -m step03_chunk.chunk --force. See each step folder's README.
"""
import argparse
from datetime import datetime, timezone

from paths import EXTRACTED


def step02(only, check, execute, run_id):
    from step02_parse import parse, review      # imported here so later steps never load Docling
    parse.run(only=only)
    if check:
        review.run(only=only)


def step03(only, check, execute, run_id):
    from step03_chunk import check_chunks, chunk
    chunk.run(only=only)
    if check:
        check_chunks.run()                      # checks every gold project; takes a few seconds


def step04(only, check, execute, run_id):
    from step04_extract import extract
    extract.run(documents=only, execute=execute, run_id=run_id)


def step05(only, check, execute, run_id):
    from step05_evaluate import evaluate
    if not run_id or not (EXTRACTED / run_id / "run.json").exists():
        print("skipped: no step 04 run to evaluate (use --execute, or --run-id of an existing run)")
        return
    evaluate.run(run_id=run_id)


STEPS = {
    "02": ("parse", step02),
    "03": ("chunk", step03),
    "04": ("extract", step04),
    "05": ("evaluate", step05),
}


def run(start="02", end="05", only=None, check=False, execute=False, run_id=""):
    """Run steps start..end in order. only = list of paper ids (None = all papers)."""
    if execute and not run_id:
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for number, (name, step) in STEPS.items():
        if start <= number <= end:
            print(f"\n=== step {number}: {name} ===")
            step(only=only, check=check, execute=execute, run_id=run_id)


def main():
    ap = argparse.ArgumentParser(description="Run the pipeline steps in order.")
    ap.add_argument("--from", dest="start", choices=list(STEPS), default="02", help="first step to run")
    ap.add_argument("--to", dest="end", choices=list(STEPS), default="05", help="last step to run")
    ap.add_argument("--only", nargs="+", metavar="PAPER_ID", help="only these papers (file stems)")
    ap.add_argument("--check", action="store_true", help="run each step's quick check after it")
    ap.add_argument("--execute", action="store_true", help="let step 04 make paid API calls")
    ap.add_argument("--run-id", default="", help="step 04/05 run name (default: a timestamp)")
    args = ap.parse_args()
    if args.start > args.end:
        ap.error("--from must come before --to")
    try:
        run(start=args.start, end=args.end, only=args.only, check=args.check,
            execute=args.execute, run_id=args.run_id)
    except (ValueError, OSError) as error:
        raise SystemExit(f"Error: {error}")


if __name__ == "__main__":
    main()
