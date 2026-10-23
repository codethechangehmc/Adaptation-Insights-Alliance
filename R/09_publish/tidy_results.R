# tidy_results.R - move superseded machine output out of 05_Extraction_Results
# into 99_Archive, so the folder shows current material.
#
# Nothing is deleted. Every file is moved, and every move is written to a
# manifest in the archive folder, so the tidy can be undone.
#
# What is moved, and why only this:
#
#   scores/{score,align}_locations_gpt-5-*_<timestamp>_vs_*.csv
#       48 dated run outputs from September, superseded by
#       gold_pilot/location_records_latest.xlsx.
#   scores/previous_runs/
#       already an archive by name; no script refers to it.
#   04_Screening/inputs/working/scope_screen_parts/  EXCEPT reverify_*.csv
#       screening shards, merged into 04_Screening/scope_screen.csv, which is newer.
#       The reverify_* shards stay: build_reverify_list.R globs them.
#   review/adjudication_batches/, review/adjudication_results/
#       the re-verification campaign, finished. Its outcome lives in
#       review/scope_reverify_adjudication.csv. build_adjudication_batches.R
#       writes the batches folder and nothing reads either one.
#
# What is deliberately NOT moved, having been checked:
#   review/backup/            repair_scope_screen.R reads two files from it
#   review/headline_results_survey/   a finished survey, cited by the pilot READMEs
#   everything a script names under RESULTS_DIR, VOCAB_DIR or SCORES_DIR
#
#   Rscript R/09_publish/tidy_results.R --dry
#   Rscript R/09_publish/tidy_results.R

suppressPackageStartupMessages({ library(cli) })

DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

DEST <- file.path(ARCHIVE_DIR, "2026-10_extraction_results")

# ---- the set to move -------------------------------------------------------
pick <- character(0)

sc <- file.path(RESULTS_DIR, "scores")
pick <- c(pick, list.files(sc, pattern = "^(score|align)_locations_gpt-5-[a-z]+_[0-9]{8}_[0-9]{4}.*\\.csv$",
                           full.names = TRUE))
pr <- file.path(sc, "previous_runs")
if (dir.exists(pr)) pick <- c(pick, list.files(pr, full.names = TRUE, recursive = TRUE))

sp <- file.path(SCREEN_DIR, "inputs", "working", "scope_screen_parts")
if (dir.exists(sp)) {
  f <- list.files(sp, full.names = TRUE)
  pick <- c(pick, f[!grepl("^reverify_", basename(f))])   # build_reverify_list.R globs these
}
for (d in c("adjudication_batches", "adjudication_results")) {
  p <- file.path(VOCAB_DIR, d)
  if (dir.exists(p)) pick <- c(pick, list.files(p, full.names = TRUE, recursive = TRUE))
}

pick <- unique(normalizePath(pick, winslash = "/", mustWork = FALSE))
pick <- pick[file.exists(pick)]

# ---- guard: never move something a script names ----------------------------
# A last check against the R sources, so a file that gained a reader since
# this script was written is left where it is rather than quietly archived.
src <- unlist(lapply(list.files(file.path(REPO, "R"), "\\.R$", recursive = TRUE, full.names = TRUE),
                     function(f) readLines(f, warn = FALSE)))
src <- paste(src, collapse = "\n")
named <- vapply(basename(pick), function(b) grepl(b, src, fixed = TRUE), logical(1))
if (any(named)) {
  cli_alert_warning("left in place, named in an R script: {sum(named)}")
  for (b in basename(pick)[named]) cli_alert_info("  {b}")
  pick <- pick[!named]
}

base <- normalizePath(RESULTS_DIR, winslash = "/", mustWork = TRUE)
rel  <- sub(paste0("^", gsub("([.|()\\^{}+$*?\\[\\]])", "\\\\\\1", base), "/"), "", pick)

cli_h1("Tidy 05_Extraction_Results")
cli_alert_info("to move: {length(pick)} files")
cli_alert_info("destination: {DEST}")

if (!length(pick)) { cli_alert_success("nothing to do"); quit(save = "no") }

man <- data.frame(from = rel, bytes = file.size(pick),
                  modified = format(file.mtime(pick), "%Y-%m-%d %H:%M"),
                  stringsAsFactors = FALSE)
grp <- sub("/.*$", "", ifelse(grepl("/", rel), rel, "."))
print(table(dirname(rel)))

if (DRY) {
  cli_alert_info("dry run, nothing moved")
  quit(save = "no")
}

moved <- 0; failed <- 0
for (i in seq_along(pick)) {
  to <- file.path(DEST, rel[i])
  dir.create(dirname(to), recursive = TRUE, showWarnings = FALSE)
  if (file.exists(to)) { cli_alert_warning("exists, skipped: {rel[i]}"); failed <- failed + 1; next }
  ok <- file.rename(pick[i], to)
  if (!ok) {                      # different volume, or a lock
    ok <- file.copy(pick[i], to) && file.remove(pick[i])
  }
  if (ok) moved <- moved + 1 else { cli_alert_danger("could not move: {rel[i]}"); failed <- failed + 1 }
}
man$moved <- file.exists(file.path(DEST, rel))
write.csv(man, file.path(DEST, "MANIFEST.csv"), row.names = FALSE)
writeLines(c(
  "# Archived from 05_Extraction_Results",
  "",
  paste("Moved", moved, "files on", format(Sys.Date(), "%d %B %Y"), "by R/09_publish/tidy_results.R."),
  "",
  "Dated run outputs and finished working sets, kept for audit. MANIFEST.csv",
  "lists every file with the path it came from, so the move can be undone.",
  "Nothing here is read by the pipeline."),
  file.path(DEST, "README.md"))

cli_h2("moved {moved}, left {failed}")
cli_alert_info("manifest: {file.path(DEST, 'MANIFEST.csv')}")
