# Retrieval comparison with R, 2026-10-22

Every saved R reference in the six sources with a usable baseline is kept by
Python. Complete downloaded-file parity is still blocked by upstream failures
and two unresolved historical GCF files. Keeping a reference does not prove it
is eligible, or that today's download is byte-identical to the old one.

## Scope

The review inventoried 71 R scripts and 333 saved tables and databases, and
compared the R retrieval rules, the two helpers, saved catalogues, download
logs and corpus-index references with Python. The audit takes the union of all
saved R snapshots, not the most favourable one. GEF's baseline rebuilds R's
target-family and best-document-per-project selection. R stages 02 to 09
(dedup to publication) were inventoried but not run or ported; this is not a
claim of parity for the whole R pipeline.

Detailed evidence (inventories, per-file results, collisions, date
comparisons) is in the ignored
`rag-pipeline/data/validation/reports/20261022_review/`. Per-source
`r_comparison.csv` files list each reference, its Python match, rule decision,
file and checksum.

## Coverage

| Source | Python kept | Checked local files | R references kept | R references with checked files |
|---|---:|---:|---:|---:|
| World Bank | 1,785 | 1,783 | 1,328 / 1,328 | 1,327 / 1,328 |
| Adaptation Fund | 44 | 44 | 35 / 35 | 35 / 35 |
| AfDB | 245 | 245 | 174 / 174 | 174 / 174 |
| CIF | 96 | 93 | 76 / 76 | 73 / 76 |
| GCF | 43 | 41 | 12 / 12 | 10 / 12 |
| GEF | 824 | 795 | 824 / 824 | 795 / 824 |
| IFAD | 147 | 0 | No saved baseline | Not established |

"Checked" means the format check passed and the stored SHA-256 matches. World
Bank, AF, AfDB, CIF and IFAD completed fresh live searches. GCF's website
channel completed but Climate Policy Radar stopped at a family returning HTTP
410. GEF's live sweeps returned HTTP 403; its 824 records come from the
baseline, not a fresh search.

## What the review corrected

- Duplicate search hits now fill missing fields and combine file links.
- Inclusion lists persist across runs. A rule drop kept for reference shows as
  `to_screen` with its original rule reason. Unknown dates, languages and
  countries stay unknown.
- Download-only runs reclassify stored records and retry every kept file.
- Office, archive, RTF, TIFF and HTML documents are kept, not just PDFs. A PDF
  link that redirects to an HTML error page fails.
- Long IDs get a hash suffix in file names. This exposed two AfDB LEAF II
  reports sharing a name; both were downloaded to separate files.
- AfDB reads older anchors and PDF-viewer links. CIF combines index and
  detail-page links. GCF keeps every project linked to a shared report.
- World Bank recovers project IDs from legacy name fields; all 426 saved R
  project IDs are in the project snapshot.
- GEF date recovery reads the whole PDF when the first pages have no date:
  613 files dated, 182 undated, no read errors. Of 142 R dates that could be
  linked to a current record, 140 agree.

## Remaining blockers

- World Bank `11636956` is a 2,209-byte disclosure stub and fails the PDF
  check; `33634810` returns HTTP 404 from both mirrors.
- CIF `7780`, `7781` and `7785` are empty administrative PDFs.
- GCF family `GCF.family.FP221.23830` returns HTTP 410. Two historical FP023
  and FP024 summary files lack the provenance for a safe match.
- GEF has 29 unreachable reference files: 17 SharePoint paths break on
  apostrophes and 12 redirect from the retired `undpgefpims.org`.
- All 147 IFAD downloads fail TLS to `operations.ifad.org`; a normal Chrome
  connection fails the same way.
- The protocol names PIRs in one place but excludes progress reports in its
  eligibility table. Normal rules drop progress reports; references stay
  available for screening. This needs a protocol decision.

No access block was bypassed. Missing files stay visible in the audit.

## Rerunning the check

```powershell
python rag-pipeline/scraper/audit/compare_with_r.py af `
  --download-dir rag-pipeline/scraper/data/af_review/downloads --require-superset
```

See the [README](../README.md#comparing-with-the-r-catalogues) for the full
export, replay and check sequence.
