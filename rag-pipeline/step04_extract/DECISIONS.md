# Extraction decisions (steps 04 and 05)

The choices behind extraction and evaluation. They started with the P001, P009 and P007
pilot of 2026-11-05 (record: `experiments/extract_comparison/`); changes since then are
marked *(Nov 2026)*. The exact prompts are in [tasks.py](tasks.py), the queries in
[retrieval.py](retrieval.py), and every `request.json` keeps the full request that was sent.

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
   failures and partial achievement, and every quantitative indicator in the results
   framework, activity counts included (their kind goes in `indicator_level`).
   *(Nov 2026)* Context figures and yes/no milestones are kept, labelled
   `value_type = context` / `milestone`, instead of excluded, so the Alliance can decide
   whether it wants them. Never results: baselines or targets on their own, money,
   dates, ratings and sample sizes.
   Each result also carries its printed value, baseline, target, year,
   location, beneficiary and intervention when the report states them. These
   rules define what gets extracted and should be agreed with the team before
   use beyond the pilot.
9. **Strict output, explicit failure.** Replies must match the JSON schema. A
   refusal, invalid JSON or cut-off reply fails the job; it never becomes an
   empty answer. Results get 24,576 output tokens, other tasks 4,096.

## Evidence preparation

10. **One input reader.** [inputs.py](inputs.py) reads
    `sections.json`, `meta.json` and *(Nov 2026)* step 03's `chunks.jsonl`, keeps typed blocks with their pages, and
    rejects partial parses and unknown block types. Empty tables and figures
    stay as page markers, not as searchable text. No method sends figure
    images or runs OCR.
11. **Hybrid searches step 03's chunks** *(Nov 2026)*. The pilot split the parsed blocks
    with its own simpler splitter; now there is one chunker for the pipeline. Its chunks
    follow headings, drop the table of contents and running headers, attach footnotes,
    split long tables by rows with the header repeated, and mark `(PDF page N)` where a
    table crosses a page break. full_parsed still reads every parsed block.
12. **Search within one report.** Fixed queries per task, never built from
    answers or labels. BM25 uses k1 1.5, b 0.75 and positive IDF on Unicode
    words. Embeddings use cosine similarity and are cached by text, model and
    dimensions, in one `.npz` file per report *(Nov 2026)*, saved after every batch. Each query takes its top 20 from each channel; reciprocal rank
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
    PDF text with line-end hyphens is also checked joined. *(Nov 2026)* The model's own
    pages stay in `page_cited` and a move sets `page_repaired`, so page mistakes are
    counted per method instead of quietly fixed. A value without digits (Yes, No) also
    needs its quote on the page, since the word alone is on almost any page.
17. **Conservative vocabulary.** Exact matches and a short alias list map
    metrics, units and beneficiaries to the workbook lists. No fuzzy matching
    and no extra model call. Unmatched metrics become `CANDIDATE: ...`.
18. **Duplicates and conflicts stay visible.** Only identical claims merge,
    keeping all their quotes. Different values for the same indicator, scope,
    location and year are flagged, never averaged or resolved.
19. **Flags are not review.** `needs_review = FALSE` means no automatic check
    fired, not that a person checked the row. *(Nov 2026)* Only possible problems set
    it (value not on the page, quote not in the PDF, suspect table, a target or money
    reported as a result, conflicting values). To-dos that don't make a row wrong (a new
    metric or unit, a qualified value, a repaired page) are `note:` items in
    `review_details`. The `section` label comes from step 03's chunk tags for every method.
20. **Portable workbook writer.** openpyxl fills a copy of the template and
    re-reads every cell to confirm it saved. Long narrative columns start
    collapsed.

## Cost and reproducibility

21. **Paid calls are explicit.** Only `--execute` calls the API. The
    budget check reserves estimated input plus maximum output before each
    call. A network error or unreadable reply keeps its reservation and stops
    the run without resending. HTTP 429 and 5xx are retried at most twice.
22. **Runs are frozen.** `run.json` stores hashes of the inputs, settings,
    code and template. Resume refuses any change except the budget. Saved
    requests, replies, packets and the cost ledger allow a full audit.

## Comparing with R (parked, Nov 2026)

The pilot could score saved raw replies from Lolita's R pipeline with the same scorer
(`import-r`). No raw R replies exist yet, so that path never ran; it is parked with its
notes in `experiments/extract_comparison/`. The exports no longer use R's Session-1 layout:
`results.csv` and `projects.csv` use our template columns, and each report gets a raw `facts.csv`.
If the comparison comes back, remember that a historical R run differs in model, prompts,
input preparation and date, and that R's published percentage counts empty-empty agreement.
