# Step 05: evaluate

Compares the methods of one step 04 run and, once the answer key is checked, scores them.

| | |
|---|---|
| Reads | `data/04_extracted/<run-id>/` and the answer key `labels/review.json` |
| Writes | `data/05_eval/<run-id>/` |

## Run

```powershell
python -m step05_evaluate.evaluate --run-id pilot03     # comparison pages, plus scores if the key exists
python -m step05_evaluate.evaluate --init-review        # create the answer key from Lolita's test set (once)
python -m step05_evaluate.compare --run-id pilot03      # optional: this run vs the Alliance's R pipeline and the gold answers
python -m step05_evaluate.dashboard --run-id pilot03    # optional, after compare: one HTML page to share (needs a hand check, below)
```

`compare` writes `data/05_eval/<run-id>/compare/` (summary.json, by_report.csv, gold_matches.csv): rows
delivered, gold values found (same lenient number-match rule for R and for us), verified rate, page right
first time, rows needing review, and cost per method. It needs no answer-key review. R's output counts
all three places it writes results: result1-3, the "further results" in result_notes, and the location sheet.

`dashboard` writes `data/05_eval/<run-id>/dashboard.html`: one self-contained page (no internet needed) that
explains the comparison with examples, shows every answer-key result next to what each output has for it,
and lists every value from both pipelines. Its "found" counts come from a hand check,
`labels/gold_check_<run-id>.json`, not from compare's lenient match: for each answer-key result and each
source, a verdict (yes / partial / no) and a piece of text that picks the row shown as evidence. The script
stops if a picked row is not in the run. The page's sentences and examples were written for meetingsample01,
so after a new run, re-check them.

## Outputs

```
data/05_eval/<run-id>/
  reports/comparison.html   every method's answers side by side, with links to the PDF pages and the cost
  reports/review.html       the same with the method names hidden (A, B, C), for blind review
  reports/review_key.json   which letter is which method; don't open it until the review is done
  scores/summary.json       per method and task: how many checked answers were found, how many answers were right
  scores/claims.csv         every extracted fact with its verdict
  scores/retrieval.csv      hybrid only: was each answer's evidence in what the model was sent?
```

## The answer key (labels/review.json)

1. `--init-review` copies Lolita's reference answers (`test_set/` at the top of the repo) into
   `labels/review.json` as **unreviewed** labels, for every report in step 04's manifest.
   It never overwrites the file.
2. A person checks each label against the PDF and sets `"reviewed": true`. Only reviewed labels count,
   because the reference set has known problems (rounded numbers, values nobody could locate,
   printed instead of PDF page numbers). How to write a label: [labels/README.md](labels/README.md).
3. For precision (how many extracted rows are right), someone marks rows correct or incorrect in
   `review.html`; those verdicts are saved in the same file.
4. Run `evaluate` again: it scores only what has been reviewed.

`labels/review.json` is in git, so the whole team shares the checked answers.

## Files

- `evaluate.py` - the command: pages, then scores.
- `report.py` - writes the comparison and blind review pages.
- `scoring.py` - matches extracted facts to reviewed labels (value, metric, unit and scope must all match).
- `benchmark.py` - creates the unreviewed answer key from the test set.
- `compare.py` - optional: the run against the R pipeline's output and the gold answers.
- `dashboard.py`, `dashboard_template.html` - optional: the shareable HTML page for a run.
- `labels/gold_check_<run-id>.json` - the hand check the dashboard's "found" counts come from.
