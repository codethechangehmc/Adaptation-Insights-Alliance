# Retrieval comparison, 2026-10-22

The confirmed retrieval discrepancies have been corrected. Every saved R
reference in the six sources with usable baselines is retained in Python.
Complete downloaded-file parity is still blocked by upstream failures and
two unresolved historical GCF file identities. A retained reference does not
establish final eligibility or prove that a current download has historical
byte identity.

## Scope and evidence

The review inventoried 71 R scripts (18,736 lines) and 333 existing tabular,
JSON, RDS and database artifacts. Retrieval source rules, the two helpers,
saved catalogues, successful download logs and corpus-index references were
compared against Python. The source audit unions saved snapshots rather than
choosing whichever single snapshot gives the best result. GEF's baseline
reconstructs the R target-family and best-document-per-project selection from
the saved all-documents table. Skipped filename collisions are not successful
downloads.

Python currently implements retrieval and the project/date helpers. R stages
02 through 09 still implement deduplication, screening, cataloguing, extraction,
harmonisation, review, quality checks and publication. Their contracts were
inventoried, but their external corpus, templates, registries, model services
and Zotero state are not all available here. Operational downstream stages were
not executed or ported. R 4.6.1 is installed, though Rscript is not on PATH.
Invoking its regression entry point by absolute path stopped at the missing
external template's `actor_codes` sheet before running cases; the log is saved
as `r_regressions.log`. This is not a claim of parity for the entire R pipeline.
GitHub issues are disabled for this repository.

Historical review data remains in its original ignored `rag-pipeline/data/`
folder; no state or files were moved. New audit outputs default to
`rag-pipeline/scraper/data/`. Detailed historical evidence is in
`rag-pipeline/data/validation/reports/20261022_review/`:

- `r_script_inventory.csv`, `r_stage_contracts.csv`, `artifact_inventory.csv`:
  script coverage, output contracts and local artifact inventory.
- `source_coverage.csv` and `.json`: retained records, checked files, reference
  coverage, live-search status and exact run-summary paths.
- `checked_retained_files.csv`, `missing_reference_files.csv`: per-file results
  and upstream error evidence.
- `worldbank_project_comparison.csv`, `filename_collisions_before.csv` and
  `filename_collisions_after.csv`: project recall and collision repair evidence.
- Date and preservation comparisons in the same folder describe the limits
  of matching older outputs to current records.

Per-source `r_comparison.csv` files contain the reference identity, matched
Python identity, original rule decision, filename, checksum and file status.
The IFAD state used here is `ifad_review/verified_outputs/state.sqlite3`, not
the older preliminary state in `ifad_review/outputs/`.

## Final coverage

All download passes, including the AfDB collision repair, have finished.
Counts refer to retained document records; identical content under separate
native IDs is not silently deduplicated.

| Source | Python retained | Checked local files | R references retained | R references with checked files |
|---|---:|---:|---:|---:|
| World Bank | 1,785 | 1,783 | 1,328 / 1,328 | 1,327 / 1,328 |
| Adaptation Fund | 44 | 44 | 35 / 35 | 35 / 35 |
| AfDB | 245 | 245 | 174 / 174 | 174 / 174 |
| CIF | 96 | 93 | 76 / 76 | 73 / 76 |
| GCF | 43 | 41 | 12 / 12 | 10 / 12 |
| GEF | 824 | 795 | 824 / 824 | 795 / 824 |
| IFAD | 147 | 0 | No saved baseline | Not established |

"Checked" means the supported format's signature/container checks and stored
SHA-256 agree. PDF checks include minimum size, header and EOF marker. This is
not a complete semantic or structural validation of every document.

World Bank, AF, AfDB, CIF and IFAD completed fresh live listing searches. GCF's
website channel completed, but CPR stopped at an indexed family returning
HTTP 410. Its partial records are diagnostic only; the incomplete run did not
publish a replacement catalogue. GEF's four live sweeps returned HTTP 403;
its 824 records were explicitly seeded from the baseline, not freshly found.
Download-only runs are labelled separately and do not claim live completeness.

## Corrected behavior

- Duplicate search hits now fill missing metadata and combine file links.
  An early sparse hit no longer hides later useful evidence.
- Explicit inclusion lists persist reference IDs and URLs across runs.
  Rule-based drops remain available as `to_screen/reference_recall`, with
  their original `rule_status` and `rule_reason`. Authoritative unknown dates,
  language and geography stay unknown; family approval dates do not become
  report dates. Reference retention cannot lift unrelated project siblings.
- Download-only runs reclassify stored records and retry all retained files,
  including records absent from a later search. They preserve last-seen times
  and use local project/date enrichment before shared filtering.
- Download handling preserves supported Office, archive, RTF, TIFF and explicit
  HTML documents as well as PDFs. It verifies containers, keeps saved names
  through metadata enrichment and archives changed content. A redirected HTML
  error page cannot satisfy a PDF download. Known reference links remain usable
  when a detail-page resolver fails.
