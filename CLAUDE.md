# Working in 07_Pipeline

This repo is the code of the CGIAR WP2 grey-literature workstream (retrieve,
dedup, screen, catalogue, extract, harmonise, review, score, publish). It
holds code and run-time reference data only. Read `../00_Knowledge/README.md`
first: that folder is the shared memory of the workstream and explains the
what and why; `05_folder_architecture.md` there is the script-by-script map,
`04_data_sources.md` the status of each source, `01_current_state.md` the
live numbers. Nothing in this file should repeat them.

## Rules this pipeline lives by
- Deterministic first, model second. If a regex, a table read or a lookup
  can decide, do not spend a model call; when a model is needed, batch and
  cache (vocab_decisions.csv is never re-asked for the same text and options).
- Everything a model extracts carries a page number and is string-matched
  back to that page. A value that fails the match is dropped, not kept.
- Results tables are read as tables (rf_table.R): figures define columns,
  header words name roles. Never choose by x-coordinate or value rules.
- One document, one record. A source is not a family: route by
  00_shared/doc_families.R, not by folder, and add a family there, nowhere else.
- The gold set P001-P010 may be tuned against; the holdout H001-H010 is
  never looked at while tuning.
- Extraction never writes into `../03_Documents`; only the catalogue step
  moves or files documents.
- Every script derives the repo root from its own `--file=` path two levels
  up, so scripts stay two levels below the repo root.
- Team documents: plain language, short sentences, no em dashes. Never
  overwrite a deck or document the user has edited; add to it.

## The knowledge folder is part of the deliverable
Keep `../00_Knowledge/` current in the same change: a new script, output,
moved score, enforced rule, decision or open question each has a home there
(the trigger table in its README says which file). `01_current_state.md` is
the only file with live numbers; move the `Last verified` date on anything
you touch.

## Gotchas
- OneDrive paths exceed 260 characters: copy to a short temp path with the
  `\\?\` prefix before opening (screen_scope.R `read_all`, doc_census.R
  `short_path`); in Python, cd into the folder and open by basename.
- Rscript on this machine: `C:\Program Files\R\R-4.4.2\bin\Rscript.exe`.
  Excel locks: write a dated copy if the target is open, regenerate later.
- pdftools orders cover text differently from PyMuPDF; detector regexes must
  not assume the running header comes first.
- The tool layer eats backslashes in shell heredocs: use the Write tool or
  `chr(92)` for anything with a backslash.

## Git
- Conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`
- Commit only when asked; branch before committing on main.
- Remote: https://github.com/Mlolita26/Adaptation-Insights (public; the
  README is written for people outside the team, keep it that way)

## Scrapers (R/01_retrieve)
Header block (source, URL, strategy, document types, quirks); all HTTP via
`polite_get()` with `HTTP_CONFIG` delays; `tryCatch` everything and keep
going; validate PDFs (`%PDF-` magic bytes, size above
`HTTP_CONFIG$min_pdf_bytes`); metadata columns at minimum `id`, `title`,
`pdf_url`, `doc_date`, `doc_type`, `country`, `project_id`, `web_url`.
New source: follow `.claude/skills/new-scraper`.
