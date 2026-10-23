# Improvements over the R scrapers

The Python scrapers replace the R retrieval scripts in `R/01_retrieve/`. They
collect the same kind of documents, but they are stricter, faster and easier
to rerun. This page lists what changed and why it matters.

## Searches are complete or they fail

**R:** a failed request returned `NULL`, and the paging loop simply stopped.
The search ended early with no error, so a network blip could quietly drop
results. Some queries had hard caps: World Bank keyword queries stopped at 500
results, and IFAD fetched document links for at most 400 projects.

**Python:** a search is complete only when it gets as many records as the site
reports. If a site caps one query, the query is split into smaller ones (by
date, country or type) that must add up to the original total. If any search
is incomplete, the run stops and the previous catalogue stays as it was.

## Every decision is recorded

**R:** dropped documents were filtered out and not saved. There was no way to
see later why a document was left out.

**Python:** every document ever seen is stored in `state.sqlite3`, kept or
dropped, with a short reason code such as `no_african_country` or
`proposal_stage`. Records are never deleted. Each run also writes
`decisions.csv` with every decision it made.

## Downloads are checked and safe to resume

**R:** any file already on disk was skipped, even a broken one. A new download
was held in memory, written straight to its final name, and checked only for
size and the `%PDF-` header.

**Python:**

- Files are written to a temporary name and renamed only after they pass the
  checks, so an interrupted download never looks complete.
- Checks include size, header, the `%%EOF` end marker and the expected length.
- Each file's SHA-256 checksum is stored. A file on disk is reused only if it
  still passes the checks.
- Word, Excel, RTF, ZIP and TIFF reports are kept in their real format instead
  of being rejected as "not a PDF".
- Each result is saved as soon as it finishes. Failed downloads are retried on
  the next run.
- `--refresh` downloads again and keeps the old copy if the content changed.

## Faster

**R:** every request waited a random 1 to 2.5 seconds, requests ran one at a
time, and sources ran one after another.

**Python:**

- Many requests run at once (16 by default), sharing one rate limit per site.
- The wait is 0.5 seconds per site, or 0.1 seconds for sites built for
  automated traffic (World Bank, Climate Policy Radar, GEF files).
- `run_all.py` runs sources side by side.

A search-only run of World Bank, AF, GCF, CIF and IFAD took 1 minute 37
seconds on 2026-10-22. The same sources took about 9 minutes one at a time.

## More polite

**R:** robots.txt was not read. A blocked request (HTTP 403) was logged and
the script carried on with the next request to the same site.

**Python:** robots.txt rules and `Crawl-delay` are followed, including for
redirected file links. A 403 stops all requests to that site for the run. The
scraper never tries to get around a block.

## Sources match today's websites

- **GCF:** R posted to Drupal's `/views/ajax`, which the site no longer has, and
  only looked at approved and completed projects. Python uses the current site
  and includes every project status, because a final evaluation can appear
  while a project is still "under implementation" (FP049). Climate Policy
  Radar is a second channel.
- **World Bank:** no 500-result cap on keyword queries. Queries above the API's
  100,000 offset limit are split by date.
- **CIF:** has a scraper in R, but R's `run_all.R` did not run it. Python runs
  every source.
- **GEF:** four sweeps (LDCF, SCCF, Land Degradation, Climate Change) instead
  of one Climate Change search per country.
- **All sources:** when one document of a project is kept, documents of the
  same project held back for weak evidence are kept too.

## Safe to rerun

- A lock stops two runs from writing to the same folder at once.
- Each run gets its own folder with a summary, search counts, decisions,
  download results and a log.
- A warning is logged when a site suddenly returns far fewer results than last
  time, which usually means the website changed.
- Clear exit codes: 0 complete, 1 incomplete or error, 130 interrupted.

## Tested

The R scrapers had no tests. Python has 38 offline tests built from saved
website responses. Each guards a rule that matters: complete paging and
incomplete-search detection per source, retries and rate limits, saved state,
file checks, downloads and decisions. They run in a few seconds without
internet.

## Checked against R

Every document in the saved R catalogues is also kept by Python, for all six
sources with a usable R baseline:

| Source | R documents kept by Python | Python total kept |
|---|---:|---:|
| World Bank | 1,328 of 1,328 | 1,785 |
| Adaptation Fund | 35 of 35 | 44 |
| AfDB | 174 of 174 | 245 |
| CIF | 76 of 76 | 96 |
| GCF | 12 of 12 | 43 |
| GEF | 824 of 824 | 824 |

IFAD had no saved R baseline. Details are in
[../audit/REVIEW.md](../audit/REVIEW.md).

## The extra documents Python keeps

Python keeps 735 documents that R did not. We checked them on 2026-10-22 by
title, document type, country and, for the World Bank, the project's sector
shares. Nobody read the documents themselves, so treat this as a first pass.

**Most are good to include.** About two in three are evaluations of
agriculture or adaptation projects in Africa.

| Source | Extra | Good | Borderline | Should not be kept |
|---|---:|---:|---:|---:|
| World Bank | 457 | 275 | 41 | 141 |
| IFAD | 147 | 102 | 0 | 45 |
| AfDB | 71 | 65 | 4 | 2 |
| GCF | 31 | 31 | 0 | 0 |
| CIF | 20 | 3 | 9 | 8 |
| Adaptation Fund | 9 | 0 | 0 | 9 |
| **Total** | **735** | **476 (65%)** | **54 (7%)** | **205 (28%)** |

