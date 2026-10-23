##############################################################################
# export_reference.R - publish the gold-set reference extractions into
# 05_Extraction_Results, next to the pipeline's own output.
#
# Three things get compared every time the pipeline is scored, and until now
# two of them lived only as working CSVs in catalogues\. They belong beside
# the results, because "what should the extraction look like" is the first
# question anyone asks when they open a results file.
#
#   reading_reference_locations   308 location rows, produced by reading the
#                                 ten gold PDFs rather than by the pipeline.
#                                 The human-analog benchmark.
#   lucy_gold_locations            60 location rows, extracted by hand (v02)
#   lucy_gold_general              10 project rows, extracted by hand (v02)
#
# Neither reference is beyond question - both have known errors, listed in
# scores\location_extraction_comparison_2026-09-09.md. They are targets to
# measure against, not truth.
#
#   Rscript R/09_publish/export_reference.R
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

rd <- function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character",
                check.names = FALSE)
  d[is.na(d)] <- ""
  d
}
src <- function(n) file.path(REPO, "catalogues", n)

sheets <- list(
  reading_reference_locations = src("claude_locations_reference.csv"),
  lucy_gold_locations         = src("gold_v1_locations.csv"),
  lucy_gold_general           = src("gold_v1_general.csv"))
missing <- names(sheets)[!file.exists(unlist(sheets))]
if (length(missing)) stop("missing reference file(s): ", paste(missing, collapse = ", "))

## The reference CSVs mark acceptable alternate answers with "||" - "either
## of these scores as correct". That is a scoring device, NOT the template's
## multi-value separator, which is a semicolon ("GLO18; CON3"). Publishing
## "81 || 95" in a cell invites somebody to read it as data, so the workbook
## shows the first answer in the cell and lists the alternates on their own
## sheet. The CSVs the scorer reads keep the marker.
ALT <- character(0)
split_alternates <- function(d, sheet) {
  for (cn in names(d)) {
    k <- which(grepl("||", d[[cn]], fixed = TRUE))
    for (i in k) {
      parts <- trimws(strsplit(d[[cn]][i], "||", fixed = TRUE)[[1]])
      # an empty side is itself an accepted answer ("blank or 119444"), so
      # empties are kept rather than dropped
      if (length(parts) < 2) next
      shown <- function(x) if (nzchar(x)) x else "(blank)"
      id <- if ("row_id" %in% names(d)) d$row_id[i] else
            if ("project_code" %in% names(d)) d$project_code[i] else as.character(i)
      ALT <<- c(ALT, paste(sheet, id, cn, shown(parts[1]),
                           paste(vapply(parts[-1], shown, character(1)),
                                 collapse = " ; "), sep = "\t"))
      d[[cn]][i] <- parts[1]
    }
  }
  d
}

wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#EEEEEE", border = "bottom")
for (nm in names(sheets)) {
  d <- split_alternates(rd(sheets[[nm]]), nm)
  addWorksheet(wb, nm)
  writeData(wb, nm, d, headerStyle = hdr, withFilter = TRUE)
  freezePane(wb, nm, firstRow = TRUE)
  setColWidths(wb, nm, cols = seq_along(d),
               widths = pmin(46, pmax(11, nchar(names(d)) + 4)))
  cat(sprintf("  %-28s %4d rows  (%s)\n", nm, nrow(d), basename(sheets[[nm]])))
}

if (length(ALT)) {
  a <- do.call(rbind, lapply(strsplit(ALT, "\t", fixed = TRUE), function(p)
    data.frame(sheet = p[1], row = p[2], field = p[3], answer_shown = p[4],
               also_accepted = p[5], stringsAsFactors = FALSE)))
  addWorksheet(wb, "accepted_alternatives")
  writeData(wb, "accepted_alternatives", a, headerStyle = hdr, withFilter = TRUE)
  freezePane(wb, "accepted_alternatives", firstRow = TRUE)
  setColWidths(wb, "accepted_alternatives", cols = 1:5, widths = c(28, 10, 24, 60, 60))
  cat(sprintf("  %-28s %4d cells had more than one acceptable answer\n",
              "accepted_alternatives", nrow(a)))
}

about <- data.frame(
  sheet = c("reading_reference_locations", "lucy_gold_locations",
            "lucy_gold_general", "accepted_alternatives", "separators",
            "generated", "regenerate with", "caution"),
  what = c(
    "The ten gold PDFs read end to end and extracted by hand-equivalent reading, not by the pipeline. 308 location rows. This is the human-analog benchmark: it shows what a careful reader finds, which is what the pipeline is trying to match. qc_flag marks rows the reader was unsure about.",
    "Lucy's manual extraction, working database v02. 60 location rows. The original gold standard.",
    "Lucy's manual extraction of the general sheet, v02. One row per project. NOTE: this sheet is the scorer's answer key, not a template-shaped extraction, so its columns differ from extracted_records_latest.xlsx. 'results_set' holds every acceptable result value for the project in one cell instead of result1/2/3, because the order of a project's results is arbitrary and scoring them position by position would mark a correct extraction wrong for listing them in a different order; the scorer counts a value as right if it matches any in the set. 'document' says which PDF the row came from. GESI_project was added on 14 September 2026, recorded by reading the ten gold documents; because it is prose it is compared by reading the two summaries side by side, not by string match. Result values the document does not state as a plain number are kept in the document's own form (for example >1000). The remaining prose fields (location_notes, rationale_project, result_notes) and the reference links are absent because they cannot be scored by string comparison - they are checked instead by the fact-check pass, which matches each quote back to the page it cites.",
    "Cells where more than one answer is accepted as correct (a project's short and long title, a figure quoted two ways). The sheets above show the first answer; this lists the others. The scorer counts any of them as a match.",
    "The template's separator for several values in one cell is a SEMICOLON, as the readme sheet says for funder, implementor and location ('GLO18; CON3; FRA33'). The pipeline follows it. The '||' marker in the underlying reference CSVs means 'either answer is acceptable', not 'both values apply', which is why it is split out here rather than shown in a cell.",
    format(Sys.time(), "%Y-%m-%d %H:%M"),
    "Rscript 07_Pipeline/R/09_publish/export_reference.R",
    "Neither reference is truth. Both have verified errors, listed in scores/location_extraction_comparison_2026-09-09.md (sections C and D). Read that before treating a disagreement as a pipeline mistake."),
  stringsAsFactors = FALSE)
addWorksheet(wb, "about")
writeData(wb, "about", about, headerStyle = hdr)
setColWidths(wb, "about", cols = 1:2, widths = c(30, 120))

out <- file.path(REPO, "outputs", "extraction", "gold_reference.xlsx")
writable <- function(p) {
  if (!file.exists(p)) return(TRUE)
  con <- suppressWarnings(try(file(p, "ab"), silent = TRUE))
  if (inherits(con, "try-error")) return(FALSE)
  close(con); TRUE
}
if (!writable(out)) {
  out <- sub("\\.xlsx$", format(Sys.time(), "_%Y%m%d_%H%M.xlsx"), out)
  cat("  NOTE: gold_reference.xlsx is open in Excel; writing a dated copy.\n")
}
saveWorkbook(wb, out, overwrite = TRUE)
cat("written:", out, "\n")
