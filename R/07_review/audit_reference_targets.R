##############################################################################
# audit_reference_targets.R — find figures the REFERENCE records as results
# that the document only ever states as a target.
#
# Two were found by hand on 15 Sep 2026 while reading the documents against the
# extractions, in ten holdout projects:
#
#   H003  reference has 2.825. Every occurrence in the terminal evaluation is
#         "the project sought to install four mini grids of a combined capacity
#          of up to 2.825 MW" - an Output statement and a "Project Target"
#         column. No achieved figure exists anywhere in the document. Confirmed.
#   H005  752 was suspected of being the lowland-development target rather than
#         the 625.08 ha actual. This audit does NOT confirm it: the report
#         states lowland development twice with different figures ("625.08 Ha /
#         752 Ha (83%)" and "752.1 ha / 767.6 ha, i.e. 98%"), so 752 also
#         appears as an achievement. Left for a person to settle.
#
# The protocol is explicit that a target without an actual is not a result, so
# each of these penalises the pipeline for behaving correctly. Two in ten means
# there are probably more, and a person has to look - this script only says
# where to look.
#
# It reads every figure in a reference's results_set, finds where that figure
# appears in the project's own PDF, and reports what kind of sentence surrounds
# it. A figure that never once appears near achievement wording, and does
# appear near target wording, is flagged.
#
#   Rscript R/07_review/audit_reference_targets.R
#   -> 05_Extraction_Results/gold_pilot/reference_target_check.csv
##############################################################################

suppressPackageStartupMessages({ library(pdftools) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."),
                      mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "rf_table.R"))

## Where a resolved indicator table exists it settles the question outright: a
## figure sitting under ACTUAL ACHIEVED is an achievement whatever the prose
## around it says, and one that only ever appears under baseline or target is
## not. Text proximity is the fallback for documents with no such table (AfDB
## reports results in prose; the GEF table has no actual column at all).
digits <- function(x) gsub("[^0-9.]", "", x)
table_values <- function(pdf) {
  rows <- tryCatch(rf_tables(pdf, seq_len(200), max_rows = 600),
                   error = function(e) character(0))
  grab <- function(pat) {
    m <- regmatches(rows, regexpr(pat, rows))
    unique(digits(sub(pat, "", m)))
  }
  list(rows = length(rows),
       actual = grab("ACTUAL ACHIEVED: [0-9,. ]+"),
       plan   = unique(c(grab("baseline: [0-9,. ]+"), grab("target: [0-9,. ]+"))))
}

TARGETY <- paste0("target|cible|objectif|expected|planned|pr.vu|attendu|",
                  "sought to|aims? to|aimed to|up to|will be|to be achieved|",
                  "projected|forecast|envisaged")
ACTUALY <- paste0("achieved|actual|reached|completed|delivered|realis|realiz|",
                  "r.alis|atteint|obtenu|at completion|resulted in|benefited|",
                  "were trained|have been|was recorded")

rd <- function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character",
                check.names = FALSE); d[is.na(d)] <- ""; d
}

# a figure may be printed 42270, 42,270, 42 270 or "4.7 million"
forms <- function(v) {
  v <- trimws(v)
  n <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", v)))
  out <- v
  if (!is.na(n) && n == round(n)) {
    d <- format(n, scientific = FALSE, trim = TRUE)
    out <- c(out, d, prettyNum(d, big.mark = ","), prettyNum(d, big.mark = " "))
    if (n >= 1e6 && n %% 1e5 == 0)
      out <- c(out, paste0(format(n / 1e6, trim = TRUE), " million"))
  }
  unique(out[nchar(out) >= 2])
}

read_pdf <- function(p) {
  t <- tryCatch(pdf_text(p), error = function(e) NULL)
  if (!is.null(t)) return(paste(t, collapse = "\n"))
  tmp <- file.path(tempdir(), paste0("a", sample.int(1e6, 1), ".pdf"))
  ok <- tryCatch(file.copy(p, tmp), error = function(e) FALSE)
  if (!isTRUE(ok)) return("")
  t <- tryCatch(pdf_text(tmp), error = function(e) NULL)
  if (is.null(t)) "" else paste(t, collapse = "\n")
}

