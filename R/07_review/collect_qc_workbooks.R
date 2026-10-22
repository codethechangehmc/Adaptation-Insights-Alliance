##############################################################################
# collect_qc_workbooks.R — read the consultants' checked workbooks back in,
# diff them against the run they were built from, and produce one corrected
# dataset plus a record of every change.
#
# Consultants edit values in place, so the only way to know what the pipeline
# originally said is the frozen run named on each workbook's `about` sheet.
# That is why the run id is written there and why nothing downstream should
# read a run that is still being added to.
#
# A workbook's folder is its status, so there is no tracker to keep in sync:
#   extracted/  built, nobody has opened it        (ignored here)
#   progress/   being worked on                    (ignored here)
#   done/       the consultant has finished it     (collected)
#   qc/         a reviewer has checked it after    (collected)
#
# Writes, under 05_Extraction_Results:
#   qc_corrected_general.csv / qc_corrected_locations.csv  the merged result
#   qc_change_log.csv               every cell that changed, and who changed it
#   qc_offlist_values.csv           values typed outside the controlled list
#   qc_vocab_corrections.csv        vocabulary choices a person overruled
#   qc_overview.xlsx                one row per project, for spotting outliers
#
#   Rscript R/07_review/collect_qc_workbooks.R [--root <dir>] [--run <file>] [--dry]
#
# --root defaults to $QC_ROOT, else outputs/qc. Point it at the Google Drive
# folder the consultants work in; Drive for Desktop mounts as a drive letter,
# so no API work is needed.
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "vocab_lists.R"))
source(file.path(REPO, "R", "00_shared", "vocab_cache.R"))
source(file.path(REPO, "R", "00_shared", "xlsx_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
opt  <- function(flag, default = "") {
  i <- which(args == flag); if (length(i) && length(args) > i[1]) args[i[1] + 1] else default
}
DRY  <- any(args == "--dry")
OUT_EXTRACT <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction"))
ROOT <- opt("--root", Sys.getenv("QC_ROOT", QC_DIR))

rd <- function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character", check.names = FALSE)
  d[is.na(d)] <- ""; d
}
`%||%` <- function(a, b) if (is.null(a) || !length(a)) b else a

#' Excel gives back a retyped number as a double, and as.character(33000000)
#' is "3.3e+07". That exact conversion already leaked into budget_total once.
cell_chr <- function(x) {
  if (is.null(x)) return(character(0))
  if (is.numeric(x)) {
    out <- ifelse(is.na(x), "", format(x, scientific = FALSE, trim = TRUE))
    return(sub("\\.0+$", "", out))
  }
  out <- as.character(x); out[is.na(out)] <- ""; trimws(out)
}
same <- function(a, b) identical(trimws(a), trimws(b))

## ---- find the workbooks ----------------------------------------------------
stage_files <- function(stage) {
  d <- list.dirs(ROOT, recursive = TRUE, full.names = TRUE)
  d <- d[basename(d) == stage]
  f <- unlist(lapply(d, function(x) list.files(x, pattern = "\\.xlsx$", full.names = TRUE)))
  # an empty stage is the normal case early on, and data.frame() recycles a
  # length-1 stage against zero files into an error rather than zero rows
  if (!length(f)) return(data.frame(file = character(0), stage = character(0),
                                    stringsAsFactors = FALSE))
  data.frame(file = f, stage = stage, stringsAsFactors = FALSE)
}
books <- rbind(stage_files("done"), stage_files("qc"))
books <- books[!grepl("^~\\$", basename(books$file)), , drop = FALSE]   # Excel lock files

cat("root:", ROOT, "\n")
if (!nrow(books)) {
  cat("\nnothing to collect: no .xlsx in any done/ or qc/ folder under that root.\n",
      "Workbooks in extracted/ and progress/ are ignored on purpose.\n")
  quit(save = "no")
}
cat("workbooks:", nrow(books), "(", sum(books$stage == "done"), "done,",
    sum(books$stage == "qc"), "reviewed )\n")

## ---- the frozen runs they were built from ----------------------------------
run_cache <- new.env(parent = emptyenv())
load_run <- function(run_id) {
  if (exists(run_id, envir = run_cache)) return(get(run_id, envir = run_cache))
  f <- opt("--run")
  if (!nzchar(f)) {
    cand <- list.files(OUT_EXTRACT, pattern = paste0("^harmonized_", run_id, "\\.csv$"),
                       full.names = TRUE, recursive = TRUE)
    f <- if (length(cand)) cand[1] else ""
  }
  v <- if (nzchar(f) && file.exists(f)) list(gen = rd(f), src = f) else NULL
  lf <- list.files(file.path(OUT_EXTRACT, "locations"),
                   pattern = "^locations_harmonized_.*\\.csv$", full.names = TRUE)
  if (!is.null(v) && length(lf)) v$loc <- rd(lf[which.max(file.mtime(lf))])
  assign(run_id, v, envir = run_cache); v
}

## ---- which columns are controlled, and how a decision is keyed -------------
# Only the fields whose decision key is ONE verbatim column are written back to
# vocab_decisions.csv. project_scale composes its key from three columns and
# document_type runs a deterministic pre-map first, so reconstructing their
# keys here would risk writing a key that never matches - a correction that
# silently never applies is worse than one the team can see and apply.
VOCAB <- list(
  general = list(
    target_beneficiary_project = list(
      field = "target_beneficiary_project (who the project targets)",
      options = OPT$beneficiary, src = "target_beneficiary_stated", writeback = TRUE),
    result1_metric = list(field = "result_metric (what a project result counts)",
      options = OPT$metric, src = "result1_metric_stated", writeback = TRUE),
    result2_metric = list(field = "result_metric (what a project result counts)",
      options = OPT$metric, src = "result2_metric_stated", writeback = TRUE),
    result3_metric = list(field = "result_metric (what a project result counts)",
      options = OPT$metric, src = "result3_metric_stated", writeback = TRUE),
    result1_unit = list(field = "result_unit", options = OPT$unit,
      src = "result1_unit_stated", writeback = TRUE),
    result2_unit = list(field = "result_unit", options = OPT$unit,
      src = "result2_unit_stated", writeback = TRUE),
    result3_unit = list(field = "result_unit", options = OPT$unit,
      src = "result3_unit_stated", writeback = TRUE),
    project_scale = list(field = "project_scale (geographic level of the project)",
      options = OPT$scale, src = "", writeback = FALSE),
    document_type = list(field = "document_type", options = OPT$doc_type,
      src = "", writeback = FALSE)),
  locations = list(
    target_beneficiary = list(field = "target_beneficiary",
      options = OPT$beneficiary, src = "target_beneficiary_stated", writeback = TRUE),
    `subsector type` = list(field = "subsector type", options = OPT$subsector,
      src = "", writeback = FALSE),
    result_level = list(field = "result_level", options = OPT$result_level,
      src = "", writeback = FALSE)))

## ---- walk the workbooks ----------------------------------------------------
changes <- list(); corrected_gen <- list(); corrected_loc <- list(); offlist <- list()

for (k in seq_len(nrow(books))) {
  f <- books$file[k]; stage <- books$stage[k]
  who <- basename(dirname(dirname(f)))
  about <- tryCatch(read.xlsx(f, sheet = "about"), error = function(e) NULL)
  if (is.null(about)) { cat(sprintf("  %-34s SKIPPED: no about sheet\n", basename(f))); next }
  getab <- function(key) {
    i <- which(tolower(trimws(about$item)) == key)
    if (length(i)) cell_chr(about$value[i[1]]) else ""
  }
  pc <- getab("project code"); run_id <- getab("run id")
  if (!nzchar(pc)) { cat(sprintf("  %-34s SKIPPED: no project code\n", basename(f))); next }
  run <- load_run(run_id)

  for (sheet in c("general", "locations")) {
    d <- tryCatch(read.xlsx(f, sheet = sheet, sep.names = " "), error = function(e) NULL)
    if (is.null(d) || !nrow(d)) next
    d[] <- lapply(d, cell_chr)
    base <- if (is.null(run)) NULL else if (sheet == "general") run$gen else run$loc
    if (!is.null(base)) {
      base <- base[base$project_code == pc, , drop = FALSE]
      if (sheet == "locations" && "row_id" %in% names(d) && "row_id" %in% names(base))
        base <- base[match(d$row_id, base$row_id), , drop = FALSE]
    }
    for (cn in names(d)) {
      was <- if (!is.null(base) && cn %in% names(base) && nrow(base) == nrow(d))
               cell_chr(base[[cn]]) else rep(NA_character_, nrow(d))
      for (i in seq_len(nrow(d))) {
        now <- d[[cn]][i]
        if (!is.na(was[i]) && !same(now, was[i]))
          changes[[length(changes) + 1]] <- data.frame(
            project_code = pc, sheet = sheet, row = i, field = cn,
            pipeline_said = was[i], consultant_said = now,
            consultant = who, stage = stage, run_id = run_id,
            workbook = basename(f), stringsAsFactors = FALSE)
        spec <- VOCAB[[sheet]][[cn]]
        if (!is.null(spec) && nzchar(now) && !now %in% spec$options &&
            !startsWith(now, "CANDIDATE:"))
          offlist[[length(offlist) + 1]] <- data.frame(
            project_code = pc, sheet = sheet, field = cn, value = now,
            consultant = who, workbook = basename(f), stringsAsFactors = FALSE)
      }
    }
    d$.consultant <- who; d$.stage <- stage; d$.workbook <- basename(f)
    if (sheet == "general") corrected_gen[[length(corrected_gen) + 1]] <- d
    else corrected_loc[[length(corrected_loc) + 1]] <- d
  }
  cat(sprintf("  %-34s %-10s %-10s %s\n", basename(f), who, stage,
              if (is.null(run)) "run not found - no diff" else "ok"))
}

bindall <- function(l) if (!length(l)) NULL else do.call(rbind, lapply(l, function(x) {
  miss <- setdiff(unique(unlist(lapply(l, names))), names(x))
  for (m in miss) x[[m]] <- ""
  x[, unique(unlist(lapply(l, names))), drop = FALSE]
}))

CHG <- bindall(changes); OFF <- bindall(offlist)
GEN <- bindall(corrected_gen); LOC <- bindall(corrected_loc)

## ---- vocabulary corrections ------------------------------------------------
VC <- NULL
if (!is.null(CHG)) {
  rows <- list()
  for (i in seq_len(nrow(CHG))) {
    spec <- VOCAB[[CHG$sheet[i]]][[CHG$field[i]]]
    if (is.null(spec)) next
    src_text <- ""
    bk <- if (CHG$sheet[i] == "general") GEN else LOC
    if (nzchar(spec$src) && !is.null(bk) && spec$src %in% names(bk)) {
      m <- which(bk$project_code == CHG$project_code[i])
      if (length(m) >= CHG$row[i]) src_text <- cell_chr(bk[[spec$src]][m[CHG$row[i]]])
    }
    rows[[length(rows) + 1]] <- data.frame(
      field = spec$field, sheet = CHG$sheet[i], template_column = CHG$field[i],
      project_code = CHG$project_code[i], extract_text = src_text,
      pipeline_choice = CHG$pipeline_said[i], corrected_choice = CHG$consultant_said[i],
      consultant = CHG$consultant[i],
      applied = if (isTRUE(spec$writeback) && nzchar(src_text)) "yes" else "no",
      why = if (isTRUE(spec$writeback) && nzchar(src_text)) ""
            else if (!isTRUE(spec$writeback))
              "decision key is composed from several columns; apply by hand in vocab_decisions.csv"
            else "the verbatim extract behind this cell is not in the workbook",
      stringsAsFactors = FALSE)
  }
  VC <- bindall(rows)
}

## ---- write -----------------------------------------------------------------
w <- function(df, path, what) {
  if (is.null(df) || !nrow(df)) { cat(sprintf("  %-34s none\n", what)); return(invisible()) }
  if (!DRY) {
    tmp <- paste0(path, ".tmp")            # OneDrive: write then rename
    write.csv(df, tmp, row.names = FALSE, na = "")
    invisible(file.rename(tmp, path))
  }
  cat(sprintf("  %-34s %4d rows  %s\n", what, nrow(df), if (DRY) "(--dry)" else path))
}
cat("\nwriting:\n")
w(GEN, file.path(QC_DIR, "qc_corrected_general.csv"), "corrected general")
w(LOC, file.path(QC_DIR, "qc_corrected_locations.csv"), "corrected locations")
w(CHG, file.path(QC_DIR, "qc_change_log.csv"), "change log")
w(OFF, file.path(QC_DIR, "qc_offlist_values.csv"), "values outside the list")
w(VC,  file.path(QC_DIR, "qc_vocab_corrections.csv"), "vocabulary corrections")

## ---- durable vocabulary fixes ----------------------------------------------
if (!is.null(VC) && !DRY) {
  app <- VC[VC$applied == "yes", , drop = FALSE]
  n <- 0L
  for (fld in unique(app$field)) {
    sub <- app[app$field == fld, , drop = FALSE]
    spec <- NULL
    for (sh in names(VOCAB)) for (cn in names(VOCAB[[sh]]))
      if (identical(VOCAB[[sh]][[cn]]$field, fld)) spec <- VOCAB[[sh]][[cn]]
    if (is.null(spec)) next
    # a later row wins on a duplicate key, so appending overrides the model
    vocab_cache_save(REPO, fld, spec$options, sub$extract_text, sub$corrected_choice)
    n <- n + nrow(sub)
  }
  if (n) cat("\n", n, "vocabulary decisions recorded in catalogues/vocab_decisions.csv;",
             "\n  the next harmonise reuses them instead of asking the model again.\n")
}

## ---- overview --------------------------------------------------------------
if (!is.null(GEN) && !DRY) {
  wb <- createWorkbook(); qc_lists_reset()
  qc_sheet(wb, "projects", GEN)
  if (!is.null(CHG)) qc_sheet(wb, "changes", CHG)
  if (!is.null(OFF)) qc_sheet(wb, "off_list", OFF)
  f <- file.path(QC_DIR, "qc_overview.xlsx")
  tryCatch({ saveWorkbook(wb, f, overwrite = TRUE); cat("  overview:", f, "\n") },
           error = function(e) cat("  overview NOT written (open in Excel?):",
                                   conditionMessage(e), "\n"))
}

cat("\ncollected", nrow(books), "workbooks;",
    if (is.null(CHG)) 0 else nrow(CHG), "cells changed by hand.\n")
if (!is.null(CHG)) {
  cat("changes per consultant:\n"); print(table(CHG$consultant))
  cat("most-corrected fields:\n"); print(head(sort(table(CHG$field), decreasing = TRUE), 8))
}
