# seed_year_overrides.R - seed review/year_overrides.csv from the GEF dating
# step (Phase 4a, Oct 2026).
#
# WHY. GEF portal sheets carry a machine footer ("1/13/2026   Page 1 of 7")
# and the screener read publication_year off it; the dating step
# (catalogues/gef/gef_evaluation_dates.csv) recovered the real years from the
# documents themselves. This script writes one override row per gef judgement
# whose screened year disagrees with the catalogue's final_year (a screened
# year that is empty also counts as a disagreement when the catalogue has one).
#
# DETERMINISTIC AND RE-RUNNABLE. Existing rows in year_overrides.csv are kept
# as recorded decisions (edit the file by hand to change one); only keys not
# yet present are added, and the output is sorted by key. So a re-run - even
# after screen_rules.R has rewritten scope_screen.csv with the corrected years
# - reproduces the file byte for byte.
#
#   Rscript R/03_screen/seed_year_overrides.R
#   -> 04_Screening/inputs/decisions/year_overrides.csv
#      (source, filename, publication_year, evidence)

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
DATES  <- file.path(REPO, "catalogues", "gef", "gef_evaluation_dates.csv")
OUT    <- file.path(SCREEN_DIR, "inputs", "decisions", "year_overrides.csv")

sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
sc[is.na(sc)] <- ""
g <- sc[sc$source == "gef", ]

dates <- read.csv(DATES, stringsAsFactors = FALSE, colClasses = "character",
                  fileEncoding = "UTF-8-BOM")
dates[is.na(dates)] <- ""
dates$final_year[dates$final_year == "NA"] <- ""

# join on the catalogue's `file` column: exact filename first, then the stem
# (so a .docx judgement still meets its catalogue row whatever the extension)
stem <- function(x) sub("[.][A-Za-z0-9]+$", "", x)
m <- match(g$filename, dates$file)
m[is.na(m)] <- match(stem(g$filename), stem(dates$file))[is.na(m)]
fy   <- ifelse(is.na(m), "", dates$final_year[m])
meth <- ifelse(is.na(m), "", dates$method[m])

new <- data.frame(source = g$source, filename = g$filename, publication_year = fy,
                  evidence = sprintf(
                    "gef_evaluation_dates.csv final_year (method %s); screen read '%s'",
                    meth, g$publication_year),
                  stringsAsFactors = FALSE)
new <- new[nzchar(fy) & fy != g$publication_year, ]

old <- NULL
if (file.exists(OUT)) {
  old <- read.csv(OUT, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
  if (nrow(old)) old[is.na(old)] <- ""
}
if (!is.null(old) && nrow(old)) {
  new <- new[!(paste(new$source, new$filename) %in% paste(old$source, old$filename)), ]
  all <- rbind(old[, names(new)], new)
} else all <- new
all <- all[order(all$source, all$filename), ]

write.csv(all, OUT, row.names = FALSE, fileEncoding = "UTF-8")
cat("year_overrides.csv:", nrow(all), "rows (", nrow(new), "added this run )\n")
if (nrow(new)) print(head(new[, c("filename", "publication_year", "evidence")], 12), row.names = FALSE)
cat("written:", OUT, "\n")