audit_set <- function(ref_csv, manifest_csv, label) {
  ref <- rd(ref_csv); man <- rd(manifest_csv)
  out <- list()
  for (i in seq_len(nrow(ref))) {
    pc  <- ref$project_code[i]
    pdf <- man$pdf[man$project_code == pc]
    if (!length(pdf) || !file.exists(pdf[1])) { cat("  no pdf for", pc, "\n"); next }
    txt <- read_pdf(pdf[1])
    if (!nzchar(txt)) { cat("  unreadable pdf for", pc, "\n"); next }
    low <- tolower(gsub("[\r\n]+", " ", txt))
    tv  <- table_values(pdf[1])
    vals <- trimws(strsplit(ref$results_set[i], "||", fixed = TRUE)[[1]])
    vals <- unique(vals[nzchar(vals)])
    for (v in vals) {
      hits <- 0; tgt <- 0; act <- 0; sample_txt <- ""
      for (f in forms(v)) {
        pos <- gregexpr(tolower(f), low, fixed = TRUE)[[1]]
        if (pos[1] == -1) next
        for (k in pos) {
          hits <- hits + 1
          ctx <- substr(low, max(1, k - 170), min(nchar(low), k + 130))
          if (grepl(TARGETY, ctx)) tgt <- tgt + 1
          if (grepl(ACTUALY, ctx)) act <- act + 1
          if (!nzchar(sample_txt)) sample_txt <- gsub("\\s+", " ", ctx)
        }
      }
      dv <- digits(v)
      in_actual <- nzchar(dv) && dv %in% tv$actual
      in_plan   <- nzchar(dv) && dv %in% tv$plan
      verdict <-
        if (in_actual) "in an ACTUAL column - fine"
        else if (in_plan) "TARGET/BASELINE COLUMN - review"
        else if (hits == 0) "NOT FOUND in document"
        else if (tv$rows > 0) "not in any table; prose only"
        else if (act == 0 && tgt > 0) "target wording only - review"
        else if (act == 0 && tgt == 0) "no target/actual wording nearby"
        else "actual wording present"
      out[[length(out) + 1L]] <- data.frame(
        set = label, project_code = pc, value = v, occurrences = hits,
        near_target = tgt, near_actual = act, verdict = verdict,
        context = substr(sample_txt, 1, 300), stringsAsFactors = FALSE)
    }
    cat(sprintf("  %-6s %2d figure(s) checked\n", pc, length(vals)))
  }
  if (length(out)) do.call(rbind, out) else NULL
}

cat("gold set\n")
g <- audit_set(file.path(REPO, "catalogues", "gold_v1_general.csv"),
               file.path(REPO, "outputs", "extraction", "pilot_manifest.csv"), "gold")
cat("holdout\n")
h <- audit_set(file.path(REPO, "catalogues", "holdout_reference.csv"),
               file.path(REPO, "outputs", "extraction", "holdout", "holdout_manifest.csv"),
               "holdout")
res <- rbind(g, h)
if (is.null(res)) { cat("nothing to report\n"); quit(save = "no") }

dir.create(VOCAB_DIR, recursive = TRUE, showWarnings = FALSE)
out <- file.path(REPO, "outputs", "extraction", "reference_target_check.csv")
write.csv(res, out, row.names = FALSE, na = "")
cat("\nwritten:", out, "\n")
cat("figures checked:", nrow(res), "\n")
print(table(res$verdict))
flag <- res[grepl("review", res$verdict), ]
if (nrow(flag)) {
  cat("\nflagged (", nrow(flag), "):\n", sep = "")
  for (i in seq_len(nrow(flag)))
    cat(sprintf("  %-8s %-12s %s\n", flag$project_code[i], flag$value[i],
                substr(flag$context[i], 1, 100)))
}
