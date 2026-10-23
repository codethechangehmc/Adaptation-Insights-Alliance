##############################################################################
# xlsx_helpers.R — the Excel furniture the QC workbooks need, in one place.
#
# Eight scripts in this repo each carry their own copy of the same
# createWorkbook/writeData/freezePane block. That was fine while every sheet
# was a flat table. The QC workbooks need three things none of them do:
#
#   qc_comment()    the quote, page and fact-check verdict on the cell itself,
#                   so a consultant hovers instead of opening the PDF. This is
#                   the whole reason the workbooks exist: the evidence has to
#                   sit beside the value or checking 23,000 cells means
#                   23,000 document searches.
#   qc_dropdown()   a real controlled list. The template's own validations
#                   point at #REF! and enforce nothing, so a reviewer can
#                   currently type anything into a coded field.
#   qc_lock()       the key columns read-only, so an edit cannot break the
#                   merge back. Not security, just a guard rail.
#
# Nothing here knows about the extraction. It takes a sheet and some strings.
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

QC_STYLES <- list(
  header  = createStyle(textDecoration = "bold", fgFill = "#EEEEEE",
                        border = "bottom", wrapText = TRUE, halign = "left"),
  # a cell the document never filled: confirming an absence is still a check,
  # so it has to look different from a value nobody has looked at
  empty   = createStyle(fgFill = "#FAFAFA", fontColour = "#999999"),
  # the fact-check could not find this value on the page it cites
  suspect = createStyle(fgFill = "#FFF2CC"),
  locked  = createStyle(fgFill = "#F3F3F3", fontColour = "#666666"),
  label   = createStyle(textDecoration = "bold", valign = "top"))

#' Attach a hover note to one cell.
#'
#' openxlsx writes these as Excel comments. They survive a round trip through
#' desktop Excel; confirm Google Sheets before relying on them (it imports them
#' as notes), and fall back to a twin evidence sheet if it does not.
#'
#' @param wb,sheet  workbook and sheet name
#' @param col,row   1-based cell position, row 1 being the header
#' @param text      the note; empty or NA attaches nothing
qc_comment <- function(wb, sheet, col, row, text) {
  if (is.null(text) || is.na(text) || !nzchar(trimws(text))) return(invisible(FALSE))
  # Excel truncates very long notes awkwardly, so cut with an ellipsis rather
  # than let it mangle the end
  if (nchar(text) > 1800) text <- paste0(substr(text, 1, 1797), "...")
  writeComment(wb, sheet, col = col, row = row,
               comment = createComment(comment = text, author = "pipeline",
                                       visible = FALSE))
  invisible(TRUE)
}

#' Restrict a column to a controlled list.
#'
#' Excel caps an inline list at 255 characters, so a long vocabulary (the 27
#' metrics, the 24 beneficiaries) is written to a hidden sheet and referenced.
#' Without that the validation silently fails to apply, which is worse than
#' having none: the sheet looks protected and is not.
#'
#' @param wb,sheet  workbook and sheet name
#' @param col       1-based column to constrain
#' @param options   character vector of allowed values
#' @param rows      data rows to cover (not counting the header)
#' @param list_sheet  name of the hidden sheet holding long lists
# how many list columns the hidden sheet already holds, per workbook. An
# openxlsx workbook is a reference object and does not carry R attributes
# across calls, so the counter lives here and qc_lists_reset() clears it
# between workbooks.
.qc_list_col <- new.env(parent = emptyenv())
qc_lists_reset <- function() assign("n", 0L, envir = .qc_list_col)
qc_dropdown <- function(wb, sheet, col, options, rows, list_sheet = "_lists") {
  options <- unique(options[nzchar(options)])
  if (!length(options) || rows < 1) return(invisible(FALSE))
  inline <- paste0('"', paste(options, collapse = ","), '"')
  if (nchar(inline) <= 255 && !any(grepl(",", options, fixed = TRUE))) {
    value <- inline
  } else {
    if (!list_sheet %in% names(wb)) addWorksheet(wb, list_sheet, visible = FALSE)
    nc <- (if (exists("n", envir = .qc_list_col)) get("n", envir = .qc_list_col) else 0L) + 1L
    assign("n", nc, envir = .qc_list_col)
    writeData(wb, list_sheet, c(paste0(sheet, ".", col), options), startCol = nc,
              startRow = 1, colNames = FALSE)
    value <- sprintf("'%s'!$%s$2:$%s$%d", list_sheet,
                     int2col(nc), int2col(nc), length(options) + 1L)
  }
  tryCatch(
    dataValidation(wb, sheet, cols = col, rows = 2:(rows + 1), type = "list",
                   value = value, allowBlank = TRUE, showErrorMsg = FALSE),
    error = function(e) warning("dropdown on ", sheet, " col ", col, ": ",
                                conditionMessage(e)))
  invisible(TRUE)
}

#' Make named columns read-only.
#'
#' Everything else stays editable: consultants correct values in place, and the
#' diff against the frozen run is what recovers what the pipeline said.
qc_lock <- function(wb, sheet, headers, lock_cols, rows) {
  idx <- which(headers %in% lock_cols)
  if (!length(idx)) return(invisible(FALSE))
  for (i in idx) addStyle(wb, sheet, QC_STYLES$locked, rows = 2:(rows + 1),
                          cols = i, gridExpand = TRUE, stack = TRUE)
  # protectWorksheet locks every cell by default, so unlock the rest first
  open <- createStyle(locked = FALSE)
  keep <- setdiff(seq_along(headers), idx)
  if (length(keep))
    addStyle(wb, sheet, open, rows = 2:(rows + 1), cols = keep,
             gridExpand = TRUE, stack = TRUE)
  protectWorksheet(wb, sheet, protect = TRUE, lockFormattingCells = FALSE,
                   lockFormattingColumns = FALSE, lockFormattingRows = FALSE)
  invisible(TRUE)
}

#' Write a table with the house furniture: bold header, filter, frozen top row,
#' sensible widths.
qc_sheet <- function(wb, sheet, df, widths = NULL) {
  if (!sheet %in% names(wb)) addWorksheet(wb, sheet)
  writeData(wb, sheet, df, headerStyle = QC_STYLES$header, withFilter = TRUE)
  freezePane(wb, sheet, firstRow = TRUE)
  setColWidths(wb, sheet, cols = seq_along(df),
               widths = widths %||% pmin(42, pmax(12, nchar(names(df)) + 4)))
  invisible(wb)
}

if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a)) b else a
