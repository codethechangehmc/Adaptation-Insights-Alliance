# repair_scope_screen.R - one-time repair of 04_Screening/scope_screen.csv, 2026-10-02.
#
# Two defects, one cause. screen_scope.R writes 21 FIELDS including
# verdict_model at position 5, but the file's header predates that column (22
# columns: the original 20 plus verdict_ruled, rule_applied from screen_rules).
# write.table(append = TRUE) aligns by position, not name, so the 53 GCF rows
# appended on 2 Oct are shifted one column left from position 5 onward, and
# their verdict_ruled is empty, which hides them from the Zotero sync and the
# extraction driver (both read verdict_ruled unconditionally).
#
# Second, 56 of the 64 rows whose verdict_ruled differs from verdict carry no
# provenance: they are session rulings written directly into the column by the
# 2 Oct scope reviews. screen_rules.R recomputes verdict_ruled from scratch,
# so re-running it would erase them. This script harvests every ruled value
# the rules cannot reproduce into 04_Screening/inputs/decisions/scope_screen_overrides.csv (the
# designed home for decisions), so rules re-runs are safe forever after.
#
# Steps:
#   1. detect shifted rows by predicate, assert against the pre-registered
#      key list (audit/2026-10_completeness/gcf_shifted_keys.csv), realign
#   2. migrate the header to 23 canonical columns; verdict_model is
#      backfilled EMPTY for old rows (their verdicts already contain the year
#      rule; a non-empty verdict_model would re-apply the window to them)
#   3. replicate screen_rules logic, diff against current verdict_ruled,
#      append unexplained rulings to scope_screen_overrides.csv
#   4. write the repaired file + a pre-rules snapshot of verdict_ruled
# Then run:  Rscript R/03_screen/screen_rules.R
#
# Safe to re-run: if the header is already canonical it only re-checks
# invariants and re-harvests (idempotent, keyed appends).

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
OVR    <- file.path(SCREEN_DIR, "inputs", "decisions", "scope_screen_overrides.csv")
KEYS   <- file.path(REPO, "audit", "2026-10_completeness", "gcf_shifted_keys.csv")
SNAP   <- file.path(SCREEN_DIR, "inputs", "working", "snapshots", "ruled_snapshot_2026-10-02.csv")
BK     <- file.path(SCREEN_DIR, "inputs", "working", "snapshots", "scope_screen_2026-10-02.csv")
stopifnot(file.exists(SCREEN), file.exists(BK), file.exists(KEYS))

FIELDS <- c("source", "folder", "filename", "verdict", "verdict_model", "reason",
            "family", "family_rule", "family_agrees",
            "doc_type", "doc_kind_stated", "publication_year", "project_name",
            "language", "countries", "covers_several_projects",
            "adaptation_or_mitigation", "climate_risk_quote",
            "adaptation_quote", "chars", "note")
CANON <- c(FIELDS, "verdict_ruled", "rule_applied")

sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character",
               na.strings = NULL, check.names = FALSE, encoding = "UTF-8")
names(sc)[1] <- sub("^﻿", "", names(sc)[1])   # BOM guard
sc[is.na(sc)] <- ""
n0 <- nrow(sc)
cat("rows:", n0, "| columns:", ncol(sc), "\n")

## ---- 1. detect and realign the shifted rows --------------------------------
VW <- c("in scope", "out of scope", "unsure")
if (!"verdict_model" %in% names(sc)) {
  corrupt <- sc$reason %in% VW & grepl("^[0-9]+$", sc$note)
  exp <- read.csv(KEYS, stringsAsFactors = FALSE, colClasses = "character")
  got <- paste(sc$source[corrupt], sc$filename[corrupt])
  want <- paste(exp$source, exp$filename)
  stopifnot(all(sc$source[corrupt] == "gcf"),
            setequal(got, want), sum(corrupt) == nrow(exp))
  cat("shifted rows detected:", sum(corrupt), "(matches pre-registered keys)\n")

  sc$verdict_model <- ""
  # the shifted rows were written in FIELDS order against the old header, so
  # header column k holds the FIELDS value k+1 from position 5 on, and the
  # value written for note landed in verdict_ruled
  old <- sc[corrupt, ]
  sc$verdict_model[corrupt]            <- old$reason
  sc$reason[corrupt]                   <- old$family
  sc$family[corrupt]                   <- old$family_rule
  sc$family_rule[corrupt]              <- old$family_agrees
  sc$family_agrees[corrupt]            <- old$doc_type
  sc$doc_type[corrupt]                 <- old$doc_kind_stated
  sc$doc_kind_stated[corrupt]          <- old$publication_year
  sc$publication_year[corrupt]         <- old$project_name
  sc$project_name[corrupt]             <- old$language
  sc$language[corrupt]                 <- old$countries
  sc$countries[corrupt]                <- old$covers_several_projects
  sc$covers_several_projects[corrupt]  <- old$adaptation_or_mitigation
  sc$adaptation_or_mitigation[corrupt] <- old$climate_risk_quote
  sc$climate_risk_quote[corrupt]       <- old$adaptation_quote
  sc$adaptation_quote[corrupt]         <- old$chars
  sc$chars[corrupt]                    <- old$note
  sc$note[corrupt]                     <- old$verdict_ruled
  sc$verdict_ruled[corrupt]            <- ""
  sc$rule_applied[corrupt]             <- ""
  sc <- sc[, CANON]
} else {
  corrupt <- rep(FALSE, n0)
  cat("header already canonical; checking invariants only\n")
}
stopifnot(!any(sc$reason %in% VW & grepl("^[0-9]+$", sc$note)),
          all(grepl("^[0-9]*$", sc$chars)), nrow(sc) == n0,
          identical(names(sc), CANON))

