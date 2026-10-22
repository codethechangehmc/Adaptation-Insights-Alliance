# catalogues/

Small reference tables the scripts read at run time. Two kinds of file live
here.

**Per funder folders** (`af`, `afdb`, `cif`, `gcf`, `gef`, `worldbank`) are
git tracked copies of the metadata lists that live next to the documents on
OneDrive, in `03_Documents/{source}/List/`. Do not edit the copies. Edit the
originals and run:

```
Rscript R/04_catalogue/sync_metadata.R
```

**Pipeline wide files:**

| File | What it is |
|---|---|
| `doc_index.csv` | Corpus filename to catalogue metadata (title, project id, year, report number, URL). The extraction prefills fields from it. |
| `gold_v1_general.csv` | The corrected gold standard for the ten pilot projects, general sheet. |
| `gold_v1_locations.csv` | The gold standard, location sheet. |
| `gold_v1_results.csv` | The results (value, metric, unit, page) recorded for the gold projects. |
| `gold_v1_adjudication.csv` | Where the manual gold and the reading based reference disagreed, and who was right. |
| `holdout_reference.csv` | The reference for the ten holdout documents, never used for tuning. |
| `claude_locations_reference.csv` | The reading based location reference (308 rows). |
| `vocab_decisions.csv` | Every harmonisation decision (field, option list fingerprint, extract, choice). Reused on rerun so results are reproducible. A person can correct a row. |
| `actor_synonyms.csv` | Organisation names as documents write them, each pointing at exactly one actor code. |
| `actor_website_harvest.csv` | What each organisation's own website says about its name. |
| `corpus_screen.csv` | An older folder label check, kept for reference. The live screening file is `05_Extraction_Results/review/scope_screen.csv`. |
| `zotero_duplicate_report.csv` | An older duplicate report for the Zotero library. |
