# Extraction experiment decisions

The choices that shape the P001, P009 and P007 pilot. The exact prompts are in
[common/tasks.py](common/tasks.py), the queries in
[hybrid/retrieval.py](hybrid/retrieval.py), and every `request.json` keeps the
full request that was sent.

## What is compared

1. **Same task, different evidence.** All methods share the model, system
   prompt, task prompts, family notes, JSON schema, reasoning effort and
   output limits. Only the evidence differs. Hybrid against full parsed tests
   retrieval with the parser held fixed. Full PDF against full parsed also
   changes text extraction and adds page images, so it cannot isolate the
   effect of images.
2. **Five independent tasks.** Identity, geography, rationale, results and
   finance each start a fresh request. An identity mistake cannot leak into
   the finance answer. This repeats input tokens on purpose.
3. **One trial by default.** It keeps cost low. It does not measure run to run
   variation; use `--repeats` for that.
4. **Method order rotates by report**, so no method always pays the cold
   cache. Timing is still only indicative.

## Model and prompts

5. **Pinned model.** `gpt-5.4-mini-2026-03-17` with low reasoning effort, so
   the alias cannot drift under a run. No seed or temperature is set, so runs
   are not deterministic.
6. **Literal extraction.** The document is data, not instructions. Answers
   use only the supplied evidence, keep the source wording, cite short exact
   quotes with physical PDF pages, keep contradictions, and leave a field
   empty when evidence is missing. Empty means "not found in the input", not
   "absent from the report".
7. **Document family is configuration.** World Bank ICRs get notes on the data
   sheet, effectiveness and closing dates, the results framework and the
   financing table. Agency evaluations get notes separating the project from
   the evaluation's own fieldwork. The manifest sets the family.
8. **What counts as a result.** Actual quantitative results, including zeros,
   failures and partial achievement. Not baselines or targets on their own,
   money, context statistics, dates, ratings, sample sizes or process counts.
   Each result also carries its printed value, baseline, target, year,
   location, beneficiary and intervention when the report states them. These
   rules define what gets extracted and should be agreed with the team before
   use beyond the pilot.
9. **Strict output, explicit failure.** Replies must match the JSON schema. A
   refusal, invalid JSON or cut-off reply fails the job; it never becomes an
   empty answer. Results get 24,576 output tokens, other tasks 4,096.

## Evidence preparation

10. **One parser adapter.** [common/inputs.py](common/inputs.py) reads
    `sections.json` and `meta.json`, keeps typed blocks with their pages, and
    rejects partial parses and unknown block types. Empty tables and figures
    stay as page markers, not as searchable text. No method sends figure
    images or runs OCR.
11. **Hybrid passages come from the same blocks.** Text is split near 450
    tokens (600 at most), tables only between rows with the header repeated.
    No separate `chunks.jsonl`, catalogue titles or `chunk.py` filtering, so
    the comparison sees the same text.
12. **Search within one report.** Fixed queries per task, never built from
    answers or labels. BM25 uses k1 1.5, b 0.75 and positive IDF on Unicode
    words. Embeddings use cosine similarity and are cached by text, model and
    dimensions. Each query takes its top 20 from each channel; reciprocal rank
    fusion (constant 60) merges them.
13. **Fixed evidence budget.** Pack ranked passages, then same-section
    neighbours, up to 12,000 tokens, in reading order. Never cut a table row,
    never fall back to the full document.
14. **Full PDF.** Upload the unchanged file once, reuse its ID, low image
    detail. The API also extracts the PDF's text.

## Checks and exports

15. **Keep literal and numeric values apart.** `value_stated` keeps the
    printed text. The numeric column is filled only for a plain number; 45%
    becomes 45 with unit percentage. Bounds, ranges and approximations keep
    their text and a blank number. No unit conversion or rounding.
16. **Match pages by string.** `verified` means the stated value appears on
    the reported PDF page. The reported page is the cited one, or, when the
    value is not there, the one page where the fact's own quote and the value
    are both found. Full PDF answers cite printed page labels, so this repair
    mattered most there. If no single page fits, the row stays unverified.
    PDF text with line-end hyphens is also checked joined.
17. **Conservative vocabulary.** Exact matches and a short alias list map
    metrics, units and beneficiaries to the workbook lists. No fuzzy matching
    and no extra model call. Unmatched metrics become `CANDIDATE: ...`.
18. **Duplicates and conflicts stay visible.** Only identical claims merge,
    keeping all their quotes. Different values for the same indicator, scope,
    location and year are flagged, never averaged or resolved.
19. **Flags are not review.** `needs_review = FALSE` means no automatic check
    fired, not that a person checked the row.
20. **Portable workbook writer.** openpyxl fills a copy of the template and
    re-reads every cell to confirm it saved. Long narrative columns start
    collapsed.

## Cost and reproducibility

21. **Paid calls are explicit.** Only `run --execute` calls the API. The
    budget check reserves estimated input plus maximum output before each
    call. A network error or unreadable reply keeps its reservation and stops
    the run without resending. HTTP 429 and 5xx are retried at most twice.
22. **Runs are frozen.** `run.json` stores hashes of the inputs, settings,
    code and template. Resume refuses any change except the budget. Saved
    requests, replies, packets and the cost ledger allow a full audit.

## Comparing with R

The R reference is `R/05_extract/extract_verbatim.R` with its family modules
and `R/08_quality/score_pilot.R`. Nothing here runs or imports R.

- **What differs.** R uses `gpt-5-mini`, longer prompts, page-tagged
  `pdftools` text, family page selection and selected table images. Full PDF
  is not a port of R's preparation; it is a separate method.
- **Same columns.** Exports use R's Session-1 names (`metric_stated`,
  `unit_stated`, `budget_total` and so on) and keep every result, not just
  three. `result1` to `result3` are a secondary summary picked by a shared
  rule, not R's headline ranking. Raw document wording must not be compared
  with harmonised codes.
- **Same scorer.** `import-r` reads the original per-task R JSON replies
  (before catalogue prefill and result folding), checks the PDF bytes match,
  and scores them with the Python methods. A missing R quote stays missing.
  The folded `session1_*.csv` and `test_set/pipeline_general.csv` are not
  valid inputs. No suitable raw R replies are in the repository yet, so this
  path is tested offline only. Copy
  [inputs/r_baseline.example.json](inputs/r_baseline.example.json) to start.
- **Read results with care.** A historical R run differs in model, prompts,
  input preparation and date. It is a system baseline, not proof that one
  language is more accurate. Do not compare R's published percentage with
  these scores: R counts empty-empty agreement and scores fields differently.