For the World Bank, "good" means the title names agriculture or adaptation
work, or at least 25% of the project's funding is in agriculture, fishing,
forestry or irrigation. By that test the extras are better than R's own set:
60% of the World Bank extras pass, against 43% of the documents R also kept.

### How they got in

1. **Complete listings.** R stopped World Bank keyword queries at 500 results,
   looked only at approved and completed GCF projects, and did not run CIF.
   Python lists everything, so it finds more. IFAD is entirely new (147).
2. **New evidence.** World Bank project sector data (259 documents) and the
   Bank's own Agriculture topic tag (92). AfDB project codes that mark an
   agriculture project (40).
3. **Project siblings.** When one document of a project is kept, its other
   documents are kept too (92 World Bank, 2 GCF).
4. **Kept for a closer look.** Global evaluations with unclear geography (15
   CIF) and documents with no date (2 AF, 8 IFAD) are kept as `to_screen`.
5. **Older reference lists.** 10 World Bank documents named in older R lists.

### Good

- **AfDB:** almost all are completion reports and evaluations of agriculture,
  irrigation, food security and value chain projects.
- **GCF:** all are interim or final evaluations of African adaptation projects.
  Six projects appear twice, once from the website and once from Climate
  Policy Radar. They are kept on purpose and removed at the dedup stage.
- **IFAD:** mid-term reviews and completion reports of African rural projects.
- **World Bank:** 275 clear agriculture, irrigation, land, water, fisheries
  and resilience projects.

### Where the poor ones come from

- **World Bank Agriculture topic tag.** The Bank tags many governance, urban
  and private sector projects with it (32 off-topic, for example Togo
  governance credits).
- **World Bank sibling rule.** 89 of the 92 siblings are off-topic: health,
  energy, roads and sewerage projects. They inherit weak evidence from another
  document of the same project.
- **Small agriculture shares.** 41 World Bank projects have under 25% of their
  funding in agriculture (energy access, statistics, enterprise development).
- **AF:** two projects are not in Africa (Pakistan and Jordan). Their only
  place label is the "Middle East & North Africa" region, which counts as
  African. Six are small readiness grants (South-South cooperation, gender
  policy), not project evaluations. One is a global grant platform.
- **IFAD:** IFAD's own data also lists some documents under projects they do
  not belong to. 38 such copies were kept: 11 from projects outside Africa
  (Paraguay, Mexico, Ecuador, Brazil, Moldova) and 27 duplicates of African
  documents that are also listed under their own project. Seven are audit
  reports. Some titles had garbled accents (`MinistÃ¨re`), which come from
  IFAD's data itself.
- **CIF:** administrative papers that slip past the filter (an options paper,
  a policy and guidance note, a session note, management responses), energy
  evaluations (Clean Technology Fund, renewable energy program) and a
  Caribbean mission report. Two evaluations appear twice.
- **AfDB:** a wind farm completion report and a French feasibility study.

### Would the R screening remove them?

Mostly, yes. The R screening (`R/03_screen/screen_scope.R`) has a model read
every document in full and checks four things: implemented in Africa,
agriculture as the main subject, a response to a climate risk, and a report of
work actually done. Almost all of the 205 poor documents fail one of the first
two or the last, which are the easiest checks. Health, energy and roads
projects fail on sector. Readiness grants, audit reports and meeting papers
fail on source type. Pakistan, Jordan and Paraguay fail on location. The R
dedup step (`R/02_dedup/dedup_corpus.R`) also merges identical files, which
covers the GCF and IFAD duplicates. Screening costs well under a cent per
document.

We could not measure this directly: the screening results live on the team
OneDrive, not in this repository. The estimate comes from the screener's rules.

The screening is enough for documents that need judgement, such as World Bank
projects with a small agriculture share. It is not enough for errors that code
can decide for certain, for three reasons:

- The pipeline's own rule is deterministic first, model second.
- Wrong metadata travels on. An IFAD copy filed under the wrong project keeps
  the wrong country and project ID, and dedup may keep that copy rather than
  the right one.
- The AF bug writes region names into the country field of every Climate
  Policy Radar record, not just the two that slip through.

### Fixes made on 2026-10-22

| Fix | Removed |
|---|---:|
| AF and GCF: read Climate Policy Radar's new label format, so a region label no longer counts as a country | 2 (Pakistan, Jordan) |
| IFAD: drop a document filed under another project; its own project keeps it | 38 |
| IFAD: drop audit reports | 7 |
| IFAD: repair garbled accents in titles | 0 |
| CIF: add options papers, policy and guidance notes and session notes to the admin filter, and "Caribbean" to the non-Africa list | 4 |

Live and stored-record checks after the change: AF keeps 41 (was 43), IFAD
102 (was 147), CIF 92 (was 96). GCF is unchanged. Nothing new was added, and
every R reference that was kept before is still kept.

Left for the screening, on purpose:

- **World Bank** topic-tag, sibling and small-share projects (about 160).
  Telling a core agriculture project from one with a small farming part needs
  judgement.
- **AF readiness grants.** R kept five of the same kind, so whether they count
  is a team decision.
- **CIF** management responses and energy evaluations, and the **AfDB** wind
  farm and French study.

## Still open

These are problems on the source websites, not in the scraper:

- **GEF:** the site refuses access (HTTP 403). Earlier records are kept.
- **IFAD:** records are found, but the file server cannot open a secure
  connection, so no files download.
- **GCF:** one Climate Policy Radar record no longer exists (HTTP 410), so the
  GCF run is marked incomplete.
