# Scrapers

These scrapers collect evaluation reports on agricultural climate adaptation
in Africa from seven funders' websites. Each run searches the sites, keeps the
documents that may be in scope, downloads them and records every decision.
Runs can be repeated: each one picks up new documents and skips files already
downloaded.

Decisions use fixed rules only: keywords, countries, dates and document types.
No AI model is used at this stage. A kept document is a candidate for
screening, not a confirmed eligible study.

The scraper is independent of the parsing and chunking tools beside this
folder. Its dependencies, environment, lint configuration, tests and reference
audits all live here. Install its requirements into its own environment;
the parent `rag-pipeline/requirements.txt` belongs to the other tools.

## Sources

| Command | Funder | Where documents come from | Status on 2026-10-22 |
|---|---|---|---|
| `worldbank` | World Bank | Documents and Reports API | Working |
| `af` | Adaptation Fund | Climate Policy Radar | Working |
| `afdb` | African Development Bank | Website listings, including IDEV evaluations | Working. Downloads are slow: the site asks for 10 seconds between requests |
| `cif` | Climate Investment Funds | Website document index | Working |
| `gcf` | Green Climate Fund | Website and Climate Policy Radar | Incomplete: one Climate Policy Radar entry no longer exists (HTTP 410) |
| `gef` | Global Environment Facility | Website listings | Blocked: the site refuses access (HTTP 403). Earlier records are kept |
| `ifad` | IFAD | IATI open data (D-Portal) | Records found, but file downloads fail: IFAD's file server cannot open a secure connection |

Two helper commands add detail after a run:

- `worldbank_projects` adds sector, instrument and dates for World Bank projects.
- `gef_doc_dates` reads report dates from downloaded GEF files.

## Setup

Python 3.10 or later. From the repository root:

```powershell
python -m venv rag-pipeline/scraper/.venv
.\rag-pipeline\scraper\.venv\Scripts\Activate.ps1
python -m pip install -r rag-pipeline/scraper/requirements.txt
```

## Running

```powershell
# One source
python rag-pipeline/scraper/run.py worldbank

# A small trial: search everything, download at most 5 files
python rag-pipeline/scraper/run.py af --max-downloads 5

# All sources at the same time
python rag-pipeline/scraper/run_all.py

# All sources, search only
python rag-pipeline/scraper/run_all.py --metadata-only
```

Main options:

| Option | What it does |
|---|---|
| `--metadata-only` | Search and decide, but download nothing |
| `--download-only` | Skip the search; retry downloads for documents already found |
| `--max-downloads N` | Download at most N new files |
| `--start-date`, `--end-date` | Date window, `YYYY-MM-DD`. Default: 2015-01-01 to today |
| `--refresh` | Download again; a changed file's old copy is kept |

Add `--help` after any command to see all its options.

A run ends with exit code 0 when complete, 1 when a search was incomplete or
an error occurred, and 130 when interrupted. Failed downloads do not fail a
run; they are retried next time.

## What you get

| Location | Contents |
|---|---|
| `downloads/<source>/` | The downloaded reports |
| `outputs/<source>/<source>_metadata.csv` | The catalogue: one row per kept document, with title, link, date, country, project, decision and download result |
| `outputs/<source>/state.sqlite3` | Every document ever seen, including dropped ones. Back it up with the downloads |
| `outputs/<source>/runs/` | A summary and logs for each run |

These paths are relative to the repository root, regardless of the working
folder. They preserve existing scraper state and downloads. Use `--output-dir`
and `--download-dir` to select other locations; for batch runs each option is
a base folder with a separate subfolder per source. Scrapers do not invoke
the parsing or chunking tools.

## How documents are judged

Each document gets one of three decisions:

- `in_scope`: clear agriculture or adaptation evidence. Downloaded.
- `to_screen`: possibly relevant, needs a closer look. Downloaded.
- `drop`: recorded with a reason, not downloaded.

A document is dropped when it is outside the date window, not in English, has
no African country, is a proposal rather than an evaluation, is budget support,
or shows no agriculture or adaptation evidence. Documents with no date are kept
for screening. When one document of a project is kept, documents of the same
project that were held back for weak evidence are kept too.

The keyword and country lists are in `config/africa.json`.

## Safeguards

- **Complete or nothing.** If a site returns fewer results than it reports,
  the run stops and the previous catalogue stays as it was.
- **Polite.** Half a second between requests to one site. The World Bank,
  Climate Policy Radar and GEF file servers are built for automated traffic
  and get a tenth of a second. A site's own robots.txt delay always wins:
  AfDB asks for 10 seconds. Each site's robots.txt rules are followed. If a site blocks access, the scraper stops; it never works
  around a block.
- **Nothing lost.** Records are never deleted. Each download is checked to
  be a real report, not an error page.
- **Change alerts.** A warning is logged when a site suddenly returns far
  fewer results than the last run.

## More detail

[DEVELOPING.md](DEVELOPING.md) describes the code, options and offline tests.
[IMPROVEMENTS.md](IMPROVEMENTS.md) explains what changed from the R scrapers.
[audit/REVIEW.md](audit/REVIEW.md) records reference coverage and live-access limits.

## Reference audits

The audit reads saved R catalogues without changing them. Review files default
to the ignored `rag-pipeline/scraper/data/<source>_review/` folder. Export a
normalized inclusion list, then import it into a review run:

```powershell
python rag-pipeline/scraper/audit/compare_with_r.py worldbank `
  --export-inclusions rag-pipeline/scraper/data/worldbank_review/inclusions.csv
python rag-pipeline/scraper/run.py worldbank --download-only `
  --include-listing rag-pipeline/scraper/data/worldbank_review/inclusions.csv `
  --output-dir rag-pipeline/scraper/data/worldbank_review/outputs `
  --download-dir rag-pipeline/scraper/data/worldbank_review/downloads
python rag-pipeline/scraper/audit/compare_with_r.py worldbank `
  --download-dir rag-pipeline/scraper/data/worldbank_review/downloads --require-superset
```

`--require-superset` fails if any reference record or checked local file is
missing. Metadata retention does not establish successful downloads or final
eligibility. Existing review states elsewhere can still be selected with
`--state`, `--run` and `--download-dir`; this reorganization moves no data.
