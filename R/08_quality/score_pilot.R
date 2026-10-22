##############################################################################
# score_pilot.R — field-level agreement between the two-session pipeline
# output and the CORRECTED gold standard (catalogues/gold_v1_general.csv,
# derived from the 2026-09-08 gold-standard audit).
#
# Gold cells may hold several acceptable alternates separated by ' || '
# (the audit found genuinely defensible variants, e.g. counting rules).
# Verdicts: match | mismatch | candidate (pipeline flagged a vocab gap /
# unregistered actor rather than forcing a value) | both_empty.
# Results are scored as a SET: each filled result slot counts as a hit if
# its value matches any value in the gold results_set.
#
# Usage: Rscript R/score_pilot.R [harmonized_diagnostics_*.csv]
##############################################################################

suppressPackageStartupMessages({ library(readr); library(dplyr) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- if (length(full)) normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", "..")) else getwd()
OUT_DIR <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction"))

args <- commandArgs(trailingOnly = TRUE)
hfile <- if (length(args)) args[1] else {
  # Since 30 Sep 2026 harmonise writes ONE file carrying the template columns
  # and the evidence together, so the scorer reads that. Older runs left a
  # separate harmonized_diagnostics_* twin; fall back to it so historical runs
  # still score.
  f <- list.files(OUT_DIR, pattern = "^harmonized_.*\\.csv$", full.names = TRUE)
  f <- f[!grepl("^harmonized_diagnostics_", basename(f))]
  if (!length(f))
    f <- list.files(OUT_DIR, pattern = "^harmonized_diagnostics_.*\\.csv$", full.names = TRUE)
  stopifnot("no harmonized_*.csv found" = length(f) > 0)
  f[which.max(file.mtime(f))]
}
cat("scoring:", hfile, "\n")
h <- read.csv(hfile, check.names = FALSE, stringsAsFactors = FALSE, colClasses = "character"); h[is.na(h)] <- ""   # text, so 33000000 never prints as 3.3e+07
gfile <- if (length(args) >= 2) args[2] else file.path(REPO, "catalogues", "gold_v1_general.csv")
cat("reference:", gfile, "\n")
g <- read.csv(gfile, check.names = FALSE, stringsAsFactors = FALSE,
              colClasses = "character"); g[is.na(g)] <- ""

nrm <- function(x) {
  x <- gsub("programme", "program", tolower(x))   # UK/US spelling never decides
  trimws(gsub("\\s+", " ", gsub("[^a-z0-9 .>%/+-]", " ", x)))
}
num_one <- function(x) {
  x <- tolower(gsub(",", "", as.character(x)))
  v <- suppressWarnings(as.numeric(x))            # handles 9.1e+07 round-trips
  if (!is.na(v)) {
    if (v >= 1000) v <- round(v)                  # decimals never decide a match
    return(format(v, scientific = FALSE, trim = TRUE))
  }
  x <- gsub("\\([^)]*\\)", "", x)                 # drop '(111 percent of target)'
  m <- regmatches(x, regexpr("[0-9]+(\\.[0-9]+)?\\s*(billion|million|thousand)?", x))
  if (!length(m) || !nzchar(m)) return("")
  scale <- if (grepl("billion", m)) 1e9 else if (grepl("million", m)) 1e6 else
           if (grepl("thousand", m)) 1e3 else 1
  val <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", m))) * scale
  if (is.na(val)) return("")
  if (val >= 1000) val <- round(val)     # cents/decimals never decide a match
  format(val, scientific = FALSE, trim = TRUE)
}
num <- function(x) vapply(as.character(x), num_one, character(1), USE.NAMES = FALSE)
alts <- function(cell) trimws(strsplit(as.character(cell), "\\|\\|")[[1]])

## Metric and unit reference: one row per accepted gold value saying what that
## figure counts and in what unit, read from the documents (16 Sep 2026). The
## results_set alone is a bag of numbers, so before this there was nothing to
## compare a metric or a unit against and neither could be scored at all.
RESFILE <- file.path(dirname(gfile), "gold_v1_results.csv")
RES <- if (file.exists(RESFILE)) {
  r <- read.csv(RESFILE, stringsAsFactors = FALSE, colClasses = "character")
  r[is.na(r)] <- ""; r
} else NULL
if (!is.null(RES)) cat("metric/unit reference:", RESFILE, "-", nrow(RES), "rows
")

# a CANDIDATE label means "outside the controlled list"; two different
# CANDIDATE wordings still agree on that much, which is a partial not a miss
mu_norm <- function(x) trimws(tolower(gsub("[^a-z0-9 ]", " ", tolower(x))))
mu_cmp <- function(gold, got) {
  g <- mu_norm(gold); e <- mu_norm(got)
  if (!nzchar(g) || !nzchar(e)) return(NA)
  if (g == e) return(TRUE)
  if (startsWith(g, "candidate") && startsWith(e, "candidate")) return(NA_character_)
  FALSE
}

NUMERIC <- c("publication_year", "start_year", "closure_year", "budget_total",
             "disbursed", "location_count", "evidence_depth")
## An actor CELL holds CODES ("GLO62; GLO27"); a reference may hold the NAMES
## those codes stand for. Compared as plain strings that marked twelve correct
## holdout answers wrong - GLO62 against "Adaptation Fund", GLO16 against
## "World Food Programme". Expand codes to their registered name and acronym
## before the containment test so a coded answer is scored on what it means.
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "actor_names.R"))
AREG <- tryCatch(actor_registry(TEMPLATE_XLSX), error = function(e) NULL)
if (is.null(AREG)) cat("NOTE: actor registry unreadable; codes compared as text
")
actor_expand <- function(e) {
  if (is.null(AREG) || !nzchar(e)) return(character(0))
  codes <- regmatches(e, gregexpr("\\b[A-Z]{2,6}[0-9]{1,4}\\b", e))[[1]]
  if (!length(codes)) return(character(0))
  k <- match(codes, AREG$code); k <- k[!is.na(k)]
  if (!length(k)) return(character(0))
  unique(c(AREG$name[k], AREG$acro[k]))
}
## Report numbers are written both padded and unpadded (ICR00004849 = ICR4849).
id_nrm <- function(x) gsub("(?<=[A-Za-z])0+(?=[0-9])", "", x, perl = TRUE)


CONTAINS <- c("project_lead", "funder", "implementors")

match_field <- function(field, gold_cell, extracted) {
  a <- alts(gold_cell); e <- as.character(extracted)
  if (field == "resource_id") e <- sub("^\\s*report\\s+no[.:]?\\s*", "", e, ignore.case = TRUE)
  if (field == "resource_id") { a <- id_nrm(a); e <- id_nrm(e) }
  if (all(!nzchar(a)) && !nzchar(e)) return("both_empty")
  # titles: tolerate appended identifiers/acronyms — containment either way
  if (field == "project_title") {
    for (av in a) if (nchar(nrm(av)) >= 15 && nzchar(e) &&
        (grepl(nrm(av), nrm(e), fixed = TRUE) || grepl(nrm(e), nrm(av), fixed = TRUE)))
      return("match")
  }
  for (av in a) {
    if (!nzchar(av) && !nzchar(e)) return("match")
    if (!nzchar(av)) next
    if (field %in% NUMERIC) {
      if (nzchar(num(av)) && num(av) == num(e)) return("match")
    } else if (field %in% CONTAINS) {
      hits <- c(e, actor_expand(e))
      for (hv in hits) if (nzchar(hv) && (grepl(nrm(av), nrm(hv), fixed = TRUE) ||
                                          grepl(nrm(hv), nrm(av), fixed = TRUE))) return("match")
    } else {
      if (identical(av, "CANDIDATE") && grepl("^candidate", nrm(e))) return("match")
      if (nzchar(e) && nrm(av) == nrm(e)) return("match")
    }
  }
  if (grepl("^(candidate|new)[: ]", nrm(e))) return("candidate")
  "mismatch"
}

FIELDS <- c("project_title", "project_id", "project_lead", "publication_year",
  "start_year", "closure_year", "project_scale", "location_count",
  "target_beneficiary_project", "budget_total", "disbursed", "currency",
  "funding_mechanism", "funder", "implementors", "document_type",
  "resource_id", "evidence_depth")

rows <- list()
for (i in seq_len(nrow(g))) {
  pc <- g$project_code[i]
  hi <- which(h$project_code_hint == pc)
  if (!length(hi)) { cat("no pipeline row for", pc, "\n"); next }
  hr <- h[hi[1], ]
  for (f in FIELDS) {
    ev <- if (f %in% names(hr)) as.character(hr[[f]]) else ""
    rows[[length(rows) + 1]] <- data.frame(project = pc, field = f,
      gold = as.character(g[[f]][i]), extracted = substr(ev, 1, 120),
      verdict = match_field(f, as.character(g[[f]][i]), ev), stringsAsFactors = FALSE)
  }
  # results as a set
  gold_vals <- num(alts(g$results_set[i])); gold_vals <- gold_vals[nzchar(gold_vals)]
  slots <- c(hr$result1, hr$result2, hr$result3)
  slots <- as.character(slots[nzchar(as.character(slots))])
  hits <- sum(vapply(slots, function(s) num(s) %in% gold_vals, logical(1)))
  rows[[length(rows) + 1]] <- data.frame(project = pc, field = "results_set",
    gold = g$results_set[i],
    extracted = paste(slots, collapse = " | "),
    verdict = if (!length(slots)) "mismatch" else
              if (hits == length(slots)) "match" else
              if (hits > 0) "partial" else "mismatch",
    stringsAsFactors = FALSE)

  # metric and unit, for the slots whose value the reference recognises
  if (!is.null(RES)) {
    ref <- RES[RES$project_code == pc, , drop = FALSE]
    for (fld in c("metric", "unit")) {
      ok <- bad <- soft <- 0
      for (k in 1:3) {
        v <- as.character(hr[[paste0("result", k)]])
        if (!nzchar(trimws(v))) next
        j <- which(nzchar(num(ref$value)) & num(ref$value) == num(v))
        if (!length(j)) next
        gold_v <- ref[[fld]][j[1]]
        if (!nzchar(gold_v)) next
        got_v <- as.character(hr[[paste0("result", k, "_", fld)]])
        r <- mu_cmp(gold_v, got_v)
        if (is.na(r)) soft <- soft + 1 else if (isTRUE(r)) ok <- ok + 1 else bad <- bad + 1
      }
      if (ok + bad + soft == 0) next          # nothing comparable: no check
      rows[[length(rows) + 1]] <- data.frame(project = pc,
        field = paste0("result_", fld), gold = "(see gold_v1_results.csv)",
        extracted = paste(vapply(1:3, function(k)
          as.character(hr[[paste0("result", k, "_", fld)]]), character(1)), collapse = " | "),
        verdict = if (bad == 0 && soft == 0) "match" else
                  if (ok + soft > 0) "partial" else "mismatch",
        stringsAsFactors = FALSE)
    }
  }
}
## A ruling beats a description. Where someone has read the document and
## decided who is right, that sentence is used instead of the generic
## diagnosis. The file is a plain CSV anyone can add a row to.
ADJFILE <- file.path(dirname(gfile), "gold_v1_adjudication.csv")
ADJ <- if (file.exists(ADJFILE)) {
  a <- read.csv(ADJFILE, stringsAsFactors = FALSE, colClasses = "character")
  a[is.na(a)] <- ""; a
} else NULL
if (!is.null(ADJ)) cat("adjudications:", ADJFILE, "-", nrow(ADJ), "rulings
")
adj_why <- function(project, field) {
  if (is.null(ADJ)) return("")
  k <- which(ADJ$project_code == project & ADJ$field == field)
  if (!length(k)) return("")
  w <- ADJ$who_is_right[k[1]]
  lab <- switch(w, gold = "Gold is right.", pipeline = "Pipeline is right.",
                neither = "Neither is right.", "Not decided yet.")
  paste(lab, ADJ$why[k[1]])
}

## Why a check did not agree, in one short plain sentence. A verdict on its own
## tells a reviewer that something is wrong but not what to look at, and the
## same four or five causes come round again and again: the pipeline found
## nothing, the two sides picked different organisations, the counting level
## differs, or the text is identical apart from a space.
actor_name_of <- function(x) {
  n <- actor_expand(x)
  if (length(n)) paste(utils::head(n[nzchar(n)], 2), collapse = " / ") else x
}
strip_all <- function(x) gsub("[^a-z0-9]", "", tolower(x))
fmt <- function(v) format(v, scientific = FALSE, trim = TRUE, big.mark = ",")

why_fail <- function(field, gold, got, verdict) {
  if (verdict %in% c("match", "both_empty")) return("")
  g <- trimws(as.character(gold)); e <- trimws(as.character(got))
  ga <- alts(g); ga <- ga[nzchar(ga)]
  if (!nzchar(e) && length(ga))  return("Pipeline found nothing. Gold has a value.")
  if (nzchar(e) && !length(ga))  return("Gold is empty. Pipeline found a value.")
  if (grepl("^candidate", tolower(e)))
    return("No option in the list fitted. Pipeline flagged it for review.")
  if (any(vapply(ga, function(a) strip_all(a) == strip_all(e), logical(1))))
    return("Same text. Only spacing or punctuation differs.")

  if (field == "results_set")
    return(if (verdict == "partial") "Some result values match gold, some do not."
           else "None of the result values match gold.")
  if (field %in% c("result_metric", "result_unit"))
    return(if (verdict == "partial")
             "Both say the term is outside the list, but word it differently."
           else "Pipeline named something different from gold.")

  if (field %in% CONTAINS)
    return(paste0("Different organisation. Gold wants ", actor_name_of(ga[1]),
                  ", pipeline gave ", actor_name_of(e), "."))

  if (field %in% NUMERIC) {
    gn <- suppressWarnings(as.numeric(num(ga))); gn <- gn[!is.na(gn)]
    en <- suppressWarnings(as.numeric(num(e)))
    if (length(gn) && !is.na(en) && en > 0) {
      if (field == "location_count")
        return(if (en > max(gn))
                 "Counted smaller places than gold. Gold counted countries or regions."
               else "Counted larger areas than gold. Gold counted sites.")
      if (field %in% c("budget_total", "disbursed"))
        return(paste0("Different amount. Gold ", fmt(max(gn)), ", pipeline ", fmt(en),
                      ". Check the currency and whether co-financing is included."))
      if (field %in% c("start_year", "closure_year", "publication_year"))
        return(paste0("Different year. Gold ", fmt(gn[1]), ", pipeline ", fmt(en),
                      ". Check which date the document means."))
      return(paste0("Different number. Gold ", fmt(gn[1]), ", pipeline ", fmt(en), "."))
    }
  }
  if (field == "project_title") return("Different title. Check the project name, not the report name.")
  paste0("Different value. Gold accepts ", substr(ga[1], 1, 40), ".")
}

sc <- bind_rows(rows)
sc$why <- mapply(why_fail, sc$field, sc$gold, sc$extracted, sc$verdict,
                 USE.NAMES = FALSE)
ruled <- mapply(adj_why, sc$project, sc$field, USE.NAMES = FALSE)
sc$why <- ifelse(nzchar(ruled), ruled, sc$why)

stamp <- sub("^harmonized_(diagnostics_)?", "", sub("\\.csv$", "", basename(hfile)))
out <- file.path(OUT_DIR, paste0("score_", stamp, ".csv"))
write_csv(sc, out)

cat("\n== per-field agreement ==\n")
per_field <- sc %>% group_by(field) %>%
  summarise(match = sum(verdict %in% c("match", "both_empty")),
            partial = sum(verdict == "partial"),
            candidate = sum(verdict == "candidate"),
            mismatch = sum(verdict == "mismatch"), .groups = "drop") %>%
  arrange(desc(mismatch))
print(as.data.frame(per_field), row.names = FALSE)
tot <- nrow(sc)
cat(sprintf("\nOVERALL: %d checks | %.0f%% match | %d partial | %d candidate-flagged | %d mismatch\n",
  tot, 100 * sum(sc$verdict %in% c("match", "both_empty")) / tot,
  sum(sc$verdict == "partial"), sum(sc$verdict == "candidate"),
  sum(sc$verdict == "mismatch")))
cat("\nmismatches:\n")
mm <- sc[sc$verdict == "mismatch", c("project", "field", "gold", "extracted")]
if (nrow(mm)) print(mm, row.names = FALSE) else cat("none\n")
cat("\nwritten:", out, "\n")
