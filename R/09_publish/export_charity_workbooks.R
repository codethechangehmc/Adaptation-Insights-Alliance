# export_charity_workbooks.R - the Charity pilot as two workbooks a person can
# open, instead of thirty files a script can read.
#
# 05_Extraction_Results/charity_pilot holds the working material of a
# measurement: the reference, the raw pipeline output, the harmonised output,
# three score files and two comparison workbooks. That is the right shape for
# checking the pipeline and the wrong shape for asking a colleague to extract
# eleven documents by hand.
#
# Two files are written, both in the template's own layout, with the readme,
# actor_codes and location_codes sheets kept so the vocabularies travel with
# them:
#
#   charity_pilot_blank_to_fill.xlsx   the eleven project codes and nothing
#                                      else, for the manual extraction
#   charity_pilot_AI_answers.xlsx      the same sheets filled with what the
#                                      pipeline produced
#
# They are separate on purpose. Someone who fills in the blank workbook with
# the machine's answers already on screen will agree with them more often than
# they would have on their own, and the comparison then measures nothing. The
# blank one is the one to send first.
#
#   Rscript R/09_publish/export_charity_workbooks.R

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

CP   <- file.path(RESULTS_DIR, "charity_pilot")
MAN  <- file.path(PILOT_DIR, "charity_pilot", "manifest.csv")
OUT  <- CP                      # everything for this pilot lives in one folder
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

GEN_SHEET <- "project_data_general"
LOC_SHEET <- "project_data_location-specific"

fields <- function(f) read.csv(file.path(REPO, "template", f),
                               stringsAsFactors = FALSE)$field
tg <- fields("fields_project_data_general.csv")
tl <- fields("fields_project_data_location_specific.csv")

rd <- function(p) {
  d <- read.csv(p, stringsAsFactors = FALSE, colClasses = "character")
  d[is.na(d)] <- ""
  d
}
# The three inputs below were the working CSVs of the measurement run. They
# have been removed, the folder now holding the workbooks rather than the
# material they were built from. Each therefore falls back to the AI answers
# workbook, which carries the same rows in the same shape: regenerating from
# its own output is idempotent, and leaves the two comparison workbooks, which
# are the record of the measurement, untouched.
AI <- file.path(CP, "charity_pilot_AI_answers.xlsx")

from_csv_or_book <- function(csv, sheet, what) {
  p <- file.path(CP, csv)
  if (file.exists(p)) return(rd(p))
  if (!file.exists(AI)) stop("neither ", csv, " nor ", basename(AI), " is present")
  cat("  ", what, ": from ", basename(AI), " (", sheet, ")\n", sep = "")
  d <- read.xlsx(AI, sheet = sheet)
  d[] <- lapply(d, as.character); d[is.na(d)] <- ""
  d
}
gen <- from_csv_or_book("pipeline_harmonized.csv", GEN_SHEET,  "general")
loc <- from_csv_or_book("pipeline_locations.csv",  LOC_SHEET,  "locations")
man <- if (file.exists(MAN)) read.csv(MAN, stringsAsFactors = FALSE) else {
  cat("   documents: from ", basename(AI), " (documents)\n", sep = "")
  d <- read.xlsx(AI, sheet = "documents")
  data.frame(project_code = d$project_code, pdf = d$document, stringsAsFactors = FALSE)
}

# template order, template columns only; a column the pipeline does not carry
# is written empty rather than dropped, so the sheet keeps its shape.
shape <- function(d, want) {
  for (f in setdiff(want, names(d))) d[[f]] <- ""
  d[, want, drop = FALSE]
}
gen <- shape(gen, tg)
loc <- shape(loc, tl)
cat(sprintf("general %d rows x %d cols, locations %d rows x %d cols\n",
            nrow(gen), ncol(gen), nrow(loc), ncol(loc)))

# which document each code is, so the workbook stands on its own
docs <- data.frame(project_code = man$project_code,
                   document = basename(man$pdf),
                   stringsAsFactors = FALSE)

# The template carries one example row under the header of the general sheet.
# It has to go, or P0001 is read as a twelfth project.
EXAMPLE_ROWS <- 1

# The OneDrive master can be a cloud placeholder: it reports the right size,
# read.xlsx copes, and loadWorkbook fails to unzip it. The committed copy is a
# real local file, which is one of the reasons it is committed.
SRC <- local({
  cand <- c(TEMPLATE_XLSX, file.path(REPO, "template", TEMPLATE_FILE_REPO))
  for (p in cand) {
    if (!file.exists(p)) next
    ok <- tryCatch({ loadWorkbook(p); TRUE }, error = function(e) FALSE)
    if (ok) return(p)
    cat("  template not loadable, trying the next copy:", basename(p), "\n")
  }
  stop("no loadable template workbook")
})
cat("template:", SRC, "\n")

write_book <- function(path, general, locations, note) {
  wb <- loadWorkbook(SRC)
  for (s in c(GEN_SHEET, LOC_SHEET)) {
    n <- max(nrow(read.xlsx(SRC, sheet = s, colNames = FALSE)), 1)
    if (n > 1) deleteData(wb, s, cols = seq_len(60), rows = 2:(n + 200), gridExpand = TRUE)
  }
  writeData(wb, GEN_SHEET, general, startRow = 2, colNames = FALSE)
  if (nrow(locations)) writeData(wb, LOC_SHEET, locations, startRow = 2, colNames = FALSE)
  if (!"documents" %in% names(wb)) addWorksheet(wb, "documents")
  writeData(wb, "documents", docs)
  if (!"about" %in% names(wb)) addWorksheet(wb, "about")
  writeData(wb, "about", data.frame(note = note, stringsAsFactors = FALSE))
  saveWorkbook(wb, path, overwrite = TRUE)
  cat("  written:", basename(path), "\n")
}

blank <- gen
blank[] <- ""
blank$project_code <- gen$project_code

write_book(
  file.path(OUT, "charity_pilot_blank_to_fill.xlsx"),
  blank, loc[0, , drop = FALSE],
  c("Charity pilot: eleven documents to extract by hand.",
    "One row per document on project_data_general, keyed by project_code.",
    "The documents sheet says which PDF each code is.",
    "actor_codes and location_codes are the accepted vocabularies.",
    "Fill this in before opening the AI answers workbook. Seeing the",
    "machine's answers first changes what a reader writes down, and the",
    "comparison stops measuring anything.",
    paste("Written", format(Sys.Date(), "%d %B %Y"))))

write_book(
  file.path(OUT, "charity_pilot_AI_answers.xlsx"),
  gen, loc,
  c("Charity pilot: what the pipeline extracted from the eleven documents.",
    "Model gpt-5-mini, run 28 September 2026, harmonised against the",
    "template vocabularies.",
    "Open this after the manual extraction is finished, not before.",
    "These answers are not correct by definition. Where the two disagree,",
    "the document decides.",
    paste("Written", format(Sys.Date(), "%d %B %Y"))))

cat("\nfolder:", OUT, "\n")
