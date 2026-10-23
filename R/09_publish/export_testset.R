# export_testset.R - the pilot test set as one tidy folder for collaborators.
#
# Two things, side by side, which is what makes it usable:
#   reference_*   the answers for the ten gold projects and the ten holdout
#                 documents
#   pipeline_*    what this pipeline extracted for the same documents
# Scoring is then reference vs pipeline, and anyone can see both halves.
#
# Only one copy of each answer table is published here. The reading-based
# 308-row location file stays on OneDrive: it is a separate AI-read coverage
# benchmark, not an answer key, and having two files called "the gold
# locations" is how people end up scoring against the wrong one.
#
#   Rscript R/09_publish/export_testset.R

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

CAT <- file.path(REPO, "catalogues")
OUT <- file.path(REPO, "test_set")
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

cp <- function(from, to, what) {
  if (!file.exists(from)) { cat("  MISSING:", basename(from), "\n"); return(invisible(FALSE)) }
  d <- read.csv(from, stringsAsFactors = FALSE, colClasses = "character")
  d[is.na(d)] <- ""
  write.csv(d, file.path(OUT, to), row.names = FALSE, fileEncoding = "UTF-8")
  cat(sprintf("  %-34s %4d rows  %2d cols   %s\n", to, nrow(d), ncol(d), what))
  invisible(TRUE)
}

cat("reference answers\n")
cp(file.path(CAT, "gold_v1_general.csv"),    "reference_gold_general.csv",   "ten gold projects, project level")
cp(file.path(CAT, "gold_v1_locations.csv"),  "reference_gold_locations.csv", "ten gold projects, location level")
cp(file.path(CAT, "gold_v1_results.csv"),    "reference_gold_results.csv",   "result values with metric, unit, page")
cp(file.path(CAT, "holdout_reference.csv"),  "reference_holdout_general.csv","ten holdout documents, project level")

## ---- what the pipeline extracted for the same documents --------------------
# The published workbooks are the stable copy; the run folders under outputs/
# are working files and are not in the repo.
cat("\npipeline extraction for the same documents\n")
suppressMessages(library(openxlsx))
# gold_pilot now holds plain CSVs, one folder for the human extraction and
# one for the machine's, instead of multi-sheet workbooks nobody could read
# without opening Excel.
AI_GEN  <- file.path(PILOT_RESULTS, "ai", "gold_general.csv")
AI_HOLD <- file.path(PILOT_RESULTS, "ai", "holdout_general.csv")
AI_LOC  <- file.path(PILOT_RESULTS, "ai", "gold_locations.csv")

grab <- function(xlsx, sheet, to, what) {
  if (!file.exists(xlsx)) { cat("  MISSING workbook:", basename(xlsx), "\n"); return(invisible(FALSE)) }
  sheets <- getSheetNames(xlsx)
  if (!sheet %in% sheets) { cat("  no sheet", sheet, "in", basename(xlsx), "\n"); return(invisible(FALSE)) }
  d <- read.xlsx(xlsx, sheet = sheet)
  d[] <- lapply(d, as.character); d[is.na(d)] <- ""
  write.csv(d, file.path(OUT, to), row.names = FALSE, fileEncoding = "UTF-8")
  cat(sprintf("  %-34s %4d rows  %2d cols   %s\n", to, nrow(d), ncol(d), what))
  invisible(TRUE)
}
# both sets in one file, matching reference_general.csv
rdcsv <- function(p) { d <- read.csv(p, stringsAsFactors = FALSE, colClasses = "character"); d[is.na(d)] <- ""; d }
gl <- rdcsv(AI_GEN)
ho <- rdcsv(AI_HOLD)
for (col in setdiff(names(gl), names(ho))) ho[[col]] <- ""
ho <- ho[, names(gl), drop = FALSE]
gl$set <- "gold"; ho$set <- "holdout"
pg <- rbind(gl, ho); pg[is.na(pg)] <- ""
pg <- pg[, c("set", setdiff(names(pg), "set"))]
write.csv(pg, file.path(OUT, "pipeline_general.csv"), row.names = FALSE, fileEncoding = "UTF-8")
cat(sprintf("  %-34s %4d rows  %2d cols   %s
", "pipeline_general.csv",
            nrow(pg), ncol(pg), "pipeline output, both sets"))
cp(AI_LOC, "pipeline_gold_locations.csv", "pipeline output, gold, location level")

## ---- one reference file, both sets, with a column saying which ------------
# Gold and holdout hold the same kind of record. They differ only in how they
# have been used: the prompts were developed against the gold documents, and
# never against the holdout. One file is easier to load; the `set` column
# keeps the distinction, which is what the measurement depends on. Scores for
# the two sets are reported separately, because a single number mixing them
# describes neither.
gg <- file.path(OUT, "reference_gold_general.csv")
hh <- file.path(OUT, "reference_holdout_general.csv")
if (file.exists(gg) && file.exists(hh)) {
  a <- read.csv(gg, stringsAsFactors = FALSE, colClasses = "character")
  b <- read.csv(hh, stringsAsFactors = FALSE, colClasses = "character")
  a[is.na(a)] <- ""; b[is.na(b)] <- ""
  for (col in setdiff(names(a), names(b))) b[[col]] <- ""   # GESI_project
  b <- b[, names(a), drop = FALSE]
  a$set <- "gold"; b$set <- "holdout"
  a$tuned_on <- "yes"; b$tuned_on <- "no"
  # Who wrote the answer. The gold ten were extracted by hand; the holdout ten
  # are an independent reading, made before any pipeline output existed and not
  # produced by the pipeline. Without this column the file looks like one
  # hand-made reference, which is what the README used to claim.
  a$reference_made_by <- "hand extraction"
  b$reference_made_by <- "independent reading, not the pipeline"
  both <- rbind(a, b)
  both <- both[, c("set", "tuned_on", "reference_made_by",
                   setdiff(names(both), c("set", "tuned_on", "reference_made_by")))]
  write.csv(both, file.path(OUT, "reference_general.csv"),
            row.names = FALSE, fileEncoding = "UTF-8")
  cat(sprintf("
  %-34s %4d rows  %2d cols   both sets in one file
",
              "reference_general.csv", nrow(both), ncol(both)))
  file.remove(gg, hh)
  cat("  (the two separate files are replaced by it)
")
}

## ---- which document each project code refers to -----------------------------
man <- file.path(REPO, "outputs", "extraction", "pilot_manifest.csv")
hman <- file.path(REPO, "outputs", "extraction", "holdout", "holdout_manifest.csv")
rows <- list()
for (f in c(man, hman)) {
  if (!file.exists(f)) next
  d <- read.csv(f, stringsAsFactors = FALSE)
  rows[[length(rows) + 1]] <- data.frame(
    code = d$project_code,
    document = basename(d$pdf),
    focus = if ("focus" %in% names(d)) d$focus else "",
    set = if (grepl("holdout", f)) "holdout" else "gold",
    stringsAsFactors = FALSE)
}
if (length(rows)) {
  m <- do.call(rbind, rows)
  write.csv(m, file.path(OUT, "documents.csv"), row.names = FALSE, fileEncoding = "UTF-8")
  cat(sprintf("\n  %-34s %4d rows             which PDF each code refers to\n", "documents.csv", nrow(m)))
}
cat("\nwritten to:", OUT, "\n")
