# Improvements over the R scrapers

The Python scrapers replace the R retrieval scripts in `R/01_retrieve/`. They
collect the same kind of documents but are stricter, faster and easier to
rerun.

## What changed

| | R | Python |
|---|---|---|
| Incomplete searches | A failed request returned `NULL` and paging quietly stopped. World Bank keyword queries stopped at 500 results; IFAD read links for at most 400 projects | A search is complete only when it gets every record the site reports. Capped queries are split and must add up. Any incomplete search stops the run and keeps the previous catalogue |
| Dropped documents | Filtered out and not saved | Stored in `state.sqlite3` with a reason code; never deleted |
| Downloads | Any file on disk was skipped, even a broken one; files written straight to their final name | Written to a temporary name and checked (size, header, `%%EOF`, expected length) before renaming. Checksums stored. Word, Excel, RTF, ZIP and TIFF kept in their real format. `--refresh` keeps old versions |
| Speed | 1 to 2.5 seconds between requests, one at a time, one source at a time | 16 requests in flight with a shared per-site limit; sources side by side. Search-only for five sources: 1 min 37 s, against about 9 minutes one at a time (2026-10-22) |
| Politeness | robots.txt not read; a 403 was logged and requests continued | robots.txt rules and `Crawl-delay` followed, including redirects. A 403 stops all requests to that site |
| Reruns | No lock, no run record | Folder lock, a run folder with summary, searches, decisions, downloads and log, drift warnings, clear exit codes |
| Tests | None | 24 offline tests from saved responses |

Source updates: GCF uses the current site (R posted to a Drupal endpoint that
no longer exists) and includes every project status, because a final
evaluation can appear while a project is still running (FP049). CIF had an R
scraper that `run_all.R` never ran. GEF uses four sweeps instead of one search
per country. All sources keep weak-evidence documents of a project when
another document of it is kept.

## Checked against R, 2026-10-22

Every document in the saved R catalogues is also kept by Python:

| Source | R documents kept by Python | Python total kept |
|---|---:|---:|
| World Bank | 1,328 of 1,328 | 1,785 |
| Adaptation Fund | 35 of 35 | 44 |
| AfDB | 174 of 174 | 245 |
| CIF | 76 of 76 | 96 |
| GCF | 12 of 12 | 43 |
| GEF | 824 of 824 | 824 |

IFAD had no saved R baseline. Details and remaining file gaps are in
[audit/REVIEW.md](audit/REVIEW.md).

## The extra documents Python keeps

Python kept 735 documents that R did not. They were checked by title, type,
country and, for the World Bank, the project's sector shares. Nobody read the
documents, so this is a first pass.

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
forestry or irrigation. By that test 60% of the World Bank extras pass,
against 43% of the documents R also kept.

They came in through complete listings (no 500-result cap, all GCF statuses,
CIF and IFAD now run), new evidence (World Bank sector data and Agriculture
topic tag, AfDB agriculture project codes), project siblings, undated or
unclear-geography documents kept for screening, and older reference lists.

The poor ones came mainly from the World Bank Agriculture topic tag (attached
to some governance and urban projects), the sibling rule (89 of 92 World Bank
siblings were off-topic), small agriculture shares, IFAD documents filed
under the wrong project, AF readiness grants and two non-African AF projects
caused by a region label, and CIF administrative papers.

### Fixes made on 2026-10-22

| Fix | Removed |
|---|---:|
| AF and GCF: read Climate Policy Radar's new label format, so a region label no longer counts as a country | 2 (Pakistan, Jordan) |
| IFAD: drop a document filed under another project; its own project keeps it | 38 |
| IFAD: drop audit reports | 7 |
| IFAD: repair garbled accents in titles | 0 |
| CIF: add options papers, policy and guidance notes and session notes to the admin filter, and "Caribbean" to the non-Africa list | 4 |

After the fixes: AF keeps 41, IFAD 102, CIF 92. Every R reference kept before
is still kept.

Left for screening on purpose: about 160 World Bank topic-tag, sibling and
small-share projects (telling a core agriculture project from one with a small
farming part needs judgement), AF readiness grants (R kept five of the same
kind; a team decision), CIF management responses and energy evaluations, and
an AfDB wind farm report and French study. The R screening
(`R/03_screen/screen_scope.R`) checks location, sector, climate response and
whether the report covers work actually done, so it should remove most of
these. Errors that code can decide for certain are fixed here instead, because
wrong metadata travels on to dedup and extraction.

## Still open

These are problems on the source websites, not in the scraper:

- **GEF:** the site refuses access (HTTP 403). Earlier records are kept.
- **IFAD:** records are found, but the file server cannot open a secure
  connection, so no files download.
- **GCF:** one Climate Policy Radar record no longer exists (HTTP 410), so the
  GCF run is marked incomplete.
