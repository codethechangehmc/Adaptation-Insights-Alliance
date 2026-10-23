# Completeness audit artefacts, 2026-10-02

Evidence and fetch lists from the six-source audit (four parallel audit agents
plus two earlier single-source investigations). Inputs to the corpus-completion
campaign; see the campaign plan for how each file is consumed.

| file | rows | what it is |
|---|---|---|
| afdb_missing_pcrs.csv | 43 | agriculture PCRs listed on afdb.org, not held (18 inside the 2015-2025 window, 25 posted 2026) |
| wb_missing_projects.csv | 60 | WB projects with evaluative docs in WDS not held (includes legacy types; the P3 scraper re-derives the true fetch list) |
| gef_failed_downloads.csv | 39 docs / 26 projects | catalogue lists a TE/MTR/evaluation/completion report, zero files on disk (silent download failures) |
| gef_cdn_urls.csv | 17 | Africa LDCF/SCCF evaluations with direct Azure CDN URLs, none held |
| af_missing_files.csv | 20 | evaluation-type links on adaptation-fund.org project pages for projects we hold no evaluation of (inclusive; classify at download) |
| cif_rescreen.csv | 6 | CIF documents to re-screen under the covers-several-projects rule |
| holdout/wrong_exclusions.csv | 26 | known wrong or self-contradicting exclusions found by full-read audits |

## holdout/ custody rule

`holdout/wrong_exclusions.csv` is the held-out reference for the screening
re-verification gate (reference written before the re-screen runs). It must
never be given to any retrieval, screening, reask-list or adjudication agent.
Only the orchestrator's gate step reads it, after the re-screen output exists.
A re-verification pass that fails to flip or flag every `clear` row fails its
gate.
