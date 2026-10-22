# reconcile_sources.R - the Phase 3 completeness gate.
#
# The campaign's guarantee is that our holdings match what each organisation's
# website publishes, and that every difference is a recorded decision rather
# than an accident. That guarantee is only real if it is re-runnable, so this
# script reconciles the five views of the corpus against each other:
#
#   site inventory  = catalogues/<src>/attestation.csv  (what the site lists)
#   disk            = 03_Documents/<folders in SCAN_DIRS>
#   download log    = outputs/download_log.csv (+ shards)
#   screening       = 04_Screening/scope_screen.csv
#   doc index       = catalogues/doc_index.csv (in-scope files only)
#
# A difference is acceptable ONLY if the ledger gives it a disposition. The
# gate fails on: blank dispositions, ledger rows claiming a file that is not
# on disk, disk files no ledger row accounts for, screened rows whose file has
# vanished, and OneDrive sync conflict copies.
#
#   Rscript R/08_quality/reconcile_sources.R            # all sources
#   Rscript R/08_quality/reconcile_sources.R --source=gef

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

args <- commandArgs(trailingOnly = TRUE)
opt <- function(k, d = NULL) {
  hit <- grep(paste0("^--", k, "="), args, value = TRUE)
  if (length(hit)) sub(paste0("^--", k, "="), "", hit[1]) else d
}
only <- opt("source")
SOURCES <- names(SCAN_DIRS)
if (!is.null(only)) SOURCES <- intersect(SOURCES, strsplit(only, ",")[[1]])

SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""

LOG <- file.path(REPO, "outputs", "download_log.csv")
logs <- list()
for (p in c(LOG, Sys.glob(file.path(REPO, "outputs", "download_log_*.csv"))))
  if (file.exists(p)) logs[[p]] <- read.csv(p, stringsAsFactors = FALSE, colClasses = "character")
dl <- if (length(logs)) do.call(rbind, lapply(logs, function(d) d[, intersect(names(d),
        c("timestamp","source","project_code","doc_type","title","url","filepath","status","notes"))])) else NULL

IDX <- file.path(REPO, "catalogues", "doc_index.csv")
idx <- if (file.exists(IDX)) read.csv(IDX, stringsAsFactors = FALSE, colClasses = "character") else NULL

fails <- 0L; warns <- 0L
bad  <- function(...) { fails <<- fails + 1L; cat("  FAIL ", ..., "\n", sep = "") }
warn <- function(...) { warns <<- warns + 1L; cat("  warn ", ..., "\n", sep = "") }
good <- function(...) cat("  ok   ", ..., "\n", sep = "")

DISPOSITIONS <- c("fetched", "already_held", "failed_download", "out_by_type",
                  "duplicate", "parked_progress", "excluded_desk_review",
                  "held_pending_window_decision")
HELD <- c("fetched", "already_held")   # dispositions that assert a local file

cat("\n=== corpus reconciliation,", format(Sys.time(), "%Y-%m-%d %H:%M"), "===\n")

# OneDrive sync conflict copies anywhere in the tree are a silent data hazard
conflicts <- c(Sys.glob(file.path(DOCS_ROOT, "**", "*-DESKTOP-*")),
               Sys.glob(file.path(VOCAB_DIR, "*-DESKTOP-*")),
               Sys.glob(file.path(REPO, "catalogues", "**", "*-DESKTOP-*")))
cat("\n[global]\n")
if (length(conflicts)) bad("OneDrive conflict copies present: ", length(conflicts),
                           " e.g. ", basename(conflicts[1]))  else good("no OneDrive conflict copies")

summary_rows <- list()

