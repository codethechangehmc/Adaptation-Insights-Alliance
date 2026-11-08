# Weekly retrieval with Zotero checkpoints

[automation/weekly-scraper.yml](automation/weekly-scraper.yml) is a GitHub
Actions template for a weekly run. It is not active until copied to
`.github/workflows/weekly-scraper.yml` on the default branch. It only
restores, retrieves and saves. It does no screening, extraction or Zotero
report publishing.

## How it works

1. **Restore.** Download the last committed checkpoint ZIP from a dedicated
   Zotero item, check every file against its manifest, and unpack it into
   empty folders. Missing, corrupt or unreadable state stops the run; it never
   silently starts a new corpus.
2. **Retrieve.** Run `run_all.py` on the restored `outputs/` and `downloads/`.
   A failed source does not stop the others, and an incomplete search never
   replaces that source's catalogue.
3. **Save.** Zip `outputs/` and `downloads/` with a checksum manifest (SQLite
   copied through its backup API), upload it as a new attachment, download it
   again to verify, then move the item's pointer to it. The pointer moves only
   if nobody else changed it meanwhile. Old attachments are kept; nothing is
   deleted automatically.

A batch that exits normally is checkpointed even if a source failed, because
its finished downloads are worth keeping; the Actions run still shows red. A
cancelled or timed-out batch is not checkpointed.

## One-time setup

1. Check the Zotero group's storage plan and space. The API key needs library
   read and write and file access.
2. In a top-level `Scraper automation` collection, create a **Computer
   Program** item titled `Adaptation Insights scraper checkpoints`, tagged
   exactly `scraperdoc:checkpoint`, with **Extra left empty**. Note its
   8-character key. The `doc:` in the tag makes the R puller skip it, and the
   prefix is outside the R uploader's six report namespaces.
3. Set `ZOTERO_API_KEY`, `ZOTERO_LIBRARY_ID`, `ZOTERO_LIBRARY_TYPE=groups` (as
   in R) and `ZOTERO_CHECKPOINT_ITEM_KEY`. Never store secrets in git.
4. Choose the seed: a folder with sibling `outputs/` and `downloads/`, sources
   separated under each. Review states at other paths must be copied into this
   layout on purpose, not merged blindly.
5. With all scrapers stopped, seed the empty item:

   ```powershell
   python rag-pipeline/scraper/run.py zotero_checkpoint save --initialize `
     --data-dir C:/path/to/seed `
     --archive rag-pipeline/scraper/data/seed-checkpoint.zip
   ```

   Use `pack` instead of `save --initialize` to build the ZIP without
   uploading. `--initialize` refuses an item that already has a checkpoint.
6. Test `zotero_checkpoint restore` into an empty folder.
7. In GitHub, add the secret `ZOTERO_API_KEY` and the variables
   `ZOTERO_LIBRARY_ID`, `ZOTERO_LIBRARY_TYPE` and `ZOTERO_CHECKPOINT_ITEM_KEY`.
   Only one repository should write to this item.
8. Copy the template into `.github/workflows/`, merge it with this code into
   the default branch, and run it by hand first (metadata-only is the default
   for manual runs). The schedule runs on Mondays at 03:23
   America/Los_Angeles.

## Limits

- Each checkpoint is a full copy of the corpus. The helper refuses archives of
  4 GB or more, Zotero's per-file limit. On 2026-10-29 the default
  `downloads/` held about 1.7 GB. Measure a full run before scheduling it, and
  keep an independent local backup.
- If the archive gets too big, store PDFs as individual attachments with a
  smaller state checkpoint, or use object storage.
- The checkpoint makes the scraper resumable. It does not create browsable
  Zotero report items. Publishing new reports to Zotero after screening still
  needs to be built, with explicit `(source, id)` to Zotero key mappings.
- IFAD has no collection in the R uploader; its files are backed up only.
- Known source failures (GEF 403, the GCF 410, IFAD TLS) are not fixed by
  scheduling. Download failures do not fail a source; read the summaries.
