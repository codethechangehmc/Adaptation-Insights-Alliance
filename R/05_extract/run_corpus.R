##############################################################################
# run_corpus.R — resumable driver for full-corpus Session-1 extraction.
#
# Builds the corpus-wide manifest (all in-scope files, same folders as
# build_doc_index.R), SKIPS documents already extracted (any session1_*.csv
# in the corpus output folder counts), and processes the remainder in chunks
# by invoking R/extract_verbatim.R per chunk — so an interrupted run loses at
# most one chunk and simply resumes on the next invocation.
#
# Outputs land in outputs/extraction/corpus/ (isolated from pilot/holdout).
#
# Usage:
#   Rscript R/run_corpus.R                    # everything not yet extracted
#   Rscript R/run_corpus.R --source=af        # one source only
#   Rscript R/run_corpus.R --family=afdb_pcr  # one document family only (several: a,b)
#   Rscript R/run_corpus.R --all               # ignore the screener, extract every in-scope-folder file
#   Rscript R/run_corpus.R --limit=20         # at most 20 documents this run
#   Rscript R/run_corpus.R --dry               # show plan + cost, extract nothing
#
# COST: ~USD 0.08-0.12 per document on gpt-5-mini (5 calls + occasional
# vision), so the full ~656-document corpus is roughly USD 55-75 run live.
# TODO (next iteration): OpenAI Batch API wiring would halve that (50%
# batch discount, 24h turnaround). It needs either ellmer >= 0.3
# (batch_chat_structured) or a request-JSONL builder; not wired yet to
# avoid upgrading ellmer under the validated 0.2.1 pipeline.
##############################################################################

suppressPackageStartupMessages({ library(readr) })

GL   <- "C:/Users/mlolita/OneDrive - CGIAR/WP2_Evidence Synthesis/Grey Literature"
DATA <- file.path(GL, "03_Documents")
full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- if (length(full)) normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", "..")) else getwd()
OUT  <- file.path(REPO, "outputs", "extraction", "corpus")
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)
RSCRIPT <- file.path(R.home("bin"), "Rscript.exe")
EXTRACT <- file.path(REPO, "R", "05_extract", "extract_verbatim.R")
CHUNK <- 8

CORPUS_DIRS <- c(
  worldbank = "Worldbank/Docs/2015_2026",
  gef       = "gef/Docs/evaluation_docs/2015_2026",
  gcf       = "gcf/Docs/evaluation_docs",
  afdb      = "afdb/Docs/2015_2026",
  af        = "af/Docs/evaluation_docs",
  cif       = "cif/Docs/evaluation_docs")