- Long native IDs receive a stable hash suffix when truncated. Final checksum
  verification exposed two AfDB LEAF II reports sharing a truncated filename;
  both were freshly downloaded into distinct paths. The old shared file remains
  untouched, and no shared state filenames remain across the seven sources.
- AfDB resolves older plain anchors and PDF-viewer iframe links. CIF combines
  listing and detail-page alternatives, recovering a real double-encoded link,
  and preserves unknown or supplied language instead of inventing English.
  GCF keeps all linked project IDs, titles and countries on shared reports.
- World Bank recovers all project IDs from legacy project-name fields. Its
  project helper retains borrower, implementing agency, status, region, team
  leader, environmental category and raw upstream metadata. All 426 saved R
  project IDs appear in the refreshed 1,429-project snapshot; eight additional
  requested IDs were not found by the API.
- GEF date recovery restores whole-PDF fallback and matches the R OOXML text
  bounds. Stored noncanonical document-family labels are normalized while
  preserving `source_doc_type`, so proposals and PIRs expose their real rule
  reasons even when explicitly retained for reference recall.
- Audits preserve duplicate URL rows, use source-specific normalized baselines
  for every matching mode, check actual local bytes, reject an empty baseline
  as proof of a superset and keep missing records separate from missing files.

Five World Bank files previously adopted through skipped filename-collision
claims were refreshed: IDs `25760331`, `31330660`, `31364799`, `33811049` and
`33873549`. Every replacement had different content. Previous copies remain
archived; the original R corpus was not modified. Other reused files were
reconciled against native IDs/checksums or exact successful-log URLs.

Six GCF historical corpus filenames were reconciled to current native records
using report covers and manual screening evidence. The evidence is in
`gcf_review/reference_resolution.csv`, which explicitly records that historical
byte identity was not verified. Two summary filenames remain unresolved.

All 1,039 previously retained Python IDs remain retained in the five sources
with comparable complete earlier runs: World Bank 762, AF 41, CIF 48, GCF 41
and verified IFAD 147. AfDB and GEF had no complete earlier Python baseline.
GEF date recovery produced 613 dated and 182 undated files, with zero read
errors. Of 193 saved R date rows, 142 could be linked by exact filename and URL
to a current record; 140 years agree. Two legacy DOC results rely on separately
recorded OLE provenance beyond the R date script. The other 51 rows remain
unmapped. This measures baseline agreement, not date accuracy against labels.

## Remaining blockers and protocol decisions

- World Bank `11636956` returns a 2,209-byte disclosure-only stub and fails the
  minimum PDF check. It is the one missing baseline file. Additional Python
  record `33634810` returns HTTP 404 from both official mirrors.
- CIF `7780`, `7781` and `7785` return empty administrative PDFs.
- GCF CPR family `GCF.family.FP221.23830` returns HTTP 410. Historical FP023 and
  FP024 project-completion-summary aliases lack enough provenance for a safe
  historical mapping; current summaries were not substituted on title alone.
- GEF has 29 inaccessible reference files: 17 Azure/SharePoint paths fail on
  apostrophes in upstream OData handling, and 12 URLs redirect from the retired
  `undpgefpims.org` host. No verified replacement was found. The current website
  also returns HTTP 403, so a fresh listing superset is not established.
- All 147 IFAD downloads fail TLS access to `operations.ifad.org`. A normal
  Chrome connection also failed with `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`.
  Its live metadata search completed, but file retrieval remains unvalidated.
- The protocol names PIRs in one place while its eligibility table excludes
  progress reports. Normal classification keeps `progress_report` as a drop;
  explicit baseline references remain available for screening. This conflict
  needs a protocol decision before changing final eligibility.

No access block was bypassed. Missing or ambiguous files remain visible in
the audit rather than being credited as downloaded. External failures prevent
claiming that every requested task, or a complete downloaded superset, is done.

## Cleanup and validation

The original retrieval review removed an empty parsing placeholder and broken
direct-launch wrappers from its working branch. This integration preserves the
existing `ctc-rag` parser, chunker and parent dependency list unchanged. Scraper
entry points remain `scraper/run.py` and `scraper/run_all.py`. R code, protocol
documents, curated catalogues and the original corpus remain untouched.

For a new scraper installation, validation uses its own environment:

```powershell
# From rag-pipeline/scraper:
.\.venv\Scripts\python.exe -m unittest discover -s tests -t .

# From the repository root:
rag-pipeline/scraper/.venv/Scripts/python.exe -m ruff check rag-pipeline/scraper
rag-pipeline/scraper/.venv/Scripts/python.exe -m ruff format --check rag-pipeline/scraper
git diff --check
python rag-pipeline/scraper/audit/compare_with_r.py af `
  --download-dir rag-pipeline/scraper/data/af_review/downloads --require-superset
```

At the original retrieval review, all 174 offline tests, Ruff lint, Ruff
formatting and `git diff --check` passed. The suite has since been simplified;
the integration PR records current offline results. AF and AfDB passed the
strict downloaded-superset audit at that review. The other superset audit
failures are evidence of the listed missing files or absent baseline, separate
from offline regression-test results. Runtime scrapers never import the R audit
or read curated R catalogues; inclusion lists are an explicit, generic input.
