##############################################################################
# build_qc_workbooks.R — turn one frozen run into one workbook per project,
# for the consultants who check every extracted value.
#
# Three consultants check the whole corpus and two people review them after.
# That is roughly 656 project rows and some 15,000 location rows, so the one
# thing that decides whether this takes weeks or months is whether a checker
# can see WHERE a value came from without opening the PDF. So every value
# carries its evidence in a cell comment: the document's own sentence, the
# page, and the machine fact-check verdict. Hover, confirm, move on.
#
# The sheets are the template's own columns in the template's own order, so a
# corrected sheet pastes straight back. Consultants edit values in place; the
# collector recovers what the pipeline said by diffing against this frozen run,
# which is why the run id on the `about` sheet matters.
#
# Writes <out>/<project_code>.xlsx, one per project:
#   about       project, consultant, documents, run id, public source links
#   general     the project_data_general columns, one row per document
#   locations   the project_data_location-specific columns, one row per location
#   _lists      hidden, backing the long dropdowns
#
# Inputs: a harmonised run (harmonize.R writes template columns and evidence
# in ONE file since 30 Sep 2026), the matching locations_harmonized_*.csv,
# catalogues/doc_index.csv for the public document URL, and optionally
# catalogues/qc_assignment.csv saying who checks what.
#
#   Rscript R/07_review/build_qc_workbooks.R [--run <file|dir>] [--out <dir>]
#                                            [--limit N] [--dry]
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "vocab_lists.R"))
source(file.path(REPO, "R", "00_shared", "xlsx_helpers.R"))

args  <- commandArgs(trailingOnly = TRUE)
opt   <- function(flag, default = "") {
  i <- which(args == flag); if (length(i) && length(args) > i[1]) args[i[1] + 1] else default
}
DRY   <- any(args == "--dry")
LIMIT <- suppressWarnings(as.integer(opt("--limit", NA)))
OUT_EXTRACT <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction"))

rd <- function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character", check.names = FALSE)
  d[is.na(d)] <- ""; d
}
`%||%` <- function(a, b) if (is.null(a) || !length(a)) b else a
gv <- function(d, col, i = NULL) {
  if (!col %in% names(d)) return(if (is.null(i)) rep("", nrow(d)) else "")
  v <- as.character(d[[col]]); v[is.na(v)] <- ""
  if (is.null(i)) v else v[i]
}

## ---- find the run ----------------------------------------------------------
# harmonize.R writes ONE file now; older runs left a harmonized_diagnostics_*
# twin beside a stripped clean file, and the clean one has no evidence in it.
newest_in <- function(dir, pat, exclude = NULL) {
  f <- list.files(dir, pattern = pat, full.names = TRUE)
  if (!is.null(exclude)) f <- f[!grepl(exclude, basename(f))]
  if (!length(f)) return(NA_character_)
  f[which.max(file.mtime(f))]
}
run_arg <- opt("--run")
GEN <- {
  if (nzchar(run_arg) && !dir.exists(run_arg)) run_arg
  else newest_in(if (nzchar(run_arg)) run_arg else OUT_EXTRACT,
                 "^harmonized_.*\\.csv$", exclude = "^harmonized_diagnostics_")
}
stopifnot("no harmonised run found - run harmonize.R first" = !is.na(GEN))
RUN_ID <- sub("^harmonized_", "", sub("\\.csv$", "", basename(GEN)))

LOCF <- newest_in(file.path(dirname(GEN), "locations"), "^locations_harmonized_.*\\.csv$")
if (is.na(LOCF)) LOCF <- newest_in(file.path(OUT_EXTRACT, "locations"),
                                   "^locations_harmonized_.*\\.csv$")

OUTDIR <- opt("--out", file.path(QC_DIR, RUN_ID))

cat("run:      ", GEN, "\n  run id: ", RUN_ID, "\n")
cat("locations:", if (is.na(LOCF)) "(none found - workbooks get a general sheet only)" else LOCF, "\n")
cat("out:      ", OUTDIR, "\n")

G <- rd(GEN)
L <- if (!is.na(LOCF)) rd(LOCF) else NULL
if (!"project_code" %in% names(G)) stop("the harmonised run has no project_code column")

