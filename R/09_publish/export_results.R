##############################################################################
# export_results.R — publish the newest pipeline run into 05_Extraction_Results
#
# The pipeline writes timestamped CSVs into 07_Pipeline/outputs/ (working
# files, gitignored). Nobody should have to dig there. This script copies the
# newest run of each kind into the team folder as one readable Excel file per
# sheet of the template, in the template's own column order.
#
#   gold_pilot/extracted_records_latest.xlsx   project_data_general rows
#   gold_pilot/location_records_latest.xlsx    project_data_location-specific rows
#
# Each workbook gets a "needs_review" sheet listing only the rows a human has
# to look at, and an "about" sheet saying which run it came from.
#
#   Rscript R/09_publish/export_results.R
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "clean_fields.R"))   # template_exact()
OUT <- file.path(REPO, "outputs", "extraction")

newest <- function(dir, pat, exclude = NULL) {
  fs <- list.files(dir, pattern = pat, full.names = TRUE)
  if (!is.null(exclude)) fs <- fs[!grepl(exclude, basename(fs))]
  if (!length(fs)) return(NA_character_)
  fs[which.max(file.mtime(fs))]
}
# nzchar() on a missing column returns logical(0), which silently collapses an
# OR chain to length zero and empties the review sheet
has <- function(x, cn) if (cn %in% names(x)) nzchar(x[[cn]]) else rep(FALSE, nrow(x))

## Excel keeps an exclusive lock on an open workbook, and saveWorkbook only
## warns when it cannot replace the file - so check first and write a dated
## copy alongside instead of pretending the refresh happened.
writable <- function(p) {
  if (!file.exists(p)) return(TRUE)
  con <- suppressWarnings(try(file(p, "ab"), silent = TRUE))
  if (inherits(con, "try-error")) return(FALSE)
  close(con); TRUE
}
rd <- function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character", check.names = FALSE)
  d[is.na(d)] <- ""; d
}

# template column order, so the export can be pasted straight into the template
# openxlsx substitutes sep.names (default ".") for spaces in a header even
# when check.names is FALSE, which is what turned the template's
# "subsector type" into "subsector.type" in every exported workbook
tmpl_cols <- function(sheet)
  names(read.xlsx(TEMPLATE_XLSX, sheet = sheet, sep.names = " "))

write_book <- function(rows, sheet_name, extra_cols, out_file, src, review_rule,
                       extra_sheets = list(), raw_sheets = list()) {
  cols <- tmpl_cols(sheet_name)
  to_template <- function(x) {
    m <- as.data.frame(lapply(cols, function(cn) if (cn %in% names(x)) x[[cn]] else ""),
                       stringsAsFactors = FALSE)
    names(m) <- cols
    # the template spells two document types with a non-breaking hyphen and the
    # emissions unit with a subscript two: write its exact strings
    for (cn in intersect(c("document_type", "result1_unit", "result2_unit", "result3_unit"), names(m)))
      m[[cn]] <- template_exact(m[[cn]])
    m
  }
  main <- to_template(rows)
  keep_extra <- intersect(extra_cols, names(rows))
  review <- rows[review_rule(rows), unique(c(intersect(cols, names(rows)), keep_extra)), drop = FALSE]

  wb <- createWorkbook()
  hdr <- createStyle(textDecoration = "bold", border = "bottom", wrapText = TRUE)
  add <- function(nm, df) {
    addWorksheet(wb, nm); writeData(wb, nm, df, headerStyle = hdr, withFilter = TRUE)
    freezePane(wb, nm, firstRow = TRUE)
    setColWidths(wb, nm, cols = seq_along(df),
                 widths = pmin(46, pmax(11, nchar(names(df)) + 4)))
  }
  add(sheet_name, main)
  for (nm in names(extra_sheets)) add(nm, to_template(extra_sheets[[nm]]))
  for (nm in names(raw_sheets)) add(nm, raw_sheets[[nm]])   # kept as-is
  add("needs_review", review)
  add("about", data.frame(
    what = c("template sheet", "rows", "rows needing review", "source run",
             "generated", "regenerate with", "note"),
    value = c(sheet_name, nrow(main), nrow(review), basename(src),
              format(Sys.time(), "%Y-%m-%d %H:%M"),
              "Rscript 07_Pipeline/R/09_publish/export_results.R",
              "columns follow the 27 Aug 2026 template exactly; working files stay in 07_Pipeline/outputs/"),
    stringsAsFactors = FALSE))
  locked <- !writable(out_file)
  if (locked) out_file <- sub("\\.xlsx$", format(Sys.time(), "_%Y%m%d_%H%M.xlsx"), out_file)
  saveWorkbook(wb, out_file, overwrite = TRUE)
  cat(sprintf("written: %s\n         %d rows, %d flagged for review (from %s)\n",
              out_file, nrow(main), nrow(review), basename(src)))
  if (locked)
    cat("         NOTE: the _latest file is open in Excel so it could not be replaced.\n",
        "        Close it and rerun to refresh the usual filename.\n", sep = "")
}

