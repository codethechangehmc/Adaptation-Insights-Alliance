# Adaptation Insights Python pipeline

Retrieval for a living evidence base on implemented agricultural climate
adaptation in Africa. Scrapers preserve evaluation documents, metadata,
retrieval decisions and download history. Retrieval relevance is separate
from final eligibility, which requires screening the full text.

## Run retrieval

Python 3.10 or later, from the repository root:

```powershell
python -m pip install -r rag-pipeline/scraper/requirements.txt
python rag-pipeline/scraper/run.py worldbank
python rag-pipeline/scraper/run_all.py --metadata-only
```

Sources are World Bank, Adaptation Fund, African Development Bank, Climate
Investment Funds, Green Climate Fund, Global Environment Facility and IFAD.
World Bank project details and GEF document dates have separate helper commands.
See the [scraper guide](scraper/README.md) for setup, commands, output files
and current source status.

## Persistent storage

Code and settings are grouped under `scraper/sources/`, `scraper/helpers/`,
`scraper/core/` and `scraper/config/`. Use `scraper/run.py` for individual
commands and `scraper/run_all.py` for batch runs; tests and fixtures are in
`scraper/tests/`.

`scraper/run.py` lists every command. The shared runner coordinates the
workflow; searching, classification, matching, HTTP, downloads and storage
have separate modules.
Shared behavior tests live in `scraper/tests/core/`; source tests remain
in `scraper/tests/test_<source>.py`, alongside helper and launcher tests.

Each source has its own `downloads/<source>/` PDF folder and
`outputs/<source>/` state database, catalogue and run logs. Keep these folders
across periodic runs. Combined datasets identify records by `(source, id)`.
Generated data is git-ignored; test and audit runs belong under
`rag-pipeline/data/<source>_review/`.

Loose local validation material is grouped in `data/validation/scripts/`,
`data/validation/reports/` and `data/validation/handoffs/`. These are ignored
working files; source review folders retain their original evidence and state.

An incomplete search does not replace the previous catalogue. Downloads are
checked and reused, failures are recorded for the next run, and `--refresh`
preserves older PDF versions when content changes. No model calls are used.

## Later stages

Deduplication, final screening, Zotero synchronization and extraction are
separate future work. The empty parsing placeholder and its unused dependency
list were removed. Retrieval dependencies live in `scraper/requirements.txt`.

Extraction will use the team's schema and manually labelled examples, preserve
document and page provenance, and route by document family. Accuracy will be
measured by field with holdouts reserved from tuning.

## Development

From `rag-pipeline/scraper/`, run `python -m unittest discover -s tests -t .`.
From `rag-pipeline/`, run `ruff check .` and `ruff format --check .`.

## Retrieval review

The [review report](audit/REVIEW.md) records the comparison with the existing
workflow, source coverage, downloaded-file checks and unresolved upstream files.
Audit utilities live outside the runtime scraper. Export a normalized inclusion
list, import it once, then reuse the same state to retain a reference corpus:

```powershell
python rag-pipeline/audit/compare_with_r.py worldbank `
  --export-inclusions rag-pipeline/data/worldbank_review/inclusions.csv
python rag-pipeline/scraper/run.py worldbank --download-only `
  --include-listing rag-pipeline/data/worldbank_review/inclusions.csv `
  --output-dir rag-pipeline/data/worldbank_review/outputs `
  --download-dir rag-pipeline/data/worldbank_review/downloads
python rag-pipeline/audit/compare_with_r.py worldbank `
  --download-dir rag-pipeline/data/worldbank_review/downloads --require-superset
```

The final command exits 1 if a reference is missing from the retained catalogue
or its checked local file is unavailable. Metadata inclusion and successful
downloads are separate checks. `--state` selects a different state database;
`--run` audits one run instead. `--adopt-local` copies locally verified files
identified by successful download logs or native filenames; originals remain
in place. Subsequent retrieval adopts those copies into its state.