# evidence columns only arrive with s1-v2.7; say so rather than silently
# producing workbooks with empty hovers
if (!any(grepl("_check$|_quote$", names(G))))
  cat("\n  NOTE: this run carries no _quote/_check columns, so most hovers will be\n",
      "       empty. Re-extract with s1-v2.7 or later for the full evidence.\n\n")

## ---- template column order -------------------------------------------------
# openxlsx substitutes sep.names for spaces in a header even when check.names
# is FALSE, which is what turned "subsector type" into "subsector.type" in
# every export until it was caught
tmpl_cols <- function(sheet) names(read.xlsx(TEMPLATE_XLSX, sheet = sheet, sep.names = " "))
GEN_COLS <- tmpl_cols("project_data_general")
LOC_COLS <- tmpl_cols("project_data_location-specific")

## ---- template column -> where its evidence lives ---------------------------
# A template column and the Session 1 field behind it rarely share a name: the
# sheet says `funder` and holds actor CODES, while the evidence is the names in
# funder_names. Without this map the hover would be blank on exactly the
# fields people most need to check.
EV_BASE <- c(
  project_title = "project_title", project_id = "project_id",
  project_lead = "project_lead_name", publication_year = "publication_year",
  start_year = "start_year", closure_year = "closure_year",
  project_scale = "scope_stated", location_count = "location_count",
  location_notes = "location_notes", rationale_project = "rationale_project",
  target_beneficiary_project = "target_beneficiary_stated",
  GESI_project = "GESI_project",
  result1 = "result1", result2 = "result2", result3 = "result3",
  result1_metric = "result1_metric_stated", result2_metric = "result2_metric_stated",
  result3_metric = "result3_metric_stated",
  result1_unit = "result1_unit_stated", result2_unit = "result2_unit_stated",
  result3_unit = "result3_unit_stated",
  budget_total = "budget_total", disbursed = "disbursed", currency = "currency",
  funding_mechanism = "instrument_stated", funder = "funder_names",
  implementors = "implementor_names", document_type = "document_type_stated",
  resource_id = "resource_id", evidence_depth = "evidence_depth",
  reference_link_1 = "reference_link_1")

CHECK_WORDS <- c(
  "NOT FOUND"        = "NOT FOUND on the page cited - look at this one",
  "found_other_page" = "found, but on a different page than cited",
  "verified"         = "verified against the cited page",
  "skipped"          = "not machine-checkable",
  "verified_tokens (table)" = "verified against a table on the cited page")

#' Build the hover note for one cell.
hover <- function(d, i, col) {
  base <- unname(EV_BASE[col])
  bits <- character(0)
  if (!is.na(base)) {
    quote <- gv(d, paste0(base, "_quote"), i)
    if (!nzchar(quote)) quote <- gv(d, paste0(base, "_stated"), i)
    if (!nzchar(quote) && !identical(base, col)) quote <- gv(d, base, i)
    if (nzchar(quote)) bits <- c(bits, paste0('"', quote, '"'))
    page <- gv(d, paste0(base, "_page"), i)
    if (nzchar(page) && page != "0") bits <- c(bits, paste0("page ", page))
    prov <- gv(d, paste0(base, "_provenance"), i)
    if (nzchar(prov)) bits <- c(bits, prov)
    chk <- gv(d, paste0(base, "_check"), i)
    if (nzchar(chk) && chk != "skipped")
      bits <- c(bits, paste0("fact-check: ", CHECK_WORDS[chk] %||% chk))
    nfail <- gv(d, paste0(base, "_check_failed"), i)
    if (nzchar(nfail) && nfail != "0")
      bits <- c(bits, paste0(nfail, " name(s) not found in the document"))
    exn <- gv(d, paste0(base, "_extracted"), i)
    if (nzchar(exn)) bits <- c(bits, paste0("the document said: ", exn))
    flag <- gv(d, paste0(base, "_flag"), i)
    if (nzchar(flag)) bits <- c(bits, paste0("flag: ", flag))
  }
  if (!length(bits)) {
    grp <- c(project_title = "identity", project_id = "identity",
             project_lead = "identity", publication_year = "identity",
             start_year = "identity", closure_year = "identity",
             resource_id = "identity", document_type = "identity",
             project_scale = "geography", location_count = "geography",
             location_notes = "geography", rationale_project = "rationale",
             target_beneficiary_project = "rationale", GESI_project = "rationale",
             budget_total = "finance", disbursed = "finance", currency = "finance",
             funding_mechanism = "finance", funder = "finance",
             implementors = "finance")[col]
    if (!is.na(grp)) {
      p <- gv(d, paste0(grp, "_pages"), i)
      if (nzchar(p)) bits <- c(bits, paste0("read from ", grp, ", pages ", p))
    }
  }
  if (!length(bits)) return("")
  paste(bits, collapse = "\n")
}

