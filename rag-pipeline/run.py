"""
run.py - run the pipeline steps in order.

Run from rag-pipeline/:
    python run.py                         # steps 02 to 05
    python run.py --from 03 --to 03       # just one step
    python run.py --only P001_doc3        # one paper through every step
    python run.py --check                 # also run each step's quick check after it

Every step skips papers that are already done, so rerunning is cheap.
To redo finished work (--force) or change a step's settings, run that step on its own,
e.g. python -m step03_chunk.chunk --force. See each step folder's README.
"""
import argparse


def step02(only, check):
    from step02_parse import parse, review      # imported here so later steps never load Docling
    parse.run(only=only)
    if check:
        review.run(only=only)


def step03(only, check):
    from step03_chunk import check_chunks, chunk
    chunk.run(only=only)
    if check:
        check_chunks.run()                      # checks every gold project; takes a few seconds


def step04(only, check):
    print("not built yet (comes with the extraction branch)")


def step05(only, check):
    print("not built yet")


STEPS = {
    "02": ("parse", step02),
    "03": ("chunk", step03),
    "04": ("extract", step04),
    "05": ("evaluate", step05),
}


def run(start="02", end="05", only=None, check=False):
    """Run steps start..end in order. only = list of paper ids (None = all papers)."""
    for number, (name, step) in STEPS.items():
        if start <= number <= end:
            print(f"\n=== step {number}: {name} ===")
            step(only=only, check=check)


def main():
    ap = argparse.ArgumentParser(description="Run the pipeline steps in order.")
    ap.add_argument("--from", dest="start", choices=list(STEPS), default="02", help="first step to run")
    ap.add_argument("--to", dest="end", choices=list(STEPS), default="05", help="last step to run")
    ap.add_argument("--only", nargs="+", metavar="PAPER_ID", help="only these papers (file stems)")
    ap.add_argument("--check", action="store_true", help="run each step's quick check after it")
    args = ap.parse_args()
    if args.start > args.end:
        ap.error("--from must come before --to")
    run(start=args.start, end=args.end, only=args.only, check=args.check)


if __name__ == "__main__":
    main()
