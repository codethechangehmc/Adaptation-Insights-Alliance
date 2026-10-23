# screen_rules.R - deterministic checks on the screener's judgements.
#
# The 200-document review of 18 Sep 2026 found the model's misses cluster in
# ways code can catch without paying again:
#   1. "in scope" with no climate-risk quote: the intervention criterion was
#      not evidenced (irrigation, value chains or productivity alone were read
#      as adaptation). Verdict becomes "unsure", reason says why.
#   2. "in scope" where the model itself says the project is mitigation or
#      neither: out on intervention.
#   3. "in scope" for a programme evaluation covering several projects:
#      "unsure", it needs a focus project before extraction.
#   4. a reason that is a bare word ("sector"): the verdict is kept but the
#      row is listed for a re-ask, because a reviewer cannot use it.
#   5. documents of one project (same cover identifier in the census) with
#      conflicting verdicts: listed, so the fuller document can decide.
# The Oct 2026 completeness audit added four more (Phase 4a):
#   0. review/year_overrides.csv: recovered publication years (GEF machine
#      footers) replace the screened year BEFORE the year rule runs.
#   5c. review/supersedes.csv: a portal sheet whose full evaluation is in hand
#      goes to "unsure" - judge the evaluation, not the sheet.
#   7. a reason that says "In scope" / "all four criteria are met" under an
#      out-of-scope ruled verdict is listed for the Phase 4c re-ask
#      (scope_screen_contradictions.csv); the verdict is left alone.
#   8. a climate_risk_quote that is the AfDB PCR template label is treated as
#      no quote; scope_screen_portal_sheets.csv lists likely GEF portal sheets.
# The original verdict and reason are kept; ruled values sit beside them.
# Human overrides (scope_screen_overrides.csv) are still applied LAST: a
# recorded decision always wins. Re-running is idempotent.
#
#   Rscript R/03_screen/screen_rules.R
#   -> 04_Screening/scope_screen.csv gains verdict_ruled, rule_applied
#      04_Screening/inputs/decisions/scope_screen_reask.csv   rows to re-judge (bare reasons)
#      04_Screening/inputs/reports/scope_screen_conflicts.csv projects whose documents disagree
#      04_Screening/inputs/reports/scope_screen_contradictions.csv reason contradicts verdict
#      04_Screening/inputs/reports/scope_screen_portal_sheets.csv  likely GEF portal sheets

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "doc_families.R"))
source(file.path(REPO, "R", "03_screen", "screen_text.R"))   # is_boilerplate_quote

SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
CENSUS <- file.path(SCREEN_DIR, "inputs", "decisions", "family_census.csv")
sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
sc[is.na(sc)] <- ""
n <- nrow(sc)
cat("judgements:", n, "\n")

