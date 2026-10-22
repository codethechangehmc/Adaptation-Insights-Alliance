# Scrapers

These scrapers find evaluation documents on funders' websites, decide which
ones may be in scope, download the reports and keep a record of everything they
saw. They run on a schedule, so each run picks up new documents and skips the
ones already on disk. Decisions are rules only: keywords, places, dates and
document types. No model is called.

Each source is one Python module under `sources/` on a shared
core (`core/`). Every source runs the same way and writes the same outputs.

## Folder layout

```text
scraper/
  run.py              run one source or helper; the command list and batch order
  run_all.py          run all sources in sequence
  config/             source scope JSON files and shared Africa reference data
  sources/            seven funder modules and shared CPR access
  helpers/            World Bank project details and GEF document dates
  core/               shared workflow and services (see the code map below)
  tests/
    core/             shared behavior tests and synthetic test helpers
    test_<source>.py  source and helper regressions
    fixtures/         small saved website responses
  requirements.txt    retrieval dependencies
```

Use the launchers below rather than executing files inside `sources/` or
`helpers/` directly. For existing scheduled commands, replace
`scraper/worldbank.py` with `scraper/run.py worldbank`, and likewise for other
sources and helpers. Options and persistent output locations are unchanged.

## Where to make a change

Start with `core/runner.py` to follow a run from search to catalogue export.
Then read the source's `plan_searches`, `run_search`, `classify` and `pdf_urls`
functions. The source owns website-specific behavior; the core coordinates
the same workflow for every source.

| Change | File or folder |
|---|---|
| Add a command or change batch order | `run.py` |
| Change shared command-line flags, summary fields, drift warnings or logging | `core/runner.py` |
| Adjust a source's queries, parsing, pagination or rules | `sources/<source>.py` |
| Adjust source settings or keyword/place reference data | `config/` |
| Change shared date/language gates, project sibling decisions or inclusion lists | `core/classification.py` |
| Change keyword, language, country or date parsing | `core/matching.py` |
| Schedule searches and check their completeness | `core/searching.py` |
| Change HTTP retries, rate limits or robots handling | `core/fetch.py` |
| Retry downloads, resolve links or reuse a local copy | `core/downloads.py` |
| Change SQLite state, CSV/JSON exports, file checks, file names, old versions or locking | `core/storage.py` |
| Enrich World Bank projects or recover GEF document dates | `helpers/` |
| Compare against saved R references | `../audit/` |

Keep source behavior in its source module, including dated notes about site
quirks. `sources/cpr.py` provides the shared Climate Policy Radar channel for
AF and GCF. Core modules do not import source modules; the runner receives the
selected source from `run.py`. Runtime code never imports the audit utilities.

## Setup

Python 3.10 or later, from the repository root:

```powershell
python -m pip install -r rag-pipeline/scraper/requirements.txt
```

For an isolated Windows environment, create and activate it before installing:

```powershell
python -m venv rag-pipeline/.venv
.\rag-pipeline\.venv\Scripts\Activate.ps1
python -m pip install -r rag-pipeline/scraper/requirements.txt
python -m pip install ruff
```

If `.venv` already exists, use its interpreter or activate it. This avoids
accidentally running tests with a different Python installation.

## Run

One source:

```powershell
python rag-pipeline/scraper/run.py worldbank
```

Every source, one after another, with one status line each at the end:

```powershell
python rag-pipeline/scraper/run_all.py
python rag-pipeline/scraper/run_all.py --sources worldbank gef --metadata-only
```

For `run_all.py`, `--output-dir` and `--download-dir` are **base folders**;
each source gets its own subfolder. World Bank project details share the
`worldbank` output folder. Individual source commands use the exact paths passed.

Scripts find the repository from their own location, so a scheduled task can
call them by full path from any folder.

