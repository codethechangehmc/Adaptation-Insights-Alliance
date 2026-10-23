# rule_unreadable.R - give a recorded verdict to the corpus files the screener
# cannot read, so every file on disk has a disposition.
#
# screen_scope.R reads pdf, docx and legacy doc. Spreadsheets are skipped on
# purpose (R/03_screen/screen_scope.R:253): they are GEF AMAT and PMAT
# indicator workbooks, which carry numbers against indicators and no prose to
# judge. The effect was that 48 files sat on disk with no row in the ledger at
# all, neither in nor out, which is the state this project tries not to have.
#
# They are ruled out of scope on the protocol's first criterion: an indicator
# workbook is not "a completion report, a terminal or mid term evaluation, a
# performance evaluation". The rule is recorded on the row, so the decision is
# visible rather than implied by absence.
#
# Idempotent: a file already in the ledger is left alone.
#
#   Rscript R/03_screen/rule_unreadable.R --dry
#   Rscript R/03_screen/rule_unreadable.R

suppressPackageStartupMessages({ library(cli) })
DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

SC <- file.path(SCREEN_DIR, "scope_screen.csv")
sc <- read.csv(SC, stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""
have <- tolower(paste(sc$source, sc$filename))

# everything on disk the screener does not read
rows <- list()
for (src in names(SCAN_DIRS)) for (d in SCAN_DIRS[[src]]) {
  p <- file.path(DOCS_ROOT, d)
  if (!dir.exists(p)) next
  f <- list.files(p, pattern = "(?i)[.](xlsx|xls|zip|csv)$")
  if (!length(f)) next
  rows[[length(rows) + 1]] <- data.frame(source = src, folder = d, filename = f,
                                         stringsAsFactors = FALSE)
}
if (!length(rows)) { cli_alert_success("nothing unreadable on disk"); quit(save = "no") }
u <- do.call(rbind, rows)
u <- u[!(tolower(paste(u$source, u$filename)) %in% have), ]
cli_alert_info("unreadable files with no ledger row: {nrow(u)}")
if (!nrow(u)) { cli_alert_success("every file already has a row"); quit(save = "no") }

ext <- tolower(tools::file_ext(u$filename))
stem <- sub("[.][^.]*$", "", u$filename)

# One reason per kind, because they are not the same kind of thing. Four of
# the five zips are named Terminal_Evaluation or Mid-Term_Review and sit in
# evaluation_docs: they are archives whose contents were unpacked at
# retrieval and screened as separate PDFs, so the archive is a container, not
# a rejected evaluation.
unpacked <- vapply(stem, function(s)
  any(grepl(paste0("^", s, "_unpacked|^", s, "_unzipped"), sc$filename)), logical(1))

reason <- ifelse(
  ext == "zip" & unpacked,
    "archive; its contents were unpacked at retrieval and screened as separate files",
  ifelse(ext == "zip",
    "archive; not itself a document",
  ifelse(grepl("PPG_Completion_Report", u$filename, fixed = TRUE),
    "completion report for a project preparation grant, not an evaluation of a project",
  ifelse(grepl("Cofinancing_Table", u$filename, fixed = TRUE),
    "financing table, not an evaluation",
  ifelse(grepl("AMAT|PMAT|Tracking_Tool", u$filename, ignore.case = TRUE),
    "GEF indicator workbook (AMAT/PMAT): numbers against indicators, not an evaluation",
    paste0("spreadsheet (", ext, "); the protocol's source type requires an evaluation"))))))

print(table(u$source, ext))

new <- sc[0, , drop = FALSE]
new[seq_len(nrow(u)), ] <- ""
new$source <- u$source; new$folder <- u$folder; new$filename <- u$filename
# verdict_model holds the MODEL'S VERDICT, not the name of what produced it
# (screen_rules.R:82 reads it as the base verdict). Putting a provenance
# string there put "rule, not read" into the verdict column for all 78 rows.
# The provenance goes in `note`.
new$verdict <- "out of scope"; new$verdict_ruled <- "out of scope"
new$verdict_model <- "out of scope"
new$reason <- reason; new$rule_applied <- reason
new$note <- "ruled by rule_unreadable.R; the screener does not read this file type"
if ("doc_type" %in% names(new)) new$doc_type <- ifelse(ext %in% c("xlsx", "xls"), "indicator workbook", ext)

if (DRY) {
  cli_alert_info("would add {nrow(new)} rows; ledger {nrow(sc)} -> {nrow(sc) + nrow(new)}")
  quit(save = "no")
}
out <- rbind(sc, new)
write.csv(out, SC, row.names = FALSE, fileEncoding = "UTF-8")
cli_h2("ledger {nrow(sc)} -> {nrow(out)} rows")
print(table(out$verdict_ruled))
