# Scraper developer guide

How the scraper code works and how to change it. The [README](README.md)
covers what the scrapers do and how to run them.

## Folder layout

```text
scraper/
  run.py           runs one source or helper; holds the command list and batch lanes
  run_all.py       runs every source, lanes side by side
  config/          per-source settings and the shared Africa keyword/country lists
  sources/         one module per funder, plus cpr.py (Climate Policy Radar, used by AF and GCF)
  helpers/         World Bank project details, GEF document dates
  core/            the shared workflow
  tests/           offline tests; fixtures/ holds small saved website responses
```

Always start a source through `run.py`, never by running a file in `sources/`.

## How a run works

`core/runner.py` drives every run. A source module only knows its website.

1. Lock the output folder so two runs cannot overlap.
2. Run every search, up to 16 at a time.
3. If any search is incomplete, stop. State, catalogue and files stay as they
   were. Exit code 1.
4. Merge records found by several searches (by `id`) and classify each one.
5. Give documents of one project the strongest decision among them.
6. Save every record to `state.sqlite3`, drops included.
7. Download every kept record that has no good local copy. Each result is
   saved as it finishes.
8. Write the catalogue CSV and the run folder.
9. Compare with the last complete run and log drift warnings.
10. Exit 0, even if some downloads failed. They are retried next run.

**Complete searches.** A search is complete when it gets as many records as
the site reports, or reaches the verified last page when the site gives no
total. If a site caps one query (for example a maximum offset), the source
splits it into smaller queries. The pieces must add up to the original total
with no repeated IDs.

**Politeness.** Each site gets one request every 0.5 seconds, shared by all
workers. Sites built for automated traffic get 0.1 seconds; they are listed in
`FAST_HOSTS` in `core/fetch.py` with the evidence. `--request-interval` sets
one value for every site. A robots.txt `Crawl-delay` always wins (AfDB: 10
seconds). Retries back off and honour `Retry-After`. HTTP 401 or 403, or an
unreadable robots.txt, stops all requests to that site for the run.

## Where to make a change

| Change | File |
|---|---|
| Commands, batch lanes | `run.py` |
| Shared options, summary, drift warnings, logging | `core/runner.py` |
| A source's queries, parsing, paging or rules | `sources/<source>.py` |
| Source settings, keywords, countries | `config/` |
| Date and language gates, project siblings, inclusion lists | `core/classification.py` |
| Keyword, country, language and date matching | `core/matching.py` |
| Running searches, completeness checks | `core/searching.py` |
| HTTP, retries, rate limits, fast hosts, robots.txt, `run_parallel` | `core/fetch.py` |
| Downloads, link resolution, reusing local files | `core/downloads.py` |
| State database, CSV/JSON, file checks, file names, locking | `core/storage.py` |
| Compare with the R reference catalogues | `audit/` |

Core modules never import source modules. Runtime code never imports `audit/`.

## Options