## ---- 2. replicate the rules to find rulings they cannot reproduce ----------
replicate_rules <- function(sc) {
  YEAR_MIN <- 2015; YEAR_MAX <- 2025
  n <- nrow(sc)
  has <- nzchar(sc$verdict_model)
  y <- suppressWarnings(as.integer(sc$publication_year))
  base <- ifelse(has, sc$verdict_model, sc$verdict)
  out_year <- has & !is.na(y) & (y < YEAR_MIN | y > YEAR_MAX)
  no_year  <- has & is.na(y) & base == "in scope"
  verdict <- ifelse(out_year, "out of scope", ifelse(no_year, "unsure", base))
  source(file.path(REPO, "R", "00_shared", "doc_families.R"), local = TRUE)
  for (i in seq_len(n)) {
    if (verdict[i] != "in scope") next
    fam <- if (nzchar(sc$family[i])) sc$family[i] else "generic"
    info <- family_info(fam)
    if (sc$adaptation_or_mitigation[i] %in% c("mitigation", "neither")) {
      verdict[i] <- "out of scope"
    } else if (nchar(trimws(sc$climate_risk_quote[i])) < 12) {
      verdict[i] <- "unsure"
    } else if (sc$covers_several_projects[i] == "yes" &&
               (isTRUE(info$multi) || fam == "programme_evaluation")) {
      verdict[i] <- "unsure"
    }
  }
  verdict[grepl("progress_reports", sc$folder, fixed = TRUE)] <- "unsure"
  if (file.exists(OVR)) {
    ov <- read.csv(OVR, stringsAsFactors = FALSE, colClasses = "character")
    ov <- ov[ov$verdict %in% VW, ]
    hit <- match(paste(ov$source, ov$filename), paste(sc$source, sc$filename))
    for (j in which(!is.na(hit))) verdict[hit[j]] <- ov$verdict[j]
  }
  verdict
}
expected <- replicate_rules(sc)
hand <- which(!corrupt & nzchar(sc$verdict_ruled) & sc$verdict_ruled != expected)
cat("rulings the rules cannot reproduce:", length(hand), "\n")

if (length(hand)) {
  ov <- read.csv(OVR, stringsAsFactors = FALSE, colClasses = "character")
  new <- data.frame(
    source   = sc$source[hand],
    filename = sc$filename[hand],
    verdict  = sc$verdict_ruled[hand],
    note     = ifelse(nzchar(sc$rule_applied[hand]),
                      paste("carried from scope_screen.csv;", sc$rule_applied[hand]),
                      "carried from scope_screen.csv; decided in the 2 Oct 2026 scope reviews (review/scope_review_*_2026-10-02.csv)"),
    by       = "Claude session reviews, Sep-Oct 2026",
    stringsAsFactors = FALSE)
  # a key already in the overrides file with a different verdict is an OLDER
  # deferral (18 Sep "for Lucy to decide") that the 2 Oct session reviews
  # superseded: update it in place rather than keeping the stale value
  at <- match(paste(new$source, new$filename), paste(ov$source, ov$filename))
  upd <- which(!is.na(at))
  if (length(upd)) {
    ov$verdict[at[upd]] <- new$verdict[upd]
    ov$note[at[upd]]    <- paste("superseded 18 Sep deferral;", new$note[upd])
    ov$by[at[upd]]      <- new$by[upd]
    cat("updated", length(upd), "stale overrides in place\n")
  }
  new <- new[is.na(at), ]
  write.csv(rbind(ov[, names(new)], new), OVR, row.names = FALSE, fileEncoding = "UTF-8")
  if (nrow(new)) cat("appended", nrow(new), "rulings to scope_screen_overrides.csv\n")
  stopifnot(identical(replicate_rules(sc)[hand], sc$verdict_ruled[hand]))
  cat("replication check: every harvested ruling is now reproduced by the rules\n")
}

## ---- 3. write ----------------------------------------------------------------
write.csv(data.frame(source = sc$source, filename = sc$filename,
                     verdict_ruled = sc$verdict_ruled),
          SNAP, row.names = FALSE, fileEncoding = "UTF-8")
write.csv(sc, SCREEN, row.names = FALSE, na = "", fileEncoding = "UTF-8")
cat("written:", SCREEN, "-", nrow(sc), "rows x", ncol(sc), "columns\n")
cat("snapshot:", SNAP, "\nnow run:  Rscript R/03_screen/screen_rules.R\n")