## ---- lookups ---------------------------------------------------------------
DOCIX <- local({
  f <- file.path(REPO, "catalogues", "doc_index.csv")
  if (file.exists(f)) rd(f) else NULL
})
url_for <- function(doc) {
  if (is.null(DOCIX) || !nzchar(doc)) return("")
  r <- DOCIX[DOCIX$filename == doc, ]
  if (nrow(r) >= 1) as.character(r$url[1]) else ""
}
ASSIGN <- local({
  f <- file.path(REPO, "catalogues", "qc_assignment.csv")
  if (file.exists(f)) rd(f) else NULL
})
consultant_for <- function(pc) {
  if (is.null(ASSIGN) || !"project_code" %in% names(ASSIGN)) return("unassigned")
  r <- ASSIGN[ASSIGN$project_code == pc, ]
  if (nrow(r) >= 1 && nzchar(r$consultant[1])) as.character(r$consultant[1]) else "unassigned"
}

GEN_DROPDOWNS <- list(
  project_scale = OPT$scale, target_beneficiary_project = OPT$beneficiary,
  document_type = OPT$doc_type,
  result1_metric = OPT$metric, result2_metric = OPT$metric, result3_metric = OPT$metric,
  result1_unit = OPT$unit, result2_unit = OPT$unit, result3_unit = OPT$unit)
LOC_DROPDOWNS <- list(
  `subsector type` = OPT$subsector, target_beneficiary = OPT$beneficiary,
  result_level = OPT$result_level)
LOCKED <- c("project_code", "row_id", "document", "resource_link", "reference_link_1")

## ---- build one project -----------------------------------------------------
shape <- function(d, cols) {
  m <- as.data.frame(lapply(cols, function(cn) if (cn %in% names(d)) as.character(d[[cn]]) else ""),
                     stringsAsFactors = FALSE)
  names(m) <- cols; m
}

add_sheet <- function(wb, name, src, cols, dropdowns) {
  df <- shape(src, cols)
  qc_sheet(wb, name, df)
  n <- nrow(df)
  if (!n) return(invisible())
  for (j in seq_along(cols)) {
    cn <- cols[j]
    for (i in seq_len(n)) {
      qc_comment(wb, name, col = j, row = i + 1, text = hover(src, i, cn))
      val <- df[[j]][i]
      if (!nzchar(val))
        addStyle(wb, name, QC_STYLES$empty, rows = i + 1, cols = j, stack = TRUE)
      base <- unname(EV_BASE[cn])
      if (!is.na(base) && identical(gv(src, paste0(base, "_check"), i), "NOT FOUND"))
        addStyle(wb, name, QC_STYLES$suspect, rows = i + 1, cols = j, stack = TRUE)
    }
    if (cn %in% names(dropdowns))
      qc_dropdown(wb, name, col = j, options = dropdowns[[cn]], rows = n)
  }
  qc_lock(wb, name, cols, LOCKED, n)
}