Options shared by every source (`--help` lists them, plus the source's own):

| Option | What it does |
|---|---|
| `--metadata-only` | Search and classify, but download nothing. |
| `--download-only` | Reclassify stored records and retry their downloads without searching. The summary labels this mode. |
| `--include-listing CSV` | Retain every document in a normalized reference CSV. Repeat for several CSVs. Inclusions persist in state. |
| `--max-downloads N` | Download at most N new PDFs. `--max-downloads 5` is the usual size check. |
| `--refresh` | Download again even when a checked copy is on disk. A changed file's old copy goes to `versions/`. |
| `--start-date`, `--end-date` | Document date window, `YYYY-MM-DD`. Default: 2015-01-01 to today. |
| `--output-dir`, `--download-dir` | Where state, outputs and PDFs go. Default: `outputs/<source>/` and `downloads/<source>/`. |
| `--workers N` | Searches or downloads in parallel. Default: 4. |
| `--request-interval S` | Seconds between two requests to one website. Default: 1.0. |

Test and audit runs go under `rag-pipeline/data/<source>_review/`, for example:

```powershell
python rag-pipeline/scraper/run.py worldbank --countries Kenya --metadata-only `
  --output-dir rag-pipeline/data/worldbank_review/outputs `
  --download-dir rag-pipeline/data/worldbank_review/downloads
```

## What a run does

1. Locks the output folder, so two runs cannot overlap.
2. Runs every search, four at a time.
3. Stops if any search is incomplete. The catalogue, state and PDFs stay as
   they were, and the exit code is 1.
4. Merges records found by several searches (by `id`) and classifies each one.
5. Gives documents of one project the strongest decision among them (see
   "Statuses and reasons").
6. Saves every record to the state database, including drops.
7. Logs the kept count and the estimated download size.
8. Downloads every stored kept record, including records absent from this search.
   Each result is saved as soon as it finishes, so
   an interrupted run loses nothing.
9. Writes the catalogue and the run folder.
10. Compares with the previous complete run and logs drift warnings.
11. Exits 0, even if some downloads failed. They are listed in the summary and
    tried again on the next run.

**Complete searches.** A search is complete only when it retrieved as many
items as the website reported, or reached the verified last page when no total
is provided. Project/family listings and document records are different units:
sources check the listing total before expanding documents, and record those
counts in `searches.csv` notes. Many websites cap what one query can return,
for example a maximum offset. Each source records its site's cap and splits a
query that reaches it into smaller queries (by date, then by country or
document type). The pieces must add up to the original total with no repeated
IDs. Nothing is ever cut off silently.

**Politeness.** One request per second per website, shared by all workers;
retries with growing pauses that honour `Retry-After`; `robots.txt` rules and
`Crawl-delay` respected, including redirected file URLs. An explicit access
block stops further requests to that host for this run. An unreachable robots
file stops the host too; missing robots files and pages without directives
impose no additional rules.

## Outputs

```text
downloads/<source>/                     PDFs: <source>_<id>_<project>_<year>.pdf
outputs/<source>/
  state.sqlite3                         every record ever seen, its decision and download
  <source>_metadata.csv                 the kept records, for people and later stages
  versions/                             old copies of PDFs replaced by --refresh
  runs/<run_id>/
    summary.json                        options, counts, timings, status, size estimate,
                                        drift warnings, failed IDs
    searches.csv                        one row per search: query, expected, retrieved, error
    decisions.csv                       every record seen this run, with status and reason
    downloads.csv                       one row per download: status, reason, file, checksum
    run.log                             readable log: progress, retries, errors
```

Incomplete searches also save `partial_records.csv` in their run folder for
diagnosis. These records do not replace state or the published catalogue.
Summary `mode` distinguishes live searches from stored-record download runs.

- **`state.sqlite3`** is the source of truth. It holds one row per document:
  the record, its last download result, and when it was first and last seen.
  Records are never deleted because a later search did not return them. Back
  it up with the PDFs. If it is lost, the next run rebuilds it from a fresh
  search and adopts the PDFs already on disk; only the `first_seen` history is
  lost.
- **`<source>_metadata.csv`** is rewritten each run from the state database:
  every kept record ever seen. Never edit it to change state; it is an export.
- **Run folders** can be deleted at any time. Run IDs are UTC timestamps with a
  short random suffix, so they sort by time.
- `downloads/`, `outputs/` and `rag-pipeline/data/` are not tracked by git.

Catalogue columns, the same for every source: `source, id, title, pdf_url,
doc_date, doc_type, country, language, project_id, web_url, screen_status,
filter_reason, matched_keywords, search_ids, first_seen, last_seen, filename,
download_status, sha256, bytes`. A source may add its own columns after these.
Records from different sources are told apart by `(source, id)`.

`download_status` values: `downloaded`, `skipped_valid` (the file on disk
matches the stored checksum), `adopted_local` (a good file on disk that state
did not know), `failed`, `no_pdf_url`, and `pending` (not tried yet). A PDF
passes the check when it is at least 10 KB, starts with `%PDF-` and has
`%%EOF` near the end. This catches error pages and cut downloads, not every
broken PDF.

Word, Excel, RTF, ZIP/7z and TIFF reports retain their file extensions.
Container and signature checks prevent error pages from being saved as reports;
valid small OOXML files use ZIP integrity rather than the PDF size threshold.
OOXML files served with a misleading `.doc` suffix are saved as `.docx`.
An explicitly linked HTML document keeps its own extension. These checks
establish plausible file format, not final eligibility or complete readability.

For an individual source command, `--include-listing` accepts CSV rows with
`id`, `title` and available standard catalogue fields. A filled `source` must
match the command. `reference_ids` and `reference_urls` preserve provenance
and fallback links as JSON arrays. An inclusion that the rules would drop
stays `to_screen` with `reference_recall`; `rule_status` and `rule_reason`
expose the rule decision. This preserves reference recall without declaring
the document eligible. Reference retention never promotes siblings. Current
source dates, geography and language remain authoritative, including unknown
values. Use inclusion lists with individual source commands.

## Statuses and reasons

Three statuses: `in_scope` and `to_screen` are both downloaded; `drop` is
recorded but not downloaded. Every record has a short reason code.

| Reason | Meaning |
|---|---|
| `outside_date_range` | Document date outside the window. Without a document date, the project's closing date is used. |
| `unknown_document_date` | No date at all. Kept as `to_screen`. |
| `not_english` | The language field, or the title words when the field is empty, say it is not English. |
| `no_african_country` | No African country or region in the record. |
| `policy_or_budget_support` | Development policy lending or budget support (World Bank). |
| `proposal_stage` | A proposal, appraisal or project document, not an evaluation. |
| `insufficient_metadata` | No abstract, no topics and no title match: nothing to decide on. |
| `no_agriculture_or_adaptation_evidence` | Metadata present, but no keyword or topic evidence. |
| `project_sibling_evidence` | Lifted because another document of the same project was kept. |
| `reference_recall` | Explicitly retained for screening despite a negative rule decision. |

Sources add their own positive reasons (for example
`agriculture_topic_or_headline_keywords`). Keywords are matched as whole
words, in English only, and accept regular plurals (`farmer`, `farmers`). The
lists are in `config/africa.json`.

**One decision per project.** Documents that share a `project_id` get the
strongest decision among them. Only records held back for weak evidence
(`no_agriculture_or_adaptation_evidence`, `insufficient_metadata`,
`abstract_keywords_only`) are lifted; a rule such as date, language, country
or proposal stage is never overridden. The sibling's ID is added to
`matched_keywords` as `sibling:<id>`.

## Periodic runs

Use the same output and download folders every time. Every run searches the
full date window again, so documents that were indexed late are still found.
Exit codes: 0 complete, 1 incomplete search or error, 130 interrupted.

**Drift warnings** (in the log and `summary.json`) say a website may have
changed: a search that returned records last time now returns none, or unique
records fell by more than 20 percent. They never fail the run.

On Windows Task Scheduler, set the program to the full path of `python.exe`
and pass the full path of `scraper/run.py`, the command name and its options.

## Tests and lint

Keep the suite small: test complete and incomplete pagination for each source,
shared retries, state preservation, reference retention and download reuse.
Keep a few source-specific classification and document-resolution regressions,
plus command smoke tests and audit checks against false coverage claims.
Prefer a workflow test over separate checks for every field, helper or setting.
Add a test when it protects a distinct failure with a meaningful consequence;
remove superseded checks and fixtures that no remaining test uses.

From `rag-pipeline/scraper/`; tests run offline from saved responses:

```powershell
python -m unittest discover -s tests -t .
```

From `rag-pipeline/`:

```powershell
ruff check .
ruff format --check .
```

## Adding a source

A source is three files:

- `scraper/sources/<source>.py`, the module.
- `scraper/config/<source>_scope.json`, its own settings: facet values, document
  types, keyword queries, `max_results_per_query`.
- `scraper/tests/test_<source>.py`, offline tests, with trimmed responses
  under `tests/fixtures/<source>/` (under 50 KB each, no PDFs).

Register its module in `run.py`'s `SOURCE_MODULES`; it then appears in
both launchers. Helpers belong in `HELPER_MODULES`; `BATCH_COMMANDS` controls
which helpers run in a batch and their order. Load source settings from
`Path(__file__).resolve().parents[1] / "config" / "<source>_scope.json"`.

The module starts with a header docstring (source, strategy, pagination,
query cap, kept, dropped, quirks, each with the date it was checked), defines
`SOURCE` and `REPO = Path(__file__).resolve().parents[3]`, and has four
functions:

```python
def plan_searches(args: Namespace) -> list[dict]:
    """List every search this run will make. Each needs a unique, stable "name"."""


def run_search(client: Client, search: dict) -> SearchResult:
    """Fetch every page of one search and return its records."""


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Return status, reason and matched keywords for one record."""


def pdf_urls(record: dict) -> list[str]:
    """Return download URLs for one record, best first."""
```

Optional names the runner reads: `SCOPE_FILE` (its checksum goes in the
summary), `EXTRA_FIELDS` (extra catalogue columns), `HEADERS` (default request
headers for this site) and `add_arguments(parser)` for the source's own
options.

Sources with document landing pages may also provide
`resolve_pdf_urls(client, record)`. The downloader calls it when a file needs
fetching; `pdf_urls(record)` still exposes known links without network requests.
Resolution failures are recorded as download failures, separate from listing
completeness.
An optional `prepare_run(args)` hook loads local lookup tables once per run,
before any search or `--download-only` reclassification.
`prepare_record(record)` attaches that evidence before shared date/language
checks, including recovered report years and project closing dates.

What the core gives you:

- `core.fetch.Client`: `get_json`, `get_html`, `get_xml`, `post`, `download`.
  Rate limit, retries, `robots.txt` and one session per thread are handled.
  `RequestFailed` is raised when a request cannot succeed.
- `core.searching.SearchResult(records, expected, pages, error, notes)`:
  `expected` is the site's own total (or `None` when it gives none). A
  non-empty `error` marks the search incomplete. `combine_pieces` joins the
  pieces of a split query and checks that they add up.
- `core.matching`: `find_keywords`, `find_countries`, `is_african`,
  `is_english`, `parse_date`.
- `core.storage`: `RECORD_FIELDS`, state access and CSV/JSON helpers.
- `core.documents`: `document_filename`, `check_document`, PDF checks and
  version preservation.

The runner applies the date window and the English-only rule before
`classify` is called, so `classify` decides only what is source-specific.
Records are dicts with the `RECORD_FIELDS` columns that the source can fill;
put a project's closing date in `project_end_date` when the site gives no
document date.

Rules for every source:

- Make every search complete. Find the site's own per-query cap, write it in
  the header and the scope file, and split queries that reach it.
- Prefer listing through filters (country, type, date) over relevance-ranked
  keyword search, which may only show the top results. Use server-side filters
  so queries stay small.
- Be polite. If a site blocks a normal browser-like session, stop and report;
  do not try to get around it.
- Write plain functions under about 40 lines, with a one-line docstring each
  and one comment above each block saying what it does. A comment on a site
  quirk gives the evidence: the date checked and an example ID or URL.
- Type hints everywhere, `logging` not `print`, specific exceptions. `ruff
  check` and `ruff format --check` must be clean.

## Sources

### World Bank (`worldbank.py`)

```powershell
python rag-pipeline/scraper/run.py worldbank
python rag-pipeline/scraper/run.py worldbank --countries Kenya --skip-keywords --metadata-only
```

The Documents and Reports API, queried once per document type (Implementation
Completion and Results Report, Implementation Completion Report Review,
Project Performance Assessment Report) and per African country or regional
value, plus seven keyword queries: 207 searches. Both date bounds go to the
API (`strdate` alone omits later years). The API rejects offsets above
100,000, so a query with 100,000 results or more is split by date.

A title keyword or the Bank's Agriculture topic gives `in_scope`; an
abstract-only keyword gives `to_screen`. Development policy lending is
dropped. `World` records pass only when the title names an African place.
PDFs are tried on `documents1.worldbank.org` first, then on the API's own
link.

Own options: `--countries`, `--skip-keywords`, `--no-server-dates` (send no
date bounds; dates are still checked locally), `--projects-file` (defaults to
`<output-dir>/worldbank_projects.csv` if present).

Project details add Agriculture sector evidence and exclude development policy
instruments even when the document title does not name them. Refresh details
after a document run, then rerun documents to use them:

```powershell
python rag-pipeline/scraper/run.py worldbank_projects
python rag-pipeline/scraper/run.py worldbank
```

The helper reads the kept catalogue (`--catalogue` overrides its path), uses
exact project-ID lookups, and writes `worldbank_projects.csv` with sector,
theme, instrument, dates and amounts in USD. Borrower, implementing agency,
team leader, region, status and the complete API response are retained too.
Missing public projects have
`retrieval_status=not_found`. Failed requests leave the previous table intact.
Logs and summaries are under `outputs/worldbank/project_runs/`.

API reference: https://documents.worldbank.org/en/publication/documents-reports/api

### Adaptation Fund (`af.py`)

```powershell
python rag-pipeline/scraper/run.py af --max-downloads 5
```

Climate Policy Radar's fund and geography filters enumerate complete families,
then every document in each family. Pagination uses `page_token`, with repeated
IDs and changing totals rejected. Evaluations and completion reports use their
document dates; a family's approval date is never treated as a report date.
The shared `cpr.py` also serves GCF. Outputs use the `af` source folder.

### African Development Bank (`afdb.py`)

```powershell
python rag-pipeline/scraper/run.py afdb --metadata-only
python rag-pipeline/scraper/run.py afdb --manual-listing listing.csv --max-downloads 5
```

Category listings and IDEV's runtime taxonomy are separate discovery channels.
Project codes with an A in the third group provide Agriculture evidence.
Normal browser headers and a homepage visit establish the session; access
blocks stop the run. A complete browser-exported CSV can supply `title`,
`web_url`, `doc_date`, and optional `id`, `pdf_url`, `language`, `country`,
`project_id` and `doc_type`. This is an explicit manual input, not a claim
that the live website was enumerated. Outputs use `afdb`.

The current sweeps use the PCR listing and the complete Evaluation Reports
umbrella, since old subcategory URLs redirect to different taxonomies. The
2026-10-22 live metadata sweep completed with 1,765 unique records, including
227 IDEV records. The main site requires a 10-second Crawl-delay, so full
download runs take time. Older interrupted run evidence remains available.

### Climate Investment Funds (`cif.py`)

```powershell
python rag-pipeline/scraper/run.py cif --max-downloads 5
```

The current website's `/search-data` endpoint enumerates knowledge documents,
documents and resource collection entries by offset and reported count. Index IDs remain stable
across pages. Known unreliable date filters are avoided; document dates are
checked locally. Proposals, evaluation planning materials and administrative
documents are excluded. Global evaluations can require geography screening.
File links and alternatives are resolved from detail pages, including the
working alternative to node 18282's double-encoded index link. Language is
never invented when absent from the index; explicit source fields or clear
title labels supply it. Outputs use `cif`.

### Green Climate Fund (`gcf.py`)

```powershell
python rag-pipeline/scraper/run.py gcf --max-downloads 5
```

The current website uses HTML fragments returned by GET endpoints. African
adaptation projects are enumerated across statuses: a final evaluation may be
published before the project's status changes to completed. Evaluation and
completion document listings are then joined to those projects. Climate Policy
Radar is a second discovery channel, recorded in `retrieval_channel`.
An incomplete channel makes the whole run incomplete. Outputs use `gcf`;
potential cross-channel duplicates remain identifiable for later deduplication.
On 2026-10-22 the website channel completed, but the indexed CPR family
`GCF.family.FP221.23830` returned HTTP 410. The combined run remains
incomplete; earlier records and files are preserved.

### Global Environment Facility (`gef.py`)

```powershell
python rag-pipeline/scraper/run.py gef --metadata-only
python rag-pipeline/scraper/run.py gef_doc_dates --pdf-dir downloads/gef
```

Four independent sweeps cover LDCF, SCCF, Land Degradation and Climate Change.
Filtered access returned HTTP 403 during validation on 2026-10-15 and 2026-10-22, so live
completeness and a query cap remain unverified. The scraper stops on refusal;
there is no fallback that bypasses the block. Offline tests cover listing
counts, repeated IDs, document families and saved date lookup.

Recovered years in `outputs/gef/gef_doc_dates.csv` are used on later runs
(`--doc-dates` overrides the table). The helper reads month-name dates from
the first PDF pages, falls back to the whole PDF when necessary, flags low-text
files, and supports Word OOXML dates. Word text uses a bounded raw XML scan
before body-text truncation.
It never trusts PDF creation timestamps. PDF text extraction requires the
optional `PyMuPDF` package, used only by this helper. Supported non-PDF reports
are downloaded in their actual formats.

### IFAD (`ifad.py`)

```powershell
python rag-pipeline/scraper/run.py ifad --max-downloads 5
```

D-Portal's IATI publisher listing supplies the counted activity total and
paginated full XML. Listing the publisher once preserves regional and
multi-country activities. Each document link keeps its activity provenance,
IATI categories and date. `--countries KE ET` narrows the local geography
selection. Generic administrative project links and progress documents are
excluded. File landing pages are resolved at download time. Outputs use `ifad`.

The 2026-10-22 full metadata check succeeded. All 147 file attempts failed
because `operations.ifad.org` could not establish TLS; a regular Chrome check
confirmed the same protocol failure. Those failures remain recorded for retry.
A complete metadata run does not imply successful PDF downloads.