args <- commandArgs(trailingOnly = TRUE)
opt <- function(name, default = "") {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
SRC   <- opt("source")
LIMIT <- suppressWarnings(as.integer(opt("limit", "0")))
DRY   <- any(args == "--dry")

# project_code from the catalogue, not the filename.
# The analytical unit is the PROJECT, not the document (team decision,
# 17 Jul 2026), so two evaluations of the same project must carry the same
# code. doc_index.csv already joins every corpus filename to its catalogue
# row: 551 of 656 files resolve to a project id, and 35 of those share an id
# with another document - exactly the rows that must not be split. The
# remaining 105 (all 72 CIF files, 32 AfDB, 1 World Bank) keep source:filename,
# which is still unique and still a usable key.
pid_for <- local({
  f <- file.path(REPO, "catalogues", "doc_index.csv")
  idx <- if (file.exists(f))
    tryCatch(read.csv(f, stringsAsFactors = FALSE, colClasses = "character"),
             error = function(e) NULL) else NULL
  if (is.null(idx) || !all(c("filename", "project_id") %in% names(idx))) {
    cat("NOTE: doc_index.csv unusable; project_code falls back to filenames\n")
    function(fn) ""
  } else {
    key <- setNames(trimws(idx$project_id), trimws(idx$filename))
    function(fn) { v <- unname(key[fn]); if (is.na(v)) "" else v }
  }
})


# manifest of the whole corpus
# the document family from the census (02_dedup/doc_census.R): what the
# extractor routes on. Empty when the census has not seen the file.
fam_for <- local({
  f <- file.path(dirname(REPO), "04_Screening", "inputs", "decisions", "family_census.csv")
  lk <- if (file.exists(f)) {
    cen <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character")
    setNames(cen$family, cen$filename)
  } else character(0)
  function(fs) { v <- unname(lk[fs]); ifelse(is.na(v), "", v) }
})
# every scanned folder, not only the in-scope ones: a document judged in scope
# while sitting in to_screen (a hand-added Zotero file, say) must not be
# stranded there. Unjudged files count only from the in-scope folders.
source(file.path(REPO, "R", "00_shared", "paths.R"))
mf <- do.call(rbind, lapply(names(SCAN_DIRS), function(s) {
  if (nzchar(SRC) && s != SRC) return(NULL)
  do.call(rbind, lapply(SCAN_DIRS[[s]], function(rel) {
    d <- file.path(DATA, rel)
    fs <- list.files(d, pattern = "\\.(pdf|PDF)$")
    if (!length(fs)) return(NULL)
    pid <- vapply(fs, pid_for, character(1), USE.NAMES = FALSE)
    data.frame(project_code = ifelse(nzchar(pid), paste0(s, ":", pid),
                                                paste0(s, ":", fs)),
               pdf = file.path(d, fs), focus = "", family = fam_for(fs),
               in_scope_folder = rel %in% unname(CORPUS_DIRS),
               stringsAsFactors = FALSE)
  }))
}))
cat("files in the scanned folders:", nrow(mf), "\n")
# one family at a time: the census family is a column on every row, so a
# module can be tested on exactly the documents it was written for
FAM <- opt("family")
if (nzchar(FAM)) {
  mf <- mf[mf$family %in% strsplit(FAM, ",")[[1]], , drop = FALSE]
  message("family filter ", FAM, " -> ", nrow(mf), " documents")
}
if (nrow(mf)) print(table(family = ifelse(nzchar(mf$family), mf$family, "(not in census)")))
# only documents the screener judged in scope are extracted (verdict_ruled
# once screen_rules.R has run); files the screener has not seen still go
# through; --all ignores the verdicts
scr <- file.path(dirname(REPO), "04_Screening", "scope_screen.csv")
if (file.exists(scr) && !any(args == "--all")) {
  sv <- read.csv(scr, stringsAsFactors = FALSE, colClasses = "character")
  v  <- if ("verdict_ruled" %in% names(sv)) sv$verdict_ruled else sv$verdict
  judged <- paste(sv$source, sv$filename)
  ok  <- judged[v == "in scope"]
  key <- paste(sub(":.*$", "", mf$project_code), basename(mf$pdf))
  keep <- key %in% ok | (!(key %in% judged) & mf$in_scope_folder)
  message(sum(!keep), " documents left out (judged out of scope or unsure, or unjudged in a parked folder); --all to include them")
  mf <- mf[keep, , drop = FALSE]
}

# resume: skip documents already present in any session1 output here
done <- character(0)
for (f in list.files(OUT, pattern = "^session1_.*\\.csv$", full.names = TRUE)) {
  d <- tryCatch(read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL)
  if (!is.null(d) && "document" %in% names(d)) done <- c(done, d$document)
}
mf <- mf[!basename(mf$pdf) %in% unique(done), , drop = FALSE]
cat("already extracted:", length(unique(done)), "| remaining:", nrow(mf), "\n")
if (LIMIT > 0 && nrow(mf) > LIMIT) mf <- mf[seq_len(LIMIT), , drop = FALSE]
cat("this run:", nrow(mf), "documents in", ceiling(nrow(mf) / CHUNK),
    sprintf("chunks | est. cost ~USD %.2f | est. time ~%d min\n",
            nrow(mf) * 0.10, ceiling(nrow(mf) * 3.5)))
if (DRY || !nrow(mf)) { cat(if (DRY) "dry run - stopping.\n" else "nothing to do.\n"); quit(save = "no") }

# child Rscript inherits these (system2's env= is unreliable on Windows)
Sys.setenv(EXTRACT_OUT_DIR = OUT, EXTRACT_MODE = "pilot")
chunks <- split(seq_len(nrow(mf)), ceiling(seq_len(nrow(mf)) / CHUNK))
for (ci in seq_along(chunks)) {
  cm <- mf[chunks[[ci]], , drop = FALSE]
  tmp <- file.path(OUT, sprintf("chunk_manifest_%03d.csv", ci))
  write.csv(cm, tmp, row.names = FALSE)
  cat(sprintf("\n#### chunk %d/%d (%d docs) ####\n", ci, length(chunks), nrow(cm)))
  status <- system2(RSCRIPT, args = shQuote(c(EXTRACT, tmp)), stdout = "", stderr = "")
  if (!identical(status, 0L)) cat("chunk", ci, "exited with status", status,
                                  "- continuing (resume will retry missing docs)\n")
  unlink(tmp)
}
cat("\ncorpus run pass complete. Re-run this script to resume/verify nothing is missing.\n")
