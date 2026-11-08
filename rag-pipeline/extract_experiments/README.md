# Extraction experiments

This experiment asks one question: which evidence should the model read when it
extracts project facts from an evaluation report? It compares three methods on
the same model, prompts and output schema:

| Method | What the model reads |
|---|---|
| `hybrid` | About 12,000 tokens of passages picked by BM25 plus embeddings, merged by reciprocal rank fusion |
| `full_parsed` | Every parsed block of the report, once, in reading order, with PDF page markers |
| `full_pdf` | The original PDF, uploaded once, with low image detail |

Each method runs five separate tasks per report: identity, geography,
rationale, results and finance. Three reports, three methods and five tasks
make 45 model calls per trial. The output is raw facts with quotes and PDF
pages, plus a mapping to the team's results workbook. Screening and
harmonisation are out of scope. [DECISIONS.md](DECISIONS.md) explains the
choices behind the prompts, retrieval, checks and exports.

The reports are development cases from the tuning set:

| Case | Report | What it tests |
|---|---|---|
| P001 | TerrAfrica ICR, 57 pages | World Bank identity, finance and results tables |
| P009 | SWIOFish1 ICR, 89 pages | A long results framework and several countries |
| P007 | Rwanda financial education evaluation, 24 pages | An agency report with scanned annexes |

## Pilot results, 2026-11-05

Run `template_pilot_20261105`: one trial, all 45 calls completed, US$1.64.
The reference answers in `test_set/` have not been reviewed against the PDFs,
so these numbers are a first look, not an accuracy claim.

| | hybrid | full_pdf | full_parsed |
|---|---:|---:|---:|
| Cost (15 calls) | $0.22 | $0.79 | $0.59 |
| Job time, summed | 148 s | 233 s | 107 s |
| Reference results found (of 10) | 9 | 8 | 8 |
| Result rows exported | 44 | 58 | 50 |
| Result values found on their PDF page | 44 | 44 | 47 |

- **Project facts are strong in every method.** Title, project ID, start,
  closing and publication years, budget and disbursement match the reference
  for P001 and P009. P009's title keeps the `AFCC2/RI-` prefix printed on the
  data sheet.
- **Hybrid gave the best value.** It found the most reference results, at
  about a quarter of the cost of the full PDF. It missed the P009 project lead.
- **Full PDF cites printed page numbers.** Its pages were off by the length of
  the front matter (5 or 6 pages on P001 and P009), so only 5 of 58 values
  checked out on the cited page. The exporter now string-matches each quote
  back to the PDF and moves the page when exactly one page fits; 44 of 58 now
  check out. It also exported 8 Yes/No milestones that the rules exclude. It
  was the only method to find P007's publication year, which is on the cover.
- **Full parsed had no edge over hybrid.** It cost more, found the same or
  fewer results, and counted only 15 countries for P001 (the reference
  accepts 22 to 26).
- **Every method missed** P001's ">1000 e-learning participants" (narrative
  text, not the results table). All three exported P007 context figures
  ("11-20% of income", "over 20% yield losses") as results.
- **Every result row is flagged for review.** Almost every metric is new to
  the workbook's 27-item list, so `new_metric` fires on each row.

Before trusting any method on new reports: review the labels in
`benchmarks/review.json` against the PDFs, score with `evaluate`, and test on
reports that were not used for tuning.

## Running it

From the repository root, with the shared environment:

```powershell
$py = "rag-pipeline/.venv/Scripts/python.exe"
& $py -m pip install -r rag-pipeline/extract_experiments/requirements.txt
& $py rag-pipeline/extract_experiments/run.py run --dry-run      # free preview
& $py rag-pipeline/extract_experiments/run.py run --execute --run-id pilot02 --xlsx   # paid
& $py rag-pipeline/extract_experiments/run.py report --run-id pilot02 --xlsx         # free
```

Only `run --execute` makes paid calls. The preview lists jobs, inputs, parse
gaps and the estimated cost; it exits with code 2 and blocks a live run if an
input is missing, partial or too large. Live runs read `OPENAI_API_KEY` from
the environment or the repository `.env` and never save it.

Useful options: `--documents P001`, `--methods hybrid`, `--groups finance`,
`--repeats 3`, `--max-cost-usd 10`. `--resume` with the same options skips
finished jobs; any change to inputs, code or settings needs a new run ID.
`prepare` saves the normalized documents and plan under `results/prepared/`.

Settings live in [config.json](config.json): model
`gpt-5.4-mini-2026-03-17` with low reasoning, low PDF detail,
`text-embedding-3-small` at 1,536 dimensions, and a $3 scheduling limit.
That limit is an estimate, not a billing cap.

## Inputs

[inputs/manifest.json](inputs/manifest.json) lists each report's PDF
(`rag-pipeline/raw/`), its parsed `sections.json`
(`rag-pipeline/parsed/parsed/<paper>/`), its document family (`wb_icr` or
`agency_evaluation`) and an optional focus project. Paths are relative to the
manifest. Pages are 1-based physical PDF pages, counting the cover.

[common/inputs.py](common/inputs.py) is the only reader of parser output. It
keeps text, tables, footnotes and figure captions with their pages, and
rejects unknown block types and partial parses. Hybrid passages are cut from
the same blocks that full parsed sends, so the two text methods differ only
in retrieval. Parse gaps (empty tables, figures without text, pages with no
text) show in the preview and the report. P007's scanned annexes are one such
gap.

## Outputs

Each run writes to `results/<run-id>/`:

| Path | Contents |
|---|---|
| `t01/<method>/<report>/<task>/` | Evidence packet, request, raw reply and checked result for one job |
| `exports/session1`, `results`, `facts` | Raw facts in R Session-1 column names, CSV and JSON |
| `exports/template_results`, `projects` | One row per result claim, in the workbook's 25 columns plus method and trial |
| `exports/extraction_results.xlsx` | The workbook, filled from the template exports (with `--xlsx`) |
| `reports/comparison.html` | Side-by-side answers, parse gaps and cost |
| `reports/review.html` | The same answers with method names hidden, for blind review |
| `ledger.json` | Every API call with its reserved and actual cost |

In the template exports, `verified` means the stated value appears on the
reported PDF page. The reported page is the cited page, or the single page
where the fact's own quote and value were found; a moved page is noted in
`review_details`. It does not check the indicator, unit or attribution.
Metrics with no exact match in the workbook list become `CANDIDATE: ...`.
Qualified values such as `>1000` keep their text and leave the number blank.

Regenerating exports overwrites the workbook. Save a reviewed copy under
another name first.

## Evaluation

```powershell
& $py rag-pipeline/extract_experiments/run.py evaluate --init-review
& $py rag-pipeline/extract_experiments/run.py evaluate --run-id pilot02
```

`--init-review` seeds `benchmarks/review.json` from `test_set/` as
unreviewed labels and never overwrites it. Only labels marked reviewed are
scored. [benchmarks/README.md](benchmarks/README.md) explains how to review
them. Saved raw R replies can join the same scoring with `import-r`; see
[DECISIONS.md](DECISIONS.md#comparing-with-r).

## Tests

```powershell
& $py -m unittest discover -s rag-pipeline/extract_experiments/tests
& $py -m ruff check rag-pipeline/extract_experiments
```

Seven offline tests use tiny generated PDFs, fake replies and blocked network
access. They protect the job matrix and resume, parser inputs, exports, page
checks, shared scoring and the budget stop. They say nothing about accuracy.