for (src in SOURCES) {
  cat("\n[", src, "]\n", sep = "")

  ## disk ----------------------------------------------------------------
  disk <- character(0); disk_folder <- character(0)
  for (d in SCAN_DIRS[[src]]) {
    p <- file.path(DOCS_ROOT, d)
    if (!dir.exists(p)) next
    f <- list.files(p, pattern = "\\.(pdf|PDF|docx?|DOCX?|xlsx?|zip)$")
    disk <- c(disk, f); disk_folder <- c(disk_folder, rep(d, length(f)))
  }
  names(disk_folder) <- disk

  ## ledger --------------------------------------------------------------
  lp <- file.path(REPO, "catalogues", src, "attestation.csv")
  led <- if (file.exists(lp)) read.csv(lp, stringsAsFactors = FALSE, colClasses = "character") else NULL
  if (is.null(led)) {
    warn("no attestation ledger yet (catalogues/", src, "/attestation.csv)")
  } else {
    led[is.na(led)] <- ""
    blank <- !led$disposition %in% DISPOSITIONS
    if (any(blank)) bad("ledger rows with a blank or unknown disposition: ", sum(blank))
    else good("ledger: ", nrow(led), " rows, every disposition in the vocabulary")

    claimed <- led$local_filename[led$disposition %in% HELD]
    claimed <- claimed[nzchar(claimed)]
    missing <- setdiff(basename(claimed), disk)
    if (length(missing)) bad("ledger claims ", length(missing),
                             " file(s) not on disk, e.g. ", missing[1])
    else if (length(claimed)) good("every held/fetched ledger row has its file on disk (",
                                   length(claimed), ")")

    unaccounted <- setdiff(disk, basename(claimed))
    if (length(unaccounted))
      warn(length(unaccounted), " file(s) on disk with no held ledger row, e.g. ",
           unaccounted[1], " (expected while a source is mid-campaign)")
    else good("every file on disk is accounted for in the ledger")
  }

  ## screening -----------------------------------------------------------
  s <- sc[sc$source == src, ]
  gone <- setdiff(s$filename, disk)
  if (length(gone)) bad("screened rows whose file is gone: ", length(gone),
                        " e.g. ", gone[1])
  else good("every screened row still has its file (", nrow(s), " rows)")
  # Files in parked folders are a recorded decision, not a screening backlog:
  # the progress-document family is an open question for the team, and
  # proposal_stage holds documents excluded by type. Count them separately so
  # the backlog figure means what it says.
  PARKED_RE <- "progress_reports|proposal_stage|tracking_tools"
  unscreened <- setdiff(disk, s$filename)
  parked <- unscreened[grepl(PARKED_RE, disk_folder[unscreened])]
  todo   <- setdiff(unscreened, parked)
  cat("       unscreened: ", length(todo), " to screen + ", length(parked),
      " parked by design\n", sep = "")

  ## download log --------------------------------------------------------
  if (!is.null(dl)) {
    d2 <- dl[dl$source == src, ]
    okd <- sum(d2$status == "success")
    af  <- sum(d2$status == "assertion_failed")
    cat("       download log: ", nrow(d2), " attempts, ", okd, " success, ",
        sum(d2$status == "failed"), " failed", if (af) paste0(", ", af, " ASSERTION FAILURES") else "",
        "\n", sep = "")
    if (af) warn("assertion failures logged for ", src, " - inspect before trusting its ledger")
  }

  ## doc index -----------------------------------------------------------
  if (!is.null(idx)) {
    in_scope <- s$filename[s$verdict_ruled == "in scope"]
    ix <- idx$filename[idx$source == src]
    miss_ix <- setdiff(in_scope, ix)
    if (length(miss_ix))
      warn(length(miss_ix), " in-scope file(s) missing from doc_index (rebuild after filing)")
    else good("doc_index covers every in-scope file (", length(in_scope), ")")
  }

  summary_rows[[src]] <- data.frame(
    source = src, disk = length(disk), screened = nrow(s),
    in_scope = sum(s$verdict_ruled == "in scope"),
    out = sum(s$verdict_ruled == "out of scope"),
    unsure = sum(s$verdict_ruled == "unsure"),
    to_screen = length(todo), parked = length(parked),
    ledger = if (is.null(led)) NA_integer_ else nrow(led),
    stringsAsFactors = FALSE)
}

cat("\n=== totals ===\n")
tot <- do.call(rbind, summary_rows)
print(tot, row.names = FALSE)
cat("\ncorpus:", sum(tot$disk), "files on disk |", sum(tot$screened), "screened |",
    sum(tot$in_scope), "in scope |", sum(tot$unsure), "unsure |",
    sum(tot$to_screen), "awaiting screening |", sum(tot$parked), "parked by design\n")

cat("\n=== gate ===\n")
cat(if (fails == 0) "PASS" else "FAIL", " - ", fails, " failure(s), ", warns, " warning(s)\n", sep = "")
if (fails > 0) quit(status = 1)
