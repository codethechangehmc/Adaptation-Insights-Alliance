# export_template.R - put the template's reference sheets into the repo as CSV.
#
# The template workbook lives on OneDrive and is not in git, but six scripts
# read it and nobody outside the team can see it. These three sheets are the
# parts other people need:
#
#   codebook       the field definitions: field, description, options, example
#   location_codes the registry every location_id is drawn from. The number
#                  after the dot is a sequence number in the order places were
#                  first recorded for that project, not a meaningful code.
#   option_lists   the controlled vocabularies behind the dropdowns
#
# The option lists exist only in the 2 Oct workbook; the codebook and the
# location registry are read from whichever workbook paths.R points at, so
# the export always matches what the pipeline actually uses.
#
#   Rscript R/00_shared/export_template.R

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
suppressMessages(library(openxlsx))
source(file.path(REPO, "R", "00_shared", "paths.R"))

OUT <- file.path(REPO, "template")
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

LISTS_XLSX <- file.path(TEMPLATE_DIR,
  "EvidenceSynthesis_GreyLiterature_AfricanAgricultureAdaptation_UpdatedTemplate_02Oct2026.xlsx")

clean <- function(df) {
  df[] <- lapply(df, function(x) {
    x <- as.character(x)
    # openxlsx leaves xml:space artefacts on some shared strings
    x <- gsub('^xml:space="preserve">', "", x)
    x <- gsub("[\r\n]+", " ", x)
    trimws(x)
  })
  df[is.na(df)] <- ""
  df
}
drop_empty_rows <- function(df) df[rowSums(df != "") > 0, , drop = FALSE]

say <- function(...) cat(" ", ..., "\n")

## ---- 1. the codebook (the readme sheet) -------------------------------------
cb <- clean(read.xlsx(TEMPLATE_XLSX, sheet = "readme", colNames = FALSE))
cb <- drop_empty_rows(cb)
names(cb) <- paste0("col", seq_len(ncol(cb)))
write.csv(cb, file.path(OUT, "codebook.csv"), row.names = FALSE, fileEncoding = "UTF-8")
say("codebook.csv          ", nrow(cb), "rows")

## ---- 2. the location registry -----------------------------------------------
lc <- clean(read.xlsx(TEMPLATE_XLSX, sheet = "location_codes"))
lc <- drop_empty_rows(lc)
write.csv(lc, file.path(OUT, "location_codes.csv"), row.names = FALSE, fileEncoding = "UTF-8")
say("location_codes.csv    ", nrow(lc), "rows,", ncol(lc), "columns")

## ---- 3. the option lists ----------------------------------------------------
if (file.exists(LISTS_XLSX)) {
  ls_raw <- clean(read.xlsx(LISTS_XLSX, sheet = "lists"))
  long <- do.call(rbind, lapply(names(ls_raw), function(n) {
    v <- ls_raw[[n]]; v <- v[nzchar(v)]
    if (!length(v)) NULL else data.frame(list_name = n, option = v, stringsAsFactors = FALSE)
  }))
  write.csv(long, file.path(OUT, "option_lists.csv"), row.names = FALSE, fileEncoding = "UTF-8")
  say("option_lists.csv      ", nrow(long), "options across",
      length(unique(long$list_name)), "lists")
} else {
  say("option_lists: SKIPPED, workbook not found:", basename(LISTS_XLSX))
}

## ---- 4. the two template sheet headers, so field order is visible -----------
for (sh in c("project_data_general", "project_data_location-specific")) {
  h <- read.xlsx(TEMPLATE_XLSX, sheet = sh, colNames = TRUE, rows = 1)
  write.csv(data.frame(position = seq_along(names(h)), field = names(h)),
            file.path(OUT, paste0("fields_", gsub("[^a-z]", "_", tolower(sh)), ".csv")),
            row.names = FALSE, fileEncoding = "UTF-8")
  say(paste0("fields_", gsub("[^a-z]", "_", tolower(sh)), ".csv"), ncol(h), "fields")
}

cat("\nwritten to:", OUT, "\nsource workbook:", basename(TEMPLATE_XLSX), "\n")
