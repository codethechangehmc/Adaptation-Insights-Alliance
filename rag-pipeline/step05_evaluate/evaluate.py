"""
evaluate.py - step 05: compare the methods of one step 04 run and score them against checked answers.

Writes data/05_eval/<run-id>/:
    reports/comparison.html   every method's answers side by side, with PDF page links and cost
    reports/review.html       the same with the method names hidden (A, B, C), for blind review
    reports/review_key.json   which letter is which method; don't open it until the review is done
    scores/summary.json       found / correct counts per method and task (once labels are reviewed)
    scores/claims.csv         every extracted fact with its verdict
    scores/retrieval.csv      hybrid only: was each label's evidence in what the model was sent?

The answer key is step05_evaluate/labels/review.json (see labels/README.md):
    python -m step05_evaluate.evaluate --init-review        # create it from Lolita's test set, once
    ...a person checks each label against the PDF and sets "reviewed": true...
    python -m step05_evaluate.evaluate --run-id pilot03     # pages + scores

From Python (this is what run.py does):
    from step05_evaluate import evaluate
    evaluate.run(run_id="pilot03")
"""
import argparse
import json
from pathlib import Path

from paths import EVAL, EXTRACTED, LABELS
from step04_extract.files import MANIFEST
from step04_extract.inputs import load_manifest
from step05_evaluate import scoring
from step05_evaluate.benchmark import seed
from step05_evaluate.report import report


def run(run_id=None, init_review=False, labels=LABELS):
    """Write the comparison and review pages for run_id, and score it if the answer key exists."""
    if init_review:
        seed(labels, load_manifest(MANIFEST))
        print(f"Wrote unreviewed labels to {labels}. Check them against the PDFs before scoring.")
        if not run_id:
            return None
    if not run_id:
        raise ValueError("Give --run-id (a folder under data/04_extracted/).")
    run_dir = EXTRACTED / run_id
    if not (run_dir / "run.json").exists():
        raise ValueError(f"No run at {run_dir}. Run step 04 with --execute first.")
    out_dir = EVAL / run_id

    for path in report(run_dir, out_dir):
        print(path)
    if not Path(labels).exists():
        print(f"No answer key yet ({labels}), so only the pages were written. Create it with --init-review.")
        return None
    summary = scoring.evaluate(run_dir, Path(labels), out_dir)
    print(json.dumps(summary["groups"], indent=2))
    if not summary["reviewed_labels"]:
        print("No label is marked reviewed yet, so nothing was scored.")
    return summary


def main():
    ap = argparse.ArgumentParser(description="Step 05: compare and score a step 04 run.")
    ap.add_argument("--run-id", help="run folder under data/04_extracted/")
    ap.add_argument("--init-review", action="store_true",
                    help="create the answer key from Lolita's test set (never overwrites)")
    ap.add_argument("--labels", type=Path, default=LABELS, help="answer key to score against")
    args = ap.parse_args()
    try:
        run(run_id=args.run_id, init_review=args.init_review, labels=args.labels)
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(f"Error: {error}")


if __name__ == "__main__":
    main()