# 0. recovered publication years. GEF portal sheets carry a machine footer
#    ("1/13/2026   Page 1 of 7") and the screener read the year off it; the
#    dating step (catalogues/gef/gef_evaluation_dates.csv) recovered the real
#    years. review/year_overrides.csv (source, filename, publication_year,
#    evidence; seeded by R/03_screen/seed_year_overrides.R) is applied BEFORE
#    the year rule, so the window is judged - and scope_screen.csv rewritten -
#    with the recovered year. Idempotent: the override value is stable, so a
#    second run replaces like with like.
YOVR <- file.path(SCREEN_DIR, "inputs", "decisions", "year_overrides.csv")
year_fixed <- rep(FALSE, n)
if (file.exists(YOVR)) {
  yo <- read.csv(YOVR, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
  yo[is.na(yo)] <- ""
  yo <- yo[nzchar(yo$publication_year), ]
  hit <- match(paste(yo$source, yo$filename), paste(sc$source, sc$filename))
  for (j in which(!is.na(hit))) {
    i <- hit[j]
    sc$publication_year[i] <- yo$publication_year[j]
    year_fixed[i] <- TRUE
  }
  cat("year overrides applied:", sum(!is.na(hit)), "of", nrow(yo), "\n")
}

# The year window is applied here from the model's own verdict when it was
# stored (verdict_model, screener v4 onward), so moving the window is a change
# of two numbers and a rerun of this script: no document is read again. Rows
# from earlier runs keep the verdict the screener wrote.
YEAR_MIN <- 2015; YEAR_MAX <- 2025
verdict <- sc$verdict
if ("verdict_model" %in% names(sc)) {
  has <- nzchar(sc$verdict_model)
  y <- suppressWarnings(as.integer(sc$publication_year))
  base <- ifelse(has, sc$verdict_model, sc$verdict)
  out_year <- has & !is.na(y) & (y < YEAR_MIN | y > YEAR_MAX)
  no_year  <- has & is.na(y) & base == "in scope"
  verdict <- ifelse(out_year, "out of scope", ifelse(no_year, "unsure", base))
}
rule <- rep("", n)
if ("verdict_model" %in% names(sc)) {
  rule[out_year] <- sprintf("timeframe: dated %s, outside %d-%d", sc$publication_year[out_year], YEAR_MIN, YEAR_MAX)
  rule[no_year]  <- "no year stated, so the timeframe cannot be checked"
}
set_rule <- function(i, v, why) { verdict[i] <<- v; rule[i] <<- why }

for (i in seq_len(n)) {
  if (verdict[i] != "in scope") next
  fam <- if (nzchar(sc$family[i])) sc$family[i] else "generic"
  info <- family_info(fam)
  # a quote that is the AfDB PCR template label ("Type (e.g. gender, climate
  # change, social, other)") is boilerplate, not evidence: treat its length
  # as 0 so the no-quote demotion catches it, with its own rule text.
  q <- sc$climate_risk_quote[i]
  qlen <- if (is_boilerplate_quote(q)) 0L else nchar(trimws(q))
  if (sc$adaptation_or_mitigation[i] %in% c("mitigation", "neither")) {
    set_rule(i, "out of scope", "model says the project is not adaptation (adaptation_or_mitigation); out on intervention")
  } else if (qlen < 12) {
    set_rule(i, "unsure", if (is_boilerplate_quote(q))
      "climate quote is template boilerplate, not evidence" else
      "no climate risk quoted, so the intervention criterion is not evidenced")
  } else if (sc$covers_several_projects[i] == "yes" && (isTRUE(info$multi) || fam == "programme_evaluation")) {
    set_rule(i, "unsure", "covers several projects: needs a focus project before extraction")
  }
}
# 5b. progress documents are out, by the protocol's first criterion:
#     "The document evaluates what was done: a completion report, a terminal
#     or mid term evaluation, a performance evaluation. Proposals, appraisals
#     and progress reports are out." (AI_Extraction_Protocol.docx, source type)
#
#     This used to mark them "unsure" pending a team decision, on the reading
#     that the protocol's wording might allow them. It does not: it names them
#     in the same sentence as proposals and appraisals. 217 of the 293 unsure
#     documents were sitting on that question.
#
#     Matched two ways, because the folder is not reliable on its own: 27
#     World Bank ISRs, GEF PIRs and AF PPRs are filed in ordinary corpus
#     folders, 6 of them previously counted as in scope.
#     The family detector alone is not enough to exclude on. It labels GEF
#     mid-term reviews and terminal evaluations wb_isr or gef_pir: 18 of the
#     27 family matches outside the parked folders are named
#     Mid-Term_Review or Terminal_Evaluation, which the protocol names as IN
#     scope. One of them, gef_4645_Mid-Term_Review.pdf, is H004 in the
#     holdout set. So a family match only counts when the filename agrees,
#     and a family match the filename contradicts is left alone and listed
#     for a person in scope_screen_family_disputed.csv.
PROGRESS_FAMILIES <- c("wb_isr", "gef_pir", "af_ppr")
EVAL_NAME <- "terminal[_ ]evaluation|mid[-_ ]?term|completion|final[_ ]evaluation|PPER|PCR|ICR"
PROG_NAME <- "implementation[_ ]report|performance[_ ]report|progress"

in_parked_folder <- grepl("progress_reports", sc$folder, fixed = TRUE)
fam_says_progress <- sc$family %in% PROGRESS_FAMILIES
name_says_eval <- grepl(EVAL_NAME, sc$filename, ignore.case = TRUE)
name_says_prog <- grepl(PROG_NAME, sc$filename, ignore.case = TRUE)

parked   <- in_parked_folder | (fam_says_progress & name_says_prog & !name_says_eval)
disputed <- fam_says_progress & !in_parked_folder & name_says_eval & !name_says_prog

verdict[parked] <- "out of scope"
rule[parked] <- ifelse(in_parked_folder[parked],
                       "progress document (parked folder); protocol source type excludes progress reports",
                       paste0("progress document (family ", sc$family[parked],
                              ", filename agrees); protocol source type excludes progress reports"))

if (any(disputed)) {
  d <- sc[disputed, c("source", "folder", "filename", "family", "verdict", "verdict_ruled")]
  d$note <- "family detector says progress, filename says an in-scope evaluation type; left as judged"
  write.csv(d, file.path(SCREEN_DIR, "inputs", "reports", "scope_screen_family_disputed.csv"),
            row.names = FALSE, fileEncoding = "UTF-8")
  cat("family/filename disputes left for a person:", sum(disputed), "\n")
}

# 5c. superseded documents: review/supersedes.csv (source, filename,
#     superseded_by, note) lists GEF portal summary sheets whose full agency
#     evaluation has been fetched. The sheet's verdict becomes "unsure" - the
#     sector and intervention must be judged on the evaluation, not a 5-19
#     page portal sheet. Applied before the human overrides, so a recorded
#     decision on the sheet still wins.
SUP <- file.path(SCREEN_DIR, "inputs", "decisions", "supersedes.csv")
if (file.exists(SUP)) {
  sp <- read.csv(SUP, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
  sp[is.na(sp)] <- ""
  hit <- match(paste(sp$source, sp$filename), paste(sc$source, sc$filename))
  for (j in which(!is.na(hit))) {
    i <- hit[j]
    verdict[i] <- "unsure"
    rule[i] <- paste0("superseded by ", sp$superseded_by[j],
                      ": judge the full evaluation, not the portal sheet")
  }
  if (nrow(sp)) cat("supersedes applied:", sum(!is.na(hit)), "of", nrow(sp), "\n")
}

# 6. a person's decision wins over everything above. 04_Screening/inputs/decisions/scope_screen_overrides.csv
#    holds one row per decided document: source, filename, verdict (in scope /
#    out of scope / unsure), note, by. This is the accepted / rejected loop
#    in the workflow diagram.
OVR <- file.path(SCREEN_DIR, "inputs", "decisions", "scope_screen_overrides.csv")
if (file.exists(OVR)) {
  ov <- read.csv(OVR, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
  ov <- ov[ov$verdict %in% c("in scope", "out of scope", "unsure"), ]
  key <- paste(sc$source, sc$filename)
  hit <- match(paste(ov$source, ov$filename), key)
  for (j in which(!is.na(hit))) {
    i <- hit[j]
    verdict[i] <- ov$verdict[j]
    rule[i] <- paste0("human (", ov$by[j], "): ", ov$note[j])
  }
  cat("overrides applied:", sum(!is.na(hit)), "of", nrow(ov), "
")
}
bare <- nchar(trimws(sc$reason)) < 25
sc$verdict_ruled <- verdict

# 7. self-contradiction: a reason that opens "In scope" or claims "all four
#    criteria are met" while the ruled verdict is out of scope. The verdict is
#    left alone (the audit found the reason, not the verdict, is sometimes the
#    honest half); the row is listed for the Phase 4c re-ask, mirroring the
#    bare-word mechanism.
#    The opening-word test was too narrow: the Phase 4c re-read produced
#    reasons like "Out on intervention: ... In scope: Benin named; sector is
#    agriculture (primary focus)", where the concession sits mid-sentence. A
#    reason that says "in scope" ANYWHERE under an out verdict is a
#    contradiction worth a person's eye, so match anywhere.
reason_trim <- trimws(sc$reason)
contra <- (grepl("\\bin scope\\b", reason_trim, ignore.case = TRUE) |
           grepl("all four criteria are met", reason_trim, ignore.case = TRUE) |
           grepl("criteria are (all )?met", reason_trim, ignore.case = TRUE)) &
          sc$verdict_ruled == "out of scope"

ra <- ifelse(bare & !nzchar(rule), "reason is a bare word: re-ask",
      ifelse(bare, paste(rule, "| reason is a bare word: re-ask"), rule))
ra <- ifelse(contra & !nzchar(ra), "reason contradicts verdict: re-ask",
      ifelse(contra, paste(ra, "| reason contradicts verdict: re-ask"), ra))
sc$rule_applied <- ra

## ---- 5. conflicting verdicts inside one project ------------------------------
conf <- data.frame()
if (file.exists(CENSUS)) {
  cen <- read.csv(CENSUS, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
  cen[is.na(cen)] <- ""
  key <- setNames(paste(cen$source, cen$filename), paste(cen$source, cen$filename))
  ids <- lapply(seq_len(nrow(cen)), function(i) {
    v <- unlist(lapply(c("wb_project", "afdb_code", "gef_id", "gcf_fp", "af_id"), function(cn) {
      x <- cen[[cn]][i]; if (nzchar(x)) paste0(cn, ":", strsplit(x, ";")[[1]]) else character(0)
    }))
    v
  })
  idmap <- split(rep(paste(cen$source, cen$filename), lengths(ids)), unlist(ids))
  vmap <- setNames(sc$verdict_ruled, paste(sc$source, sc$filename))
  rows <- list()
  for (k in names(idmap)) {
    docs <- unique(idmap[[k]]); docs <- docs[docs %in% names(vmap)]
    if (length(docs) < 2) next
    vs <- vmap[docs]
    if (length(unique(vs)) < 2) next
    rows[[length(rows) + 1]] <- data.frame(project_id = k, n_docs = length(docs),
      verdicts = paste(sprintf("%s [%s]", sub("^[a-z]+ ", "", docs), vs), collapse = " | "),
      stringsAsFactors = FALSE)
  }
  if (length(rows)) conf <- do.call(rbind, rows)
}

## ---- portal sheets (a report, not a verdict change) -----------------------------
# GEF portal summary sheets - the all-caps TERMINAL EVALUATION / MID-TERM
# REVIEW / PROJECT IMPLEMENTATION REPORT heading over a "Project ID:" block,
# with the M/D/YYYY "Page N of M" machine footer on every page (checked
# against gef_5580 and gef_10199) - are 5-19 page stand-ins for the agency
# evaluation; 37 of 122 GEF screens were judged on one. Signal available from
# the judgement row: low chars plus either the bare portal heading captured
# verbatim as doc_kind_stated, or a footer-derived year the dates catalogue
# corrected (a year_overrides.csv hit).
ch <- suppressWarnings(as.integer(sc$chars))
kind_norm <- toupper(gsub("\\s+", " ", trimws(sc$doc_kind_stated)))
portal <- sc$source == "gef" & !is.na(ch) & ch < 25000 &
  (kind_norm %in% c("TERMINAL EVALUATION", "MID-TERM REVIEW",
                    "PROJECT IMPLEMENTATION REPORT") | year_fixed)
portal_sheets <- sc[portal, c("source", "folder", "filename", "chars",
                              "publication_year", "doc_kind_stated", "verdict_ruled")]

## ---- write ---------------------------------------------------------------------
write.csv(sc, SCREEN, row.names = FALSE, na = "", fileEncoding = "UTF-8")
reask <- sc[bare, c("source", "folder", "filename", "verdict", "reason", "family")]
write.csv(reask, file.path(SCREEN_DIR, "inputs", "decisions", "scope_screen_reask.csv"), row.names = FALSE, fileEncoding = "UTF-8")
write.csv(conf, file.path(SCREEN_DIR, "inputs", "reports", "scope_screen_conflicts.csv"), row.names = FALSE, fileEncoding = "UTF-8")
contradictions <- sc[contra, c("source", "folder", "filename", "verdict", "verdict_ruled", "reason")]
write.csv(contradictions, file.path(SCREEN_DIR, "inputs", "reports", "scope_screen_contradictions.csv"), row.names = FALSE, fileEncoding = "UTF-8")
write.csv(portal_sheets, file.path(SCREEN_DIR, "inputs", "reports", "scope_screen_portal_sheets.csv"), row.names = FALSE, fileEncoding = "UTF-8")
cat("reason contradicts verdict (Phase 4c re-ask):", nrow(contradictions), "\n")
if (nrow(contradictions)) print(table(contradictions$source))
cat("portal-sheet listing:", nrow(portal_sheets), "gef rows\n")
# the human queue: every unsure document with the model's reason and the rule
# that made it unsure, so a person can decide without opening the CSV
unsure <- sc[sc$verdict_ruled == "unsure", c("source", "folder", "filename", "family", "reason", "rule_applied", "doc_type", "publication_year")]
write.csv(unsure, file.path(SCREEN_DIR, "inputs", "reports", "scope_screen_unsure.csv"), row.names = FALSE, fileEncoding = "UTF-8")
cat("unsure queue for a person:", nrow(unsure), "\n")

cat("\nverdicts before and after the rules:\n")
print(addmargins(table(before = sc$verdict, after = sc$verdict_ruled)))
cat("\nrules applied:\n"); print(table(sub(" \\|.*$", "", sc$rule_applied[nzchar(sc$rule_applied)])))
cat("\nrows to re-ask (bare reason):", nrow(reask), "\n")
cat("projects whose documents disagree:", nrow(conf), "\n")
if (nrow(conf)) print(head(conf, 12))
cat("\nwritten:", SCREEN, "(+ verdict_ruled, rule_applied)\n        scope_screen_reask.csv, scope_screen_conflicts.csv,\n        scope_screen_contradictions.csv, scope_screen_portal_sheets.csv\n")