build_one <- function(pc) {
  g <- G[G$project_code == pc, , drop = FALSE]
  l <- if (!is.null(L) && "project_code" %in% names(L)) L[L$project_code == pc, , drop = FALSE] else NULL
  docs <- unique(gv(g, "document")); docs <- docs[nzchar(docs)]
  who  <- consultant_for(pc)

  wb <- createWorkbook()
  qc_lists_reset()
  about <- data.frame(
    item = c("project code", "checked by", "documents", "source links",
             "pipeline run", "run id", "built", "how to use", "", "rebuild with"),
    value = c(
      pc, who,
      if (length(docs)) paste(docs, collapse = "\n") else "(none recorded)",
      paste(Filter(nzchar, vapply(docs, url_for, character(1))), collapse = "\n"),
      basename(GEN), RUN_ID, format(Sys.time(), "%Y-%m-%d %H:%M"),
      paste("Hover any value to see the document's own sentence, its page and",
            "the machine fact-check. Correct values in place; the pipeline's",
            "originals are recovered by diffing against the run named above.",
            "A yellow cell is one the fact-check could not find on the page it",
            "cites. A grey cell is empty: confirming the document is silent is",
            "still a check.", sep = " "),
      "",
      "Rscript R/07_review/build_qc_workbooks.R"),
    stringsAsFactors = FALSE)
  qc_sheet(wb, "about", about, widths = c(16, 110))
  addStyle(wb, "about", QC_STYLES$label, rows = 2:(nrow(about) + 1), cols = 1, stack = TRUE)

  add_sheet(wb, "general", g, GEN_COLS, GEN_DROPDOWNS)
  if (!is.null(l) && nrow(l)) add_sheet(wb, "locations", l, LOC_COLS, LOC_DROPDOWNS)

  f <- file.path(OUTDIR, paste0(safe_name(pc), ".xlsx"))
  if (!DRY) saveWorkbook(wb, f, overwrite = TRUE)
  list(file = f, who = who, general = nrow(g), locations = if (is.null(l)) 0L else nrow(l))
}

## ---- run -------------------------------------------------------------------
codes <- unique(G$project_code); codes <- codes[nzchar(codes)]
if (!is.na(LIMIT)) codes <- head(codes, LIMIT)
if (!DRY) dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)
cat("\nprojects:", length(codes), "\n")

res <- lapply(codes, function(pc) {
  r <- tryCatch(build_one(pc), error = function(e) {
    cat(sprintf("  %-28s FAILED: %s\n", pc, conditionMessage(e))); NULL })
  if (!is.null(r))
    cat(sprintf("  %-28s %-12s %2d general, %3d location rows\n",
                pc, r$who, r$general, r$locations))
  r
})
res <- Filter(Negate(is.null), res)

cat("\n", length(res), "workbooks", if (DRY) "(--dry: nothing written)" else
    paste("written to", OUTDIR), "\n")

## ---- hand them to the consultants ------------------------------------------
# The consultants are external and cannot reach OneDrive, so they work on
# Google Drive. Drive for Desktop mounts as an ordinary drive letter, so this
# is a copy, not an API. Only `extracted/` is written: a workbook already in
# progress/, done/ or qc/ is somebody's work in hand and is never overwritten.
DEST <- opt("--distribute")
if (nzchar(DEST) && length(res) && !DRY) {
  cat("\ndistributing to", DEST, "\n")
  copied <- skipped <- 0L
  for (r in res) {
    for (stage in c("extracted", "progress", "done", "qc"))
      dir.create(file.path(DEST, r$who, stage), recursive = TRUE, showWarnings = FALSE)
    elsewhere <- unlist(lapply(c("progress", "done", "qc"), function(s)
      file.path(DEST, r$who, s, basename(r$file))))
    if (any(file.exists(elsewhere))) { skipped <- skipped + 1L; next }
    if (file.copy(r$file, file.path(DEST, r$who, "extracted", basename(r$file)),
                  overwrite = TRUE)) copied <- copied + 1L
  }
  cat("  ", copied, "copied into extracted/;", skipped,
      "left alone because the consultant already has them in hand\n")
}
if (length(res)) {
  who <- table(vapply(res, `[[`, character(1), "who"))
  cat("per consultant:\n"); print(who)
  if (is.null(ASSIGN))
    cat("\n  no catalogues/qc_assignment.csv yet, so everything is 'unassigned'.\n",
        "  Add one with columns project_code,consultant to split the work.\n")
}
