# Step 04: extract

Asks the model to extract project facts from each report, with a choice of **what the model reads**.
The point is to compare the methods (step 05 scores them), so they share everything else: the same
model, prompts, output format and checks.

| Method | What the model reads |
|---|---|
| `full_pdf` | the original PDF, uploaded as a file |
| `full_parsed` | every block of step 02's parsed output, in reading order, with PDF page markers |
| `hybrid` | about 12,000 tokens of step 03's chunks, picked by BM25 (keywords) + embeddings (meaning) |

Each report gets five separate tasks: identity, geography, rationale, results, finance.

| | |
|---|---|
| Reads | `data/01_raw/<paper>.pdf`, `data/02_parsed/<paper>/sections.json`, `data/03_chunks/<paper>/chunks.jsonl` |
| Writes | `data/04_extracted/<run-id>/` |
| Which reports | `config/manifest.json`: project code, paper id, family (`wb_icr` or `agency_evaluation`) |
| Settings | `config/config.json`: model, reasoning effort, budget, search settings, prices (checked 2026-11-17) |

## Run

```powershell
python -m step04_extract.extract                                         # free preview: jobs, inputs, cost estimate
python -m step04_extract.extract --execute --run-id pilot03              # paid: every method, every report
python -m step04_extract.extract --methods hybrid --documents P001 --groups results --execute --run-id test01
python -m step04_extract.extract --execute --run-id pilot03 --resume     # finish an interrupted run
python -m step04_extract.extract --run-id pilot03 --export-only --xlsx   # rebuild the tables; no API calls
```

**Only `--execute` spends money.** The API key comes from the `OPENAI_API_KEY` environment variable,
or from `rag-pipeline/.env` (one line `OPENAI_API_KEY=sk-...`; `.env` is gitignored).

## Outputs

```
data/04_extracted/<run-id>/
  run.json             frozen settings, input fingerprints and code fingerprints (a changed input = a new run)
  prepared/<id>.json   the inputs as the model sees them, plus parse-gap diagnostics
  t01/<method>/<id>/<task>/
      packet.json      the evidence sent (hybrid: the chosen chunks and the search rankings)
      request.json     exactly what was sent
      response.json    the raw reply
      result.json      the checked answer
  ledger.json          every API call: tokens, cost, status
  exports/
    results.csv        checked results, every report and method
    projects.csv       project fields (title, years, budget, funders...), every report and method
    <paper_id>/
      facts.csv        everything the model said for this report, all 5 tasks, unchecked
      results.csv      this report's checked results
      projects.csv     this report's project fields
    results.xlsx       the results template filled in (only with --xlsx)
data/04_extracted/cache/embeddings/<id>.npz   embeddings, one file per report, reused by every run
```

### Columns of results.csv that need explaining

| Column | Meaning |
|---|---|
| `value_stated` / `value` | the value exactly as printed / as a plain number (blank for `>1000`, `about 40%`, `Yes`) |
| `value_type` | `achieved` (a result), `context` (a figure describing the situation, not a change the project caused), `milestone` (yes/no) |
| `result_level` | input / process / output / outcome / impact, from the report's own results framework |
| `page` | the PDF page (counting the cover as 1) where the value really is |
| `page_cited` | the page(s) the model cited |
| `page_repaired` | TRUE if the value was on none of the cited pages and was found, with its quote, on exactly one other page |
| `verified` | the value is printed on `page` (for values without digits, its quote must be there too) |
| `needs_review` | an automatic check found a possible problem; `review_reason` and `review_details` say which |
| `review_details` | the problems, then `note:` items that are to-dos, not errors (new metric, repaired page...) |
| `chunk_id`, `section` | hybrid: the chunk the value came from; every method: body / annex / references, from step 03 |

`needs_review = FALSE` means no check fired, not that a person checked the row.

## What happens in a run

1. `inputs.py` reads each report's PDF, sections and chunks (`load_manifest`, `prepare_document`).
2. `runner.py` plans the jobs (report x method x task) and prints the preview.
3. For each job, the evidence is prepared: the PDF upload, all parsed blocks, or `retrieval.py`'s search.
4. `tasks.py` builds the prompt; `api.py` sends it, checks the budget and records the cost.
5. `rules.py` flags each fact (e.g. a target reported as a result) without changing it.
6. `exports.py` and `template.py` write the tables: page check and repair, vocabulary mapping, duplicates
   merged, conflicts and problems flagged. `workbook.py` fills the Excel template.

Design choices and their reasons: [DECISIONS.md](DECISIONS.md). Tests: `python -m unittest discover -s tests`.

## Known limits

- The model cites printed page numbers in `full_pdf` and page ranges in split tables; `page_repaired` shows how often.
- No method sends figure images or runs OCR, so scanned pages and charts without text can't be extracted.
- The metric vocabulary has 27 terms, so most metrics come out as `CANDIDATE: ...` until the list grows.