Every source accepts these (`--help` also lists the source's own):

| Option | What it does |
|---|---|
| `--metadata-only` | Search and classify, download nothing |
| `--download-only` | Skip the search; reclassify stored records and retry downloads |
| `--max-downloads N` | Download at most N new files |
| `--refresh` | Download again; a changed file's old copy goes to `versions/` |
| `--start-date`, `--end-date` | Date window. Default: 2015-01-01 to today |
| `--include-listing CSV` | Keep every document in a reference CSV for screening (repeatable) |
| `--output-dir`, `--download-dir` | Default: `outputs/<source>/`, `downloads/<source>/` |
| `--workers N` | Requests in flight at once. Default: 16 |
| `--request-interval S` | Seconds between requests to one site, for every site |

For `run_all.py`, the two folder options are base folders: each source gets a
subfolder. Test runs go under `rag-pipeline/scraper/data/<source>_review/`.

## Batch runs

`run_all.py` runs the lanes in `BATCH_LANES` (in `run.py`) side by side. Each
source runs in its own process, and sources in one lane run in order. Two
lanes have more than one command:

- `worldbank`, then `worldbank_projects`, which reads its catalogue.
- `af`, then `gcf`, because both use Climate Policy Radar and the rate limit
  only works within one process.

Each output line starts with the source name. A full batch takes about as long
as AfDB, the slowest source.

## Outputs

```text
downloads/<source>/          report files: <source>_<id>_<project>_<year>.pdf
outputs/<source>/
  state.sqlite3              every record ever seen, its decision and download result
  <source>_metadata.csv      kept records; rebuilt from state each run
  versions/                  old copies replaced by --refresh
  runs/<run_id>/
    summary.json             options, counts, timings, status, drift warnings, failed IDs
    searches.csv             per search: query, expected, retrieved, error
    decisions.csv            every record seen this run, with status and reason
    downloads.csv            per download: status, file, checksum
    run.log                  readable log
```

- `state.sqlite3` is the source of truth. Records are never deleted. Back it
  up with the downloads. If it is lost, the next run rebuilds it and adopts
  the files on disk; only `first_seen` dates are lost.
- The catalogue CSV is an export. Never edit it to change state.
- Run folders can be deleted at any time. An incomplete run also writes
  `partial_records.csv` for diagnosis only.
- `downloads/`, `outputs/` and `rag-pipeline/scraper/data/` are not in git.

**Catalogue columns** (every source): `source, id, title, pdf_url, doc_date,
doc_type, country, language, project_id, web_url, screen_status,
filter_reason, matched_keywords, search_ids, first_seen, last_seen, filename,
download_status, sha256, bytes`. Sources may add columns after these.

**`download_status`**: `downloaded`, `skipped_valid` (file matches stored
checksum), `adopted_local` (good file that state did not know), `failed`,
`no_pdf_url`, `pending`.

**File checks.** A PDF must be at least 10 KB, start with `%PDF-` and end with
`%%EOF`. Word, Excel, RTF, ZIP/7z and TIFF files keep their real extension and
get a format check. These checks catch error pages and cut downloads, not
every broken file.

## Decisions

`in_scope` and `to_screen` are downloaded. `drop` is recorded, not downloaded.
Every record has a reason code:

| Reason | Meaning |
|---|---|
| `outside_date_range` | Outside the window. Uses the project closing date if there is no document date |
| `unknown_document_date` | No date at all. Kept as `to_screen` |
| `not_english` | Language field, or title words if it is empty, say not English |
| `no_african_country` | No African country or region |
| `policy_or_budget_support` | Development policy lending or budget support |
| `proposal_stage` | A proposal or appraisal, not an evaluation |
| `insufficient_metadata` | Nothing to decide on: no abstract, topics or title match |
| `no_agriculture_or_adaptation_evidence` | No keyword or topic evidence |
| `project_sibling_evidence` | Kept because another document of the project was kept |
| `reference_recall` | Kept by `--include-listing` although the rules would drop it |

Sources add their own positive reasons. Keywords match whole English words and
regular plurals. The lists are in `config/africa.json`.

**Project siblings.** Documents sharing a `project_id` get the strongest
decision among them. Only weak-evidence drops are lifted. Date, language,
country and proposal rules are never overridden.

**Reference listings.** `--include-listing` takes a CSV with at least `id` and
`title`. A document the rules would drop is kept as `to_screen` with reason
`reference_recall`; `rule_status` and `rule_reason` show what the rules said.
This never lifts siblings.

## Adding a source

A source is three files:

- `sources/<source>.py`
- `config/<source>_scope.json`: facets, document types, queries, query cap
- `tests/test_<source>.py`, with trimmed responses in `tests/fixtures/<source>/`
  (under 50 KB each, no PDFs)

Register the module in `SOURCE_MODULES` in `run.py` and add it to
`BATCH_LANES`: its own lane, unless it shares a website with another source.

The module starts with a header docstring: source, strategy, paging, query
cap, kept, dropped and quirks, each with the date checked. It defines
`SOURCE`, `REPO = Path(__file__).resolve().parents[3]` and four functions:

```python
def plan_searches(args: Namespace) -> list[dict]:
    """List every search. Each needs a unique, stable "name"."""


def run_search(client: Client, search: dict) -> SearchResult:
    """Fetch every page of one search and return its records."""


def classify(record: dict) -> tuple[str, str, list[str]]:
    """Return status, reason and matched keywords for one record."""


def pdf_urls(record: dict) -> list[str]:
    """Return download URLs for one record, best first."""
```

The runner applies the date and English checks before `classify`, so
`classify` only decides what is specific to the source.

Optional names the runner uses:

| Name | Use |
|---|---|
| `SCOPE_FILE` | Its checksum goes in the summary |
| `EXTRA_FIELDS` | Extra catalogue columns |
| `HEADERS` | Default request headers for the site |
| `add_arguments(parser)` | The source's own options |
| `resolve_pdf_urls(client, record)` | Find file links on a landing page at download time |
| `prepare_run(args)` | Load local lookup tables once per run |
| `prepare_record(record)` | Add evidence (for example recovered dates) before the shared checks |

What the core gives you:

- `core.fetch.Client`: `get_json`, `get_html`, `get_xml`, `post`, `download`.
  Handles rate limits, retries and robots.txt. Raises `RequestFailed`.
- `core.fetch.run_parallel(client, function, items)`: runs independent
  requests up to `--workers` at a time and keeps item order. With one worker
  it runs in order, so tests can use `Mock(workers=1)`.
- `core.searching.SearchResult(records, expected, pages, error, notes)`:
  `expected` is the site's total or `None`. A non-empty `error` marks the
  search incomplete. `combine_pieces` joins split queries and checks the sum.
- `core.matching`: `find_keywords`, `find_countries`, `is_african`,
  `is_english`, `parse_date`.
- `core.storage`: record fields, state, CSV/JSON, file names and checks.

**Rules for every source:**

- Make every search complete. Find the site's query cap, write it in the
  header and scope file, and split queries that reach it.
- Prefer filtered listings (country, type, date) to keyword search, which may
  only show top results.
- If a site blocks a normal session, stop and report. Never work around it.
- Use `run_parallel` for independent requests. Keep a loop when each page
  depends on the last, or when the server slows down under load. Measure
  before and after.
- Short functions (about 40 lines), a one-line docstring each, a comment above
  each block. A comment on a site quirk gives the date checked and an example
  ID or URL.
- Type hints, `logging` not `print`, specific exceptions.

## Tests and lint

Tests run offline from saved responses. From `rag-pipeline/scraper/`:

```powershell
python -m unittest discover -s tests -t .
```

From `rag-pipeline/scraper/` (install with `pip install ruff`):

```powershell
ruff check .
ruff format --check .
```

Keep the suite small. Test complete and incomplete paging per source, retries,
state, downloads and a few source-specific rules. Add a test when it protects
against a failure that matters; delete tests and fixtures that nothing needs.

## Scheduled runs

Use the same output and download folders every time. Each run searches the
whole date window again, so late-indexed documents are still found. Scripts
find the repository from their own path, so a scheduler can call them from any
folder. On Windows Task Scheduler, set the program to the full path of
`python.exe` and pass the full path of `run.py`, the command and its options.

Exit codes: 0 complete, 1 incomplete search or error, 130 interrupted.

**Drift warnings** mean a site may have changed: a search that found records
last time now finds none, or unique records fell by more than 20 percent. They
never fail the run.

## Source notes

**World Bank** (`worldbank.py`). The Documents and Reports API, one query per
document type (ICR, ICR Review, PPAR) and per African country or region, plus
keyword queries: 207 searches. Both date bounds are sent, because `strdate`
alone drops later years. Offsets above 100,000 are rejected, so larger queries
are split by date. A title keyword or the Agriculture topic gives `in_scope`;
an abstract-only keyword gives `to_screen`. Own options: `--countries`,
`--skip-keywords`, `--no-server-dates`, `--projects-file`.

**World Bank projects** (`helpers/worldbank_projects.py`). Looks up every
project in the kept catalogue and writes `worldbank_projects.csv` (sector,
instrument, dates, amounts). The next `worldbank` run uses it to add
Agriculture evidence and drop policy lending. A failed lookup leaves the old
table in place.

**Adaptation Fund** (`af.py`, through `cpr.py`). Climate Policy Radar fund and
region filters list every project family, then each family's documents are
fetched in parallel. A family's approval date is never used as a report date.
Place labels decide geography: a country label wins over a region label, so
"Middle East & North Africa" cannot make a Pakistan project African. Since
2026-10 the label kind sits in `value.type`.

**AfDB** (`afdb.py`). Two channels: AfDB category listings (PCR and the
evaluation reports umbrella) and IDEV's five evaluation categories, run in
parallel. `www.afdb.org` sets a 10-second Crawl-delay, so its listings and
downloads are slow. A browser-exported CSV can replace live listing with
`--manual-listing`. Project codes with an A in the third group count as
Agriculture.

**CIF** (`cif.py`). The site's `/search-data` endpoint, paged by offset with a
reported count. Pages stay sequential because the index groups entries. Date
filters are unreliable, so dates are checked locally. File links are also
taken from detail pages, which fixes broken index links (node 18282).

**GCF** (`gcf.py`). Website HTML fragments list African adaptation projects in
every status, then evaluation and completion documents are joined to them.
Climate Policy Radar is a second channel. If either is incomplete, the run is
incomplete. Since 2026-10-22, CPR family `GCF.family.FP221.23830` returns HTTP
410.

**GEF** (`gef.py`). Four sweeps: LDCF, SCCF, Land Degradation, Climate Change.
African project pages are opened in parallel. The site has returned HTTP 403
since 2026-10-15, so live completeness is unverified. `gef_doc_dates` reads
report years from downloaded files (needs `PyMuPDF`) and later runs use them.

**IFAD** (`ifad.py`). D-Portal's copy of IFAD's IATI data: a count, then XML
pages of every activity. Each document link becomes one record. IFAD also
lists some documents under projects they do not belong to; the title's project
number shows the right one, so those copies are dropped as
`filed_under_other_project` (the right copy stays). Audit reports are dropped.
Garbled accents in IFAD's text are repaired. Pages stay
sequential: each is 3 to 4 MB, and parallel paging took 90 seconds against 48.
File downloads currently fail because `operations.ifad.org` cannot open a
secure connection.