## ---- location-specific ------------------------------------------------------
f <- newest(file.path(OUT, "locations"), "^locations_harmonized_.*\\.csv$")
if (!is.na(f)) {
  d <- rd(f)
  # extra_cols are the diagnostic columns kept beside the template ones on the
  # needs_review sheet. The original four never existed in the location output,
  # so intersect() dropped them all and the sheet carried none of them; the
  # row SELECTION was unaffected, since review_rule reads `notes`.
  # harmonize_locations.R carries them from 30 Sep 2026, so a reviewer can now
  # see the page and the flags beside the row that needs looking at.
  write_book(d, "project_data_location-specific",
             extra_cols = c("row_flags", "loc_match", "document", "prompt_version",
                            "page", "locations_stated", "target_beneficiary_stated"),
             out_file = file.path(REPO, "outputs", "extraction", "location_records_latest.xlsx"),
             src = f,
             review_rule = function(x) has(x, "notes") | has(x, "row_flags"))
} else cat("no harmonised location run found\n")

## ---- general ----------------------------------------------------------------
# Harmonise writes ONE file from 30 Sep 2026, carrying the template columns
# first and the evidence behind them. to_template() still reduces it to the
# template sheet for this workbook. The "diagnostics" exclusion stays so an
# older twin left on disk is never picked as the newest run.
f <- newest(OUT, "^harmonized_.*\\.csv$", exclude = "diagnostics")
if (!is.na(f)) {
  d <- rd(f)
  # the holdout validation set keeps its own sheet, as in the first hand-made
  # export: it is a separate measurement, never merged with the gold rows
  hf <- newest(file.path(OUT, "holdout"), "^harmonized_.*\\.csv$", exclude = "diagnostics")
  extra <- if (!is.na(hf)) setNames(list(rd(hf)), "holdout") else list()
  # Comparing this workbook against gold_reference.xlsx by eye goes wrong:
  # a gold cell can hold more than one acceptable answer, so "producer"
  # looks like a mismatch beside a gold sheet showing "smallholder farmer"
  # when both are accepted. The scorer already knows; publish its verdict.
  sf <- newest(OUT, "^score_.*\\.csv$")
  raw <- if (!is.na(sf)) {
    s <- rd(sf)
    if ("gold" %in% names(s))
      names(s)[names(s) == "gold"] <- "gold_accepts"
    if ("extracted" %in% names(s))
      names(s)[names(s) == "extracted"] <- "pipeline_said"
    setNames(list(s[order(s$verdict != "mismatch", s$project), ]), "vs_gold")
  } else list()
  write_book(d, "project_data_general", extra_sheets = extra, raw_sheets = raw,
             extra_cols = c("document", "prompt_version"),
             out_file = file.path(REPO, "outputs", "extraction", "extracted_records_latest.xlsx"),
             src = f,
             review_rule = function(x) {
               fl <- grep("_flag$", names(x), value = TRUE)
               Reduce(`|`, lapply(fl, function(cn) has(x, cn)),
                      init = has(x, "notes"))
             })
} else cat("no harmonised general run found\n")
